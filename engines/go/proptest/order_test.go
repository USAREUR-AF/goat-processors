package proptest

import (
	"bytes"
	"encoding/json"
	"math/rand/v2"
	"os"
	"strings"
	"testing"

	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
)

// Order independence, where the specifications say order does not matter.

// shuffled writes v as JSON with every object's members in a random order.
func shuffled(b *bytes.Buffer, v any, r *rand.Rand) {
	switch x := v.(type) {
	case map[string]any:
		keys := model.SortedKeys(x)
		r.Shuffle(len(keys), func(i, j int) { keys[i], keys[j] = keys[j], keys[i] })
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			kb, _ := json.Marshal(k)
			b.Write(kb)
			b.WriteByte(':')
			shuffled(b, x[k], r)
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			shuffled(b, e, r)
		}
		b.WriteByte(']')
	default:
		vb, _ := json.Marshal(x) // json.Number is written as it was read
		b.Write(vb)
	}
}

// TestJSONMemberOrder: a JSON object is unordered (RFC 8259), so the order of
// the members of every report, step and vector object changes nothing.
func TestJSONMemberOrder(t *testing.T) {
	r := rand.New(rand.NewPCG(7, 7))
	for _, p := range packs(t) {
		mk := p.engine(t)
		for _, v := range p.vectors {
			text, err := os.ReadFile(v)
			if err != nil {
				t.Fatal(err)
			}
			doc, err := io.DecodeObject(text)
			if err != nil {
				t.Fatal(err)
			}
			steps, _ := io.ParseSteps(doc)
			want := runBytes(t, mk(), steps)
			var b bytes.Buffer
			shuffled(&b, doc, r)
			doc2, err := io.DecodeObject(b.Bytes())
			if err != nil {
				t.Fatal(err)
			}
			steps2, err := io.ParseSteps(doc2)
			if err != nil {
				t.Fatal(err)
			}
			if got := runBytes(t, mk(), steps2); !bytes.Equal(got, want) {
				t.Fatalf("%s: %s", v, firstDiff(got, want))
			}
		}
	}
}

// TestFilterDirectiveOrder: spec/filter.md Pack, "Other directives may
// appear in any order relative to the rules": moving the pack, version,
// default and forget_ms lines anywhere changes nothing.
func TestFilterDirectiveOrder(t *testing.T) {
	r := rand.New(rand.NewPCG(11, 11))
	for _, p := range packs(t) {
		if p.fn.name != "filter" {
			continue
		}
		mk := p.engine(t)
		var moved, rest []string
		for _, line := range strings.Split(p.text, "\n") {
			f := strings.Fields(line)
			if len(f) > 0 && (f[0] == "pack" || f[0] == "version" || f[0] == "default" || f[0] == "forget_ms") {
				moved = append(moved, line)
			} else {
				rest = append(rest, line)
			}
		}
		for trial := 0; trial < 8; trial++ {
			lines := append([]string(nil), rest...)
			for _, m := range moved {
				i := r.IntN(len(lines) + 1)
				lines = append(lines[:i], append([]string{m}, lines[i:]...)...)
			}
			mk2, err := p.fn.parse(strings.Join(lines, "\n"))
			if err != nil {
				t.Fatalf("%s reordered does not load: %v\n%s", p.name, err, strings.Join(lines, "\n"))
			}
			for _, v := range p.vectors {
				steps := readSteps(t, v)
				if got, want := runBytes(t, mk2(), steps), runBytes(t, mk(), steps); !bytes.Equal(got, want) {
					t.Fatalf("%s %s: %s", p.name, v, firstDiff(got, want))
				}
			}
		}
	}
}

// permuteBetweenTicks returns a permutation of steps: between two ticks the
// reports of different entities change places, each entity's own reports
// keep their order, and every step up to the first accepted report (which
// fixes the frame) stays. perm[i] is the original index of new step i.
func permuteBetweenTicks(steps []io.Step, r *rand.Rand) []int {
	perm := make([]int, len(steps))
	for i := range perm {
		perm[i] = i
	}
	start := 0
	for start < len(steps) && (steps[start].Report == nil || model.MissingKey(steps[start].Report) != "") {
		start++
	}
	start++
	for i := start; i < len(steps); {
		if steps[i].Report == nil {
			i++
			continue
		}
		j := i
		for j < len(steps) && steps[j].Report != nil {
			j++
		}
		seg := append([]int(nil), perm[i:j]...)
		r.Shuffle(len(seg), func(a, b int) { seg[a], seg[b] = seg[b], seg[a] })
		// Put each entity's reports back in their own order, in the slots
		// that entity now holds.
		byKey := map[string][]int{}
		key := func(k int) string {
			rep := steps[k].Report
			s, _ := rep["track.source_id"].(string)
			u, _ := rep["uid"].(string)
			if s == "" || u == "" {
				return "#" + string(rune(k))
			}
			return s + "/" + u
		}
		for _, k := range perm[i:j] {
			byKey[key(k)] = append(byKey[key(k)], k)
		}
		for n, k := range seg {
			list := byKey[key(k)]
			seg[n], byKey[key(k)] = list[0], list[1:]
		}
		copy(perm[i:j], seg)
		i = j
	}
	return perm
}

// TestReportOrderBetweenTicks: method assign assigns at the tick, its rows
// in key order (correlate-assign.md Window step 2), and fuse decides at the
// tick, groups in their output order (fuse.md Groups); a report changes
// only its own entity. So between two ticks the reports of different
// entities may arrive in any order: every step's output, the step moved
// with its report, and the snapshot are the same.
func TestReportOrderBetweenTicks(t *testing.T) {
	r := rand.New(rand.NewPCG(13, 13))
	for _, p := range packs(t) {
		mk := p.engine(t)
		if !(p.fn.name == "fuse" || (p.fn.name == "correlate" && strings.Contains(p.text, "method") && strings.Contains(p.text, "assign"))) {
			continue
		}
		var inputs [][]io.Step
		for _, v := range p.vectors {
			inputs = append(inputs, readSteps(t, v))
		}
		inputs = append(inputs, scenario(21, 120), scenario(22, 120))
		for n, steps := range inputs {
			want, wantSnap := io.Run(mk(), steps)
			for trial := 0; trial < 3; trial++ {
				perm := permuteBetweenTicks(steps, r)
				moved := make([]io.Step, len(steps))
				for i, k := range perm {
					moved[i] = steps[k]
				}
				got, gotSnap := io.Run(mk(), moved)
				back := make([]io.Result, len(got))
				for i, k := range perm {
					back[k] = got[i]
				}
				if a, b := output(t, back, gotSnap), output(t, want, wantSnap); !bytes.Equal(a, b) {
					t.Fatalf("%s input %d: %s", p.name, n, firstDiff(a, b))
				}
			}
		}
	}
}
