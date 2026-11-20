package quality

import (
	"fmt"
	"path/filepath"
	"sort"
	"testing"

	"goat-correlator/engines/go/io"
)

const root = "../../.."

// TestScenarioVectors runs packs/quality-*/vectors/*.json: every step's events
// and trace, then the final snapshot.
func TestScenarioVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "quality-*", "vectors", "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no quality scenario vectors found")
	}
	for _, f := range files {
		v, err := io.ReadObject(f)
		if err != nil {
			t.Fatal(err)
		}
		t.Run(fmt.Sprint(v["pack"], "/", v["name"]), func(t *testing.T) {
			g, err := Load(filepath.Join(root, "packs", v["pack"].(string)))
			if err != nil {
				t.Fatal(err)
			}
			if m := io.CheckVector(g, v); m != "" {
				t.Fatal(m)
			}
		})
	}
}

// TestLoadVectors runs spec/quality-load-vectors/*.json.
func TestLoadVectors(t *testing.T) {
	vs, err := io.ReadLoadVectors(filepath.Join(root, "spec", "quality-load-vectors"))
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range vs {
		t.Run(v.Name, func(t *testing.T) {
			if m := v.CheckLoad(func(text string) error { _, err := ParsePack(text); return err }); m != "" {
				t.Fatal(m)
			}
		})
	}
}

// TestShippedPacksLoad checks every packs/quality-*/pack.def loads.
func TestShippedPacksLoad(t *testing.T) {
	dirs, _ := filepath.Glob(filepath.Join(root, "packs", "quality-*", "pack.def"))
	for _, d := range dirs {
		if _, err := LoadPack(filepath.Dir(d)); err != nil {
			t.Errorf("%s: %v", d, err)
		}
	}
}
