package filter

import (
	"encoding/json"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Conditions (spec/filter.md: Conditions). Each condition gives true, false
// or unknown, with the `value` and `limit` of its trace record.

type truth int

const (
	isFalse truth = iota
	isTrue
	unknown
)

type result struct {
	truth        truth
	value, limit any
}

func of(b bool) truth {
	if b {
		return isTrue
	}
	return isFalse
}

// passes applies `not` and the rule that an unknown condition never passes.
func (r result) passes(negated bool) bool {
	if r.truth == unknown {
		return false
	}
	return (r.truth == isTrue) != negated
}

// conditionKind is one row of the conditions table: the parameter sets it
// accepts (exactly one of them; spec: Pack) and its evaluation against the
// report and the entities' state before it (read only).
type conditionKind struct {
	sets [][]string
	eval func(c Condition, r *report, states map[string]*State) result
}

// conditions is the Conditions table; adding a condition is one row (and,
// for a new parameter, its reading in parseWhen).
var conditions = map[string]conditionKind{
	"circle": {[][]string{{"lat", "lon", "radius_m"}}, func(c Condition, r *report, _ map[string]*State) result {
		d := distance(r.lat, r.lon, c.Lat, c.Lon)
		return result{of(d <= c.RadiusM), d, c.RadiusM}
	}},
	"polygon": {[][]string{{"vertices"}}, func(c Condition, r *report, _ map[string]*State) result {
		where := polygonTest(c.Vertices, r.lat, r.lon)
		return result{of(where != outside), where, nil}
	}},
	"near": {[][]string{{"reference", "radius_m", "max_age_ms"}}, near},
	"env": {[][]string{{"in"}}, func(c Condition, r *report, _ map[string]*State) result {
		env, ok := r.environment()
		return inList(env, ok, c.In)
	}},
	"affiliation": {[][]string{{"in"}}, func(c Condition, r *report, _ map[string]*State) result {
		aff, ok := r.affiliation()
		return inList(aff, ok, c.In)
	}},
	"source": {[][]string{{"in"}}, func(c Condition, r *report, _ map[string]*State) result {
		return inList(r.source, true, c.In)
	}},
	"uid": {[][]string{{"in"}}, func(c Condition, r *report, _ map[string]*State) result {
		return inList(r.uid, true, c.In)
	}},
	"key": {[][]string{{"name", "eq"}, {"name", "in"}, {"name", "min"}, {"name", "max"}, {"name", "min", "max"}},
		func(c Condition, r *report, _ map[string]*State) result { return keyCondition(c, r) }},
	"has": {[][]string{{"name"}}, func(c Condition, r *report, _ map[string]*State) result {
		_, present := r.values[c.KeyName]
		return result{of(present), present, nil}
	}},
	"speed": {[][]string{{"min"}, {"max"}, {"min", "max"}}, func(c Condition, r *report, _ map[string]*State) result {
		return rangeOf(r.values["speed_ms"], c)
	}},
	"altitude": {[][]string{{"min"}, {"max"}, {"min", "max"}}, func(c Condition, r *report, _ map[string]*State) result {
		return rangeOf(r.values["hae"], c)
	}},
	"interval": {[][]string{{"min_ms"}}, func(c Condition, r *report, states map[string]*State) result {
		s := states[r.key]
		if s == nil || s.KeptMs == nil {
			return result{isFalse, nil, c.MinMs}
		}
		gap := r.timeMs - *s.KeptMs
		return result{of(gap < c.MinMs), gap, c.MinMs}
	}},
	"order": {[][]string{{}}, func(c Condition, r *report, states map[string]*State) result {
		s := states[r.key]
		if s == nil || s.KeptMs == nil {
			return result{isFalse, r.timeMs, nil}
		}
		return result{of(r.timeMs < *s.KeptMs), r.timeMs, *s.KeptMs}
	}},
}

// near: the distance from the report to the reference predicted to the
// report's time; unknown (value null) when the reference has no state or is stale.
func near(c Condition, r *report, states map[string]*State) result {
	ref := states[c.Reference]
	if ref == nil || stale(ref, r.timeMs, c.MaxAgeMs) {
		return result{unknown, nil, c.RadiusM}
	}
	lat, lon := predict(ref, r.timeMs)
	d := distance(r.lat, r.lon, lat, lon)
	return result{of(d <= c.RadiusM), d, c.RadiusM}
}

// stale: abs(time_ms - ref.time_ms) > max_age_ms, or time_ms >= ref.stale_ms.
func stale(ref *State, t, maxAge int64) bool {
	age := t - ref.TimeMs
	if age < 0 {
		age = -age
	}
	if age > maxAge {
		return true
	}
	return ref.StaleMs != nil && t >= *ref.StaleMs
}

// listLimit is the trace limit of an `in` list: its items in pack order.
func listLimit(items []string) []any {
	out := make([]any, len(items))
	for i, s := range items {
		out[i] = s
	}
	return out
}

// inList: a string compared byte for byte with the items; unknown when absent.
func inList(v string, present bool, items []string) result {
	if !present {
		return result{unknown, nil, listLimit(items)}
	}
	found := false
	for _, it := range items {
		if it == v {
			found = true
		}
	}
	return result{of(found), v, listLimit(items)}
}

// rangeLimit is [min, max], null for an omitted bound.
func rangeLimit(c Condition) []any {
	return []any{snapshot.OptFloat(c.Min), snapshot.OptFloat(c.Max)}
}

// rangeOf: min <= value <= max, inclusive; unknown when the value is absent
// or not a number (true and false are not numbers).
func rangeOf(v any, c Condition) result {
	f, isNum := model.ToFloat(v)
	if v == nil || !isNum {
		return result{unknown, v, rangeLimit(c)}
	}
	ok := (c.Min == nil || *c.Min <= f) && (c.Max == nil || f <= *c.Max)
	return result{of(ok), v, rangeLimit(c)}
}

// keyCondition runs the three forms of `key`: eq, in, range.
func keyCondition(c Condition, r *report) result {
	v, present := r.values[c.KeyName]
	switch {
	case c.In != nil: // form in
		if !present {
			return result{unknown, nil, listLimit(c.In)}
		}
		found := false
		for _, it := range c.In {
			if keyEqual(v, it) {
				found = true
			}
		}
		return result{of(found), v, listLimit(c.In)}

	case c.Eq != "": // form eq
		if !present {
			return result{unknown, nil, c.Eq}
		}
		return result{of(keyEqual(v, c.Eq)), v, c.Eq}

	default: // form range
		return rangeOf(v, c)
	}
}

// keyEqual is `key` equality between a report value and a pack text.
func keyEqual(v any, t string) bool {
	switch x := v.(type) {
	case string:
		return x == t
	case bool:
		return (x && t == "true") || (!x && t == "false")
	case json.Number, float64, int, int64:
		f, _ := model.ToFloat(x)
		p, err := parseNumber(t) // only a pack number can equal a number
		return err == nil && p == f
	}
	return false // arrays and objects are never equal
}
