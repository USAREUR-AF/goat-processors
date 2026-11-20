package quality

import (
	"testing"
)

func TestStatistics(t *testing.T) {
	if mean([]float64{1, 2, 4}) != 7.0/3 {
		t.Error("mean")
	}
	if maxInt([]int64{3, 9, 2}) != 9 {
		t.Error("maxInt")
	}
	if extreme([]any{int64(2), 2.0, 5.5, int64(-1)}, true) != 5.5 || extreme([]any{int64(2), 2.0}, true) != int64(2) {
		t.Error("extreme largest, first on a tie")
	}
	if extreme([]any{int64(2), -0.5}, false) != -0.5 {
		t.Error("extreme smallest")
	}
	if median([]int64{5, 1, 3}) != int64(3) || median([]int64{4, 1}) != 2.5 {
		t.Error("median")
	}
	if lateness(int64(10), 4) != int64(6) || lateness(10.5, 4) != 6.5 {
		t.Error("lateness")
	}
	for _, c := range []struct {
		v  float64
		op string
		x  float64
		ok bool
	}{{1, "<", 2, true}, {2, "<=", 2, true}, {3, ">", 2, true}, {2, ">=", 2, true}, {2, ">", 2, false}} {
		if holds(c.v, c.op, c.x) != c.ok {
			t.Errorf("holds(%v %s %v)", c.v, c.op, c.x)
		}
	}
	if _, ok := asFloat("x"); ok {
		t.Error("asFloat of a string")
	}
}

func TestRuleStep(t *testing.T) {
	r := Rule{Op: "<", Limit: 10, For: 2, Clear: 20}
	st, s := r.step(ruleState{}, 5.0)
	if st.count != 1 || st.active || !s.pass || s.limit != 10 {
		t.Fatalf("first %+v %+v", st, s)
	}
	st, s = r.step(st, 5.0)
	if !st.active || st.count != 0 || !s.started {
		t.Fatalf("second %+v %+v", st, s)
	}
	st, s = r.step(st, nil)
	if !st.active || s.pass || s.limit != 20 {
		t.Fatalf("absent value never clears: %+v %+v", st, s)
	}
	st, s = r.step(st, 25.0)
	if st.active || !s.ended {
		t.Fatalf("clear %+v %+v", st, s)
	}
	st, _ = r.step(ruleState{count: 1}, 15.0)
	if st.count != 0 {
		t.Error("a miss resets the count")
	}
}

func TestPackErrors(t *testing.T) {
	base := "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n"
	for _, bad := range []string{
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=2 action=alert\n",
		base + "rule r scope=entity measure=age op=< limit=2 for=1 clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=0 clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=downgrade\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=alert factor=2\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=downgrade factor=0.5\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=downgrade factor=x\n",
		base + "rule r scope=entity measure=age op=! limit=1 for=1 clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=shout\n",
		base + "rule r scope=group measure=age op=> limit=1 for=1 clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=x for=1 clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=x action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=x clear=1 action=alert\n",
		base + "rule r scope=entity measure=age op=> limit=1e999 for=1 clear=1 action=alert\n",
		base + "rule\n", base + "rule r! scope=entity\n",
		base + "rule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=alert\nrule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=alert\n",
		base + "time_default s error_ms=1\ntime_default s state=drifting\n",
		base + "pack q\n", base + "noise\n", base + "\x01\n",
		"pack p\nversion 1\nfilter accel_var=-1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=0 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=0 min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=x min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=x default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1\nwindow window_ms=1 min_samples=1 forget_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n",
	} {
		if _, err := ParsePack(bad); err == nil {
			t.Errorf("loads:\n%q", bad)
		}
	}
	if _, err := Load("testdata/none"); err == nil {
		t.Error("a missing pack loads")
	}
}
