package correlator

import (
	"fmt"
	"math"
	"strings"
)

// Time quality (spec/correlate.md 0.8: Reports, "Time quality"; Track
// estimate, "Measurement variance"; Pack, time_default).

// timeStates are the values time_state and a time_default's state may take.
var timeStates = []string{"coherent", "drifting", "free-running"}

// IsTimeState reports whether s is one of the three time states.
func IsTimeState(s string) bool { return isTimeState(s) }

func isTimeState(s string) bool {
	for _, t := range timeStates {
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

// parseTimeDefault reads the fields after `time_default` with correlate's
// number grammar (Pack).
func parseTimeDefault(rest []string) (string, TimeDefault, error) {
	return ParseTimeDefault(rest, parseFloat)
}

// ParseTimeDefault reads the fields after `time_default`: the source id, a
// first token without '=', then error_ms, state or both, each at most once.
// number reads error_ms with the grammar of the calling function's pack (the
// quality package passes its own; spec/quality.md, Pack).
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
			if !isTimeState(v) {
				return "", d, fmt.Errorf("time_default: unknown state %q", v)
			}
			d.HasState, d.State = true, v
		default:
			return "", d, fmt.Errorf("time_default: unknown or repeated parameter %q", k)
		}
	}
	return rest[0], d, nil
}

// cleanTimeQuality removes from a report (already cleaned by cleanOptional)
// the time quality keys that are treated as absent: a time_error_ms that is
// not a number, negative or not finite; a time_state that is not one of the
// three states. Neither causes a reject.
func cleanTimeQuality(r map[string]any) map[string]any {
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

// ValidTimeError reads a report's time_error_ms value: a number, finite and 0
// or above. false when it is absent by those rules (null included).
func ValidTimeError(v any) (float64, bool) {
	x, isNum := toFloat(v)
	if !isNum || math.IsNaN(x) || math.IsInf(x, 0) || x < 0 {
		return 0, false
	}
	return x, true
}

// ValidTimeState reads a report's time_state value: one of the three states,
// compared byte for byte. false when it is absent by that rule.
func ValidTimeState(v any) (string, bool) {
	s, isStr := v.(string)
	if !isStr || !isTimeState(s) {
		return "", false
	}
	return s, true
}

// timeQuality returns a report's time error (ms) and time state, each found
// per key: the report's own key, else the pack's time_default for the
// report's source, else error 0 and state coherent. Correlate reads the time
// state but does not use it in this version.
func (g *Engine) timeQuality(source string, report map[string]any) (float64, string) {
	te, state := 0.0, "coherent"
	def, hasDef := g.pack.TimeDefaults[source]
	if v, ok := report["time_error_ms"]; ok {
		te, _ = toFloat(v)
	} else if hasDef && def.HasError {
		te = def.ErrorMs
	}
	if v, ok := report["time_state"]; ok {
		state = v.(string)
	} else if hasDef && def.HasState {
		state = def.State
	}
	return te, state
}

// measurementVariance sets z's position variance per axis (Track estimate,
// Measurement variance) from ce and the time error te in ms, and returns the
// timing variance (v_e*ts)², (v_n*ts)², or 0 and 0 when te is 0. ve, vn is
// the velocity of the entity's prediction to the report's time (for its first
// report, the measured velocity, or 0 without one).
func measurementVariance(z *Measurement, ce, te, ve, vn float64) (float64, float64) {
	if te == 0 {
		z.REast, z.RNorth = ce*ce, ce*ce
		return 0, 0
	}
	ts := te / 1000
	varE, varN := (ve*ts)*(ve*ts), (vn*ts)*(vn*ts)
	z.REast = ce*ce + varE
	z.RNorth = ce*ce + varN
	return varE, varN
}

// timeRecord is the trace record of a report with time error above 0.
func timeRecord(key string, te, varE, varN float64) Obj {
	return Obj{"stage": "filter", "a": key, "b": nil, "test": "time", "value": te, "limit": nil,
		"pass": true, "var_east": varE, "var_north": varN}
}

// withTimingVariance adds an entity's timing variance to the pp of a
// prediction of it that is compared with another entity (Track estimate:
// before any other change to that prediction, such as the bias move).
func withTimingVariance(e *Entity, pe, pn Axis) (Axis, Axis) {
	pe.PP = pe.PP + e.TimeVarEast
	pn.PP = pn.PP + e.TimeVarNorth
	return pe, pn
}
