package io

import (
	"fmt"
	"math"

	"goat-correlator/engines/go/model"
)

// Mismatch returns the path of the first difference between got and want,
// or "" when they are equal (spec/vector-format.md: What the engine
// checks): numbers within 1e-6 * max(1, |want|), strings, booleans and null
// exactly, lists element by element, objects key by key (a key present
// with null differs from a key absent).
func Mismatch(path string, got, want any) string {
	if wn, ok := model.ToFloat(want); ok {
		gn, ok := model.ToFloat(got)
		if !ok || math.Abs(gn-wn) > 1e-6*math.Max(1, math.Abs(wn)) {
			return fmt.Sprintf("%s: got %#v, want %v", path, got, want)
		}
		return ""
	}
	switch w := want.(type) {
	case nil, string, bool:
		if got != want {
			return fmt.Sprintf("%s: got %#v, want %#v", path, got, want)
		}
		return ""
	case []any:
		g, ok := got.([]any)
		if !ok || len(g) != len(w) {
			return fmt.Sprintf("%s: got %#v, want %v", path, got, want)
		}
		for i := range w {
			if m := Mismatch(fmt.Sprintf("%s[%d]", path, i), g[i], w[i]); m != "" {
				return m
			}
		}
		return ""
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return fmt.Sprintf("%s: got %#v, want an object", path, got)
		}
		keys := map[string]bool{}
		for k := range w {
			keys[k] = true
		}
		for k := range g {
			keys[k] = true
		}
		for _, k := range model.SortedKeys(keys) {
			gv, gok := g[k]
			wv, wok := w[k]
			if gok != wok {
				return fmt.Sprintf("%s.%s: present in got=%v, in want=%v", path, k, gok, wok)
			}
			if m := Mismatch(path+"."+k, gv, wv); m != "" {
				return m
			}
		}
		return ""
	}
	return fmt.Sprintf("%s: unexpected want type %T", path, want)
}

// Objs is a list of objects as a JSON list.
func Objs(list []model.Obj) []any {
	out := make([]any, len(list))
	for i, o := range list {
		out[i] = o
	}
	return out
}

// CheckVector runs a scenario vector's steps on g, comparing each step's
// events with its expect and its trace with its trace, then the final
// snapshot; it returns the first mismatch, or "".
func CheckVector(g model.Engine, v map[string]any) string {
	list, _ := v["steps"].([]any)
	steps, err := ParseSteps(v)
	if err != nil {
		return err.Error()
	}
	for i, s := range steps {
		var events, tr []model.Obj
		if s.Report != nil {
			events, tr = g.Ingest(s.Report)
		} else {
			events, tr = g.Tick(s.Now)
		}
		step := list[i].(map[string]any)
		p := fmt.Sprintf("steps[%d]", i)
		if m := Mismatch(p+".expect", Objs(events), step["expect"]); m != "" {
			return m
		}
		if m := Mismatch(p+".trace", Objs(tr), step["trace"]); m != "" {
			return m
		}
	}
	return Mismatch("snapshot", g.Snapshot(), v["snapshot"])
}
