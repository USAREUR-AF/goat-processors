package fuse

import (
	"fmt"
	"path/filepath"
	"sort"
	"testing"

	"goat-correlator/engines/go/io"
)

const root = "../../.."

// TestFuseScenarioVectors runs packs/fuse-*/vectors/*.json: every step's events
// and trace, then the final snapshot.
func TestFuseScenarioVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "fuse-*", "vectors", "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no fuse scenario vectors found")
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

// TestFuseLoadVectors runs spec/fuse-load-vectors/*.json.
func TestFuseLoadVectors(t *testing.T) {
	vs, err := io.ReadLoadVectors(filepath.Join(root, "spec", "fuse-load-vectors"))
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

// TestFuseShippedPacksLoad checks every packs/fuse-*/pack.def loads.
func TestFuseShippedPacksLoad(t *testing.T) {
	dirs, _ := filepath.Glob(filepath.Join(root, "packs", "fuse-*", "pack.def"))
	for _, d := range dirs {
		if _, err := LoadPack(filepath.Dir(d)); err != nil {
			t.Errorf("%s: %v", d, err)
		}
	}
}
