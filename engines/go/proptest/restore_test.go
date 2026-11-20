package proptest

import (
	"bytes"
	"encoding/json"
	"testing"

	"goat-correlator/engines/go/filter"
	"goat-correlator/engines/go/fuse"
	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/quality"
)

// Snapshot then restore gives the same continued output. Filter, fuse and
// quality support restore: their snapshot holds their whole state. Correlate
// does not: its snapshot (correlate.md, correlate-assign.md Snapshot) holds
// neither an entity's last report, which the tests, staleness and output
// read, nor the pending histories' per-entity data, so an engine cannot be
// rebuilt from it.

// restorer rebuilds an engine of a pack from a decoded snapshot.
func restorer(t *testing.T, p pack) func(snap map[string]any) (model.Engine, error) {
	switch p.fn.name {
	case "filter":
		pk, err := filter.ParsePack(p.text)
		if err != nil {
			t.Fatal(err)
		}
		return func(s map[string]any) (model.Engine, error) { return filter.Restore(pk, s) }
	case "fuse":
		pk, err := fuse.ParsePack(p.text)
		if err != nil {
			t.Fatal(err)
		}
		return func(s map[string]any) (model.Engine, error) { return fuse.Restore(pk, s) }
	case "quality":
		pk, err := quality.ParsePack(p.text)
		if err != nil {
			t.Fatal(err)
		}
		return func(s map[string]any) (model.Engine, error) { return quality.Restore(pk, s) }
	}
	return nil
}

// throughJSON is the snapshot as a file holds it, read back.
func throughJSON(t *testing.T, snap model.Obj) map[string]any {
	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	v, err := io.DecodeObject(b)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestSnapshotRestore(t *testing.T) {
	for _, p := range packs(t) {
		restore := restorer(t, p)
		if restore == nil {
			continue
		}
		mk := p.engine(t)
		var inputs [][]io.Step
		for _, v := range p.vectors {
			inputs = append(inputs, readSteps(t, v))
		}
		inputs = append(inputs, scenario(31, 200), scenario(32, 200))
		for n, steps := range inputs {
			want, wantSnap := io.Run(mk(), steps)
			every := max(1, len(steps)/12) // about a dozen restore points per input

			for k := 0; k <= len(steps); k += every {
				g := mk()
				io.Run(g, steps[:k])
				g2, err := restore(throughJSON(t, g.Snapshot()))
				if err != nil {
					t.Fatalf("%s input %d at %d: %v", p.name, n, k, err)
				}
				tail, snap := io.Run(g2, steps[k:])
				if a, b := output(t, tail, snap), output(t, want[k:], wantSnap); !bytes.Equal(a, b) {
					t.Fatalf("%s input %d restored at step %d: %s", p.name, n, k, firstDiff(a, b))
				}
			}
		}
	}
}

// TestRestoreRejects: a snapshot that is not one gives an error, not an engine.
func TestRestoreRejects(t *testing.T) {
	fp, _ := filter.ParsePack("pack p\nversion 1\ndefault keep\nforget_ms 1\n")
	up, _ := fuse.ParsePack("pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 1\n")
	qp, _ := quality.ParsePack("pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\nrule r scope=entity measure=age op=> limit=1 for=1 clear=1 action=alert\n")
	bad := []map[string]any{
		{"entities": 1},
		{"entities": map[string]any{"s/1": map[string]any{"time_ms": "x"}}},
		{"ref": []any{1.0}, "entities": map[string]any{}},
		{"ref": nil, "entities": map[string]any{"s/1": map[string]any{"filter": 1, "report": map[string]any{}}}},
		{"ref": nil, "entities": map[string]any{"s/1": map[string]any{"last_pos": []any{1.0}, "window": []any{map[string]any{}}}}, "rules": map[string]any{}},
		{"ref": nil, "entities": map[string]any{}, "rules": map[string]any{"r": map[string]any{"s/1": map[string]any{"count": "1"}}}},
	}
	for i, s := range bad {
		_, e1 := filter.Restore(fp, s)
		_, e2 := fuse.Restore(up, s)
		_, e3 := quality.Restore(qp, s)
		if e1 == nil && e2 == nil && e3 == nil {
			t.Errorf("snapshot %d restores in every function", i)
		}
	}
	if _, err := quality.Restore(qp, map[string]any{"ref": nil, "entities": map[string]any{}, "rules": map[string]any{"r": map[string]any{}}}); err != nil {
		t.Errorf("an empty quality snapshot: %v", err)
	}
}
