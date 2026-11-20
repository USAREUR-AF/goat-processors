// Package model holds what every function of the engine shares: the JSON
// object type, the entry-point shape, the frame (spec/correlate.md Frame),
// the constant-velocity filter (Track estimate), the two-model math
// (Two-model filter), the report rules (Reports) and time quality (Reports,
// Time quality). Every function here is pure: it reads its arguments and
// returns values; nothing in this package holds state.
package model

import "sort"

// Obj is one JSON object: an event, a trace record or a snapshot.
type Obj = map[string]any

// Engine is the entry-point shape of every function (correlate, filter,
// fuse, quality): a pack is loaded into a new engine, then each report is
// ingested and each tick run, each returning its events and trace records,
// and Snapshot returns the whole state.
type Engine interface {
	Ingest(report map[string]any) (events, trace []Obj)
	Tick(now int64) (events, trace []Obj)
	Snapshot() Obj
}

// SortedKeys returns the keys of m in ascending byte order.
func SortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// Strings is a list of strings as a JSON list.
func Strings(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

// OrNull is s, or nil (JSON null) for the empty string.
func OrNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}
