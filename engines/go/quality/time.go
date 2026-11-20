package quality

import (
	"sort"

	"goat-correlator/engines/go/model"
)

// Time quality (spec: Reports, "Time quality") and the input clock (spec:
// Input clock).

// timeStateCodes are the codes of the time states for measures; higher is
// worse (spec: Reports, Time quality).
var timeStateCodes = map[string]int64{"coherent": 0, "drifting": 1, "free-running": 2}

// timeQuality is a report's time error and time state, each found per key
// (spec: Reports, Time quality). For the trace it also keeps the report's own
// valid value and the time_default's value, each nil when not given.
type timeQuality struct {
	errorReport, errorDefault any // float64 or nil
	stateReport, stateDefault any // string or nil
}

// resolveTimeQuality finds the time quality of a report from source:
//  1. the report's own valid value (validity as correlate.md 0.8);
//  2. otherwise the pack's time_default for the report's source, when it
//     gives that key;
//  3. otherwise unstated: no sample is taken (quality, unlike correlate, does
//     not take error 0 and coherent here).
func (g *Engine) resolveTimeQuality(source string, report map[string]any) timeQuality {
	var tq timeQuality
	if x, ok := model.ValidTimeError(report["time_error_ms"]); ok {
		tq.errorReport = x
	}
	if s, ok := model.ValidTimeState(report["time_state"]); ok {
		tq.stateReport = s
	}
	if def, ok := g.pack.TimeDefaults[source]; ok {
		if def.HasError {
			tq.errorDefault = def.ErrorMs
		}
		if def.HasState {
			tq.stateDefault = def.State
		}
	}
	return tq
}

// timeError is the stated time error, or false when unstated.
func (tq timeQuality) timeError() (float64, bool) {
	for _, v := range []any{tq.errorReport, tq.errorDefault} {
		if x, ok := v.(float64); ok {
			return x, true
		}
	}
	return 0, false
}

// timeState is the stated time state, or false when unstated.
func (tq timeQuality) timeState() (string, bool) {
	for _, v := range []any{tq.stateReport, tq.stateDefault} {
		if s, ok := v.(string); ok {
			return s, true
		}
	}
	return "", false
}

// inputClock builds the input clock for a report from source, from the
// entities as they are just before the report is applied (spec: Input clock).
// It returns an int64, a float64 (the mean of two middle values), or nil when
// there is no other source.
func (g *Engine) inputClock(source string) any {
	// 1. Each other source's latest time: the greatest last of its entities.
	latest := map[string]int64{}
	for _, e := range g.entities {
		if e.source == source {
			continue
		}
		if l, ok := latest[e.source]; !ok || e.last > l {
			latest[e.source] = e.last
		}
	}
	// 3. No other source: no input clock.
	if len(latest) == 0 {
		return nil
	}
	// 2. The median of those latest times.
	times := make([]int64, 0, len(latest))
	for _, l := range latest {
		times = append(times, l)
	}
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	n := len(times)
	if n%2 == 1 {
		return times[n/2]
	}
	a, b := float64(times[n/2-1]), float64(times[n/2])
	return (a + b) / 2
}

// sourceLatest is the greatest last among the entities whose source is the
// report's source, the report's own entity included; false when there is none
// (spec: Input clock).
func (g *Engine) sourceLatest(source string) (int64, bool) {
	var latest int64
	found := false
	for _, e := range g.entities {
		if e.source == source && (!found || e.last > latest) {
			latest, found = e.last, true
		}
	}
	return latest, found
}

// lateness is clock - t: an integer when the clock is one, else binary64
// (spec: Samples).
func lateness(clock any, t int64) any {
	if c, ok := clock.(int64); ok {
		return c - t
	}
	return clock.(float64) - float64(t)
}
