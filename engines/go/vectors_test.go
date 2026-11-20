package goengine

import (
	"fmt"
	"path/filepath"
	"sort"
	"testing"

	"goat-correlator/engines/go/correlate"
	"goat-correlator/engines/go/io"
)

const root = "../.."

// TestScenarioVectors runs packs/correlate-*/vectors/*.json: every step's events and trace,
// then the final snapshot.
func TestScenarioVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "correlate-*", "vectors", "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no scenario vectors found")
	}
	for _, f := range files {
		v, err := io.ReadObject(f)
		if err != nil {
			t.Fatal(err)
		}
		t.Run(fmt.Sprint(v["pack"], "/", v["name"]), func(t *testing.T) {
			g, err := correlate.Load(filepath.Join(root, "packs", v["pack"].(string)))
			if err != nil {
				t.Fatal(err)
			}
			if m := io.CheckVector(g, v); m != "" {
				t.Fatal(m)
			}
		})
	}
}

// TestLoadVectors runs spec/correlate-load-vectors/*.json.
func TestLoadVectors(t *testing.T) {
	vs, err := io.ReadLoadVectors(filepath.Join(root, "spec", "correlate-load-vectors"))
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range vs {
		t.Run(v.Name, func(t *testing.T) {
			if m := v.CheckLoad(func(text string) error { _, err := correlate.ParsePack(text); return err }); m != "" {
				t.Fatal(m)
			}
		})
	}
}

// TestShippedPacksLoad checks every packs/correlate-*/pack.def loads.
func TestShippedPacksLoad(t *testing.T) {
	dirs, _ := filepath.Glob(filepath.Join(root, "packs", "correlate-*", "pack.def"))
	for _, d := range dirs {
		if _, err := correlate.LoadPack(filepath.Dir(d)); err != nil {
			t.Errorf("%s: %v", d, err)
		}
	}
}
