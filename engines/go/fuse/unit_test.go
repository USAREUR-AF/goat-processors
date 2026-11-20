package fuse

import (
	"encoding/json"
	"testing"
)

func TestCIWeight(t *testing.T) {
	a := Axis{PP: 1, VV: 1}
	b := Axis{PP: 4, VV: 4}
	if w := ciWeight(a, a, b, b); w != 1 {
		t.Errorf("a smaller X keeps X: %v", w)
	}
	if w := ciWeight(b, b, a, a); w != 0 {
		t.Errorf("a smaller Y takes Y: %v", w)
	}
	if w := ciWeight(a, a, a, a); w != 0.5 {
		t.Errorf("equal: %v", w)
	}
	if w := ciWeight(Axis{PP: 1}, Axis{PP: 4}, Axis{PP: 4}, Axis{PP: 1}); w <= 0 || w >= 1 {
		t.Errorf("crossed: %v", w)
	}
	if w := ciWeight(Axis{PP: 1}, Axis{PP: 100}, Axis{PP: 1.1}, Axis{PP: 2}); w < 0 || w > 1 {
		t.Errorf("clamped: %v", w)
	}
	f := ciFold(Axis{P: 0, V: 0, PP: 2, VV: 2}, Axis{P: 10, V: 4, PP: 2, VV: 2}, 0.5)
	if f.P != 5 || f.V != 2 || f.PP != 2 {
		t.Errorf("fold %v", f)
	}
}

func TestEqualAndUsable(t *testing.T) {
	for _, c := range []struct {
		x, y any
		eq   bool
	}{{json.Number("1"), 1.0, true}, {json.Number("1"), "1", false}, {"a", "a", true}, {"a", true, false},
		{true, true, true}, {true, false, false}, {[]any{}, []any{}, false}} {
		if equal(c.x, c.y) != c.eq {
			t.Errorf("equal(%#v, %#v)", c.x, c.y)
		}
	}
	if attributeRules["max"].usable("5") || !attributeRules["latest"].usable(true) || attributeRules["majority"].usable(nil) {
		t.Error("usable")
	}
}

func TestPackErrors(t *testing.T) {
	base := "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1000\n"
	p, err := ParsePack(base + "source a\nsource b\nattribute type rule=majority\n")
	if err != nil {
		t.Fatal(err)
	}
	if p.Rank("b") != 1 || p.Rank("c") != -1 {
		t.Error("Rank")
	}
	for _, bad := range []string{
		base + "kinematics best\n", base + "source a\nsource a\n", base + "attribute k rule=sum\n",
		base + "attribute k=1 rule=max\n", base + "attribute k rule=max\nattribute k rule=min\n",
		base + "attribute k\n", base + "colour red\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics vote\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=-1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=0 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1 accel_var=1 default_ce_m=1 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=x default_ce_m=1 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100 x=1\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var\nkinematics best\nstale_ms 1\n",
		"pack p q\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms -1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics\nstale_ms 1\n",
		"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\n",
	} {
		if _, err := ParsePack(bad); err == nil {
			t.Errorf("loads:\n%s", bad)
		}
	}
	if _, err := Load("testdata/none"); err == nil {
		t.Error("a missing pack loads")
	}
}
