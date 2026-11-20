package proptest

import (
	"bytes"
	"testing"

	"goat-correlator/engines/go/io"
)

// TestDeterminism: the same input gives the same output, byte for byte, on
// every scenario vector of every shipped pack and on seeded random
// scenarios. Each run is a new engine, and Go randomizes map iteration on
// every run, so an output that depended on map order would differ.
func TestDeterminism(t *testing.T) {
	for _, p := range packs(t) {
		mk := p.engine(t)
		inputs := [][]any{}
		for _, v := range p.vectors {
			inputs = append(inputs, []any{v, readSteps(t, v)})
		}
		for seed := uint64(1); seed <= 3; seed++ {
			inputs = append(inputs, []any{"random", scenario(seed, 150)})
		}
		for _, in := range inputs {
			steps := in[1].([]io.Step)
			first := runBytes(t, mk(), steps)
			for i := 0; i < 3; i++ {
				if again := runBytes(t, mk(), steps); !bytes.Equal(first, again) {
					t.Fatalf("%s %v: run %d differs: %s", p.name, in[0], i+2, firstDiff(first, again))
				}
			}
		}
	}
}
