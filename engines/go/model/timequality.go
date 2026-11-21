package model

import (
	"fmt"
	"math"
	"strings"
)

// Time quality (spec/correlate.md 1.0: Reports, "Time quality"; Track
// estimate, "Measurement variance"; Pack, time_default), which quality cites.

// TimeStates are the values time_state and a time_default's state may take.
var TimeStates = [...]string{"coherent", "drifting", "free-running"}

// IsTimeState reports whether s is one of the three time states.
func IsTimeState(s string) bool {
	for _, t := range TimeStates {
		if s == t {
			return true
		}
	}
	return false
}

// TimeDefault is one pack line `time_default <source_id> error_ms= state=`.
// Each key is given or not, independently.
type TimeDefault struct {
	HasError bool
	ErrorMs  float64
	HasState bool
	State    string
}

// ParseTimeDefault reads the fields after `time_default`: the source id, a
// first token without '=', then error_ms, state or both, each at most once.
// number reads error_ms with the grammar of the calling function's pack.
func ParseTimeDefault(rest []string, number func(string) (float64, error)) (string, TimeDefault, error) {
	var d TimeDefault
	if len(rest) < 2 || strings.Contains(rest[0], "=") {
		return "", d, fmt.Errorf("time_default takes <source_id> and error_ms=, state= or both")
	}
	for _, f := range rest[1:] {
		k, v, ok := strings.Cut(f, "=")
		switch {
		case !ok:
			return "", d, fmt.Errorf("time_default: parameter without '=': %q", f)
		case k == "error_ms" && !d.HasError:
			x, err := number(v)
			if err != nil || !(x >= 0) {
				return "", d, fmt.Errorf("time_default: error_ms must be a number 0 or above")
			}
			d.HasError, d.ErrorMs = true, x
		case k == "state" && !d.HasState:
			if !IsTimeState(v) {
				return "", d, fmt.Errorf("time_default: unknown state %q", v)
			}
			d.HasState, d.State = true, v
		default:
			return "", d, fmt.Errorf("time_default: unknown or repeated parameter %q", k)
		}
	}
	return rest[0], d, nil
}

// ValidTimeError reads a report's time_error_ms value: a number, finite and
// 0 or above. false when it is absent by those rules (null included).
func ValidTimeError(v any) (float64, bool) {
	x, isNum := ToFloat(v)
	if !isNum || math.IsNaN(x) || math.IsInf(x, 0) || x < 0 {
		return 0, false
	}
	return x, true
}

// ValidTimeState reads a report's time_state value: one of the three
// states, compared byte for byte. false when it is absent by that rule.
func ValidTimeState(v any) (string, bool) {
	s, isStr := v.(string)
	if !isStr || !IsTimeState(s) {
		return "", false
	}
	return s, true
}

// CleanTimeQuality removes from a report (already cleaned by CleanOptional)
// the time quality keys that are treated as absent. Neither causes a reject.
func CleanTimeQuality(r map[string]any) map[string]any {
	if v, ok := r["time_error_ms"]; ok {
		if _, valid := ValidTimeError(v); !valid {
			delete(r, "time_error_ms")
		}
	}
	if v, ok := r["time_state"]; ok {
		if _, valid := ValidTimeState(v); !valid {
			delete(r, "time_state")
		}
	}
	return r
}

// MeasurementVariance is the position variance r_east, r_north of a report
// with circular error ce and time error te (ms), and its timing variance
// (v_e*ts)², (v_n*ts)², 0 and 0 when te is 0 (Track estimate, Measurement
// variance). ve, vn is the velocity the timing variance is found from.
func MeasurementVariance(ce, te, ve, vn float64) (rEast, rNorth, varEast, varNorth float64) {
	if te == 0 {
		return ce * ce, ce * ce, 0, 0
	}
	ts := te / 1000
	varEast, varNorth = (ve*ts)*(ve*ts), (vn*ts)*(vn*ts)
	return ce*ce + varEast, ce*ce + varNorth, varEast, varNorth
}

// AddVariance adds a variance to the pp of each axis of a prediction.
func AddVariance(pe, pn Axis, varEast, varNorth float64) (Axis, Axis) {
	pe.PP = pe.PP + varEast
	pn.PP = pn.PP + varNorth
	return pe, pn
}
