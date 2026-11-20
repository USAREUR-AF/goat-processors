package model

import (
	"encoding/json"
	"strings"
)

// The report rules of spec/correlate.md Reports, which filter, fuse and
// quality cite.

// RequiredKeys are the required report keys, in the order they are checked.
var RequiredKeys = [...]string{"track.source_id", "uid", "time_ms", "lat", "lon"}

// ToFloat reads a JSON number (or a Go number) as binary64.
func ToFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	}
	return 0, false
}

// ToInt reads a JSON number (or a Go number) as an int64.
func ToInt(v any) (int64, bool) {
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return i, true
		}
		f, err := x.Float64()
		return int64(f), err == nil
	case float64:
		return int64(x), true
	case int:
		return int64(x), true
	case int64:
		return x, true
	}
	return 0, false
}

// IsInt reports whether v is a JSON integer: written without fraction or
// exponent (1000, not 1000.0 or 1e3), within the signed 64-bit range.
func IsInt(v any) bool {
	switch x := v.(type) {
	case json.Number:
		_, err := x.Int64()
		return err == nil && !strings.ContainsAny(string(x), ".eE")
	case int, int64:
		return true
	}
	return false
}

// IsNum reports whether v is a number.
func IsNum(v any) bool { _, ok := ToFloat(v); return ok }

// ValidKey reports whether a report key holds a value of its type: strings
// for track.source_id, uid, type; integers for time_ms, stale_ms; numbers
// for lat, lon, hae, ce, course, speed_ms; any other key any value.
func ValidKey(k string, v any) bool {
	switch k {
	case "track.source_id", "uid", "type":
		_, ok := v.(string)
		return ok
	case "time_ms", "stale_ms":
		return IsInt(v)
	case "lat", "lon", "hae", "ce", "course", "speed_ms":
		return IsNum(v)
	}
	return true
}

// MissingKey returns the first required key without a value of its type,
// or "" when every one has one (the reject reason is "missing:" + that key).
func MissingKey(report map[string]any) string {
	for _, k := range RequiredKeys {
		if !ValidKey(k, report[k]) {
			return k
		}
	}
	return ""
}

// CleanOptional returns a copy of the report without keys that are null,
// optional keys of the wrong type, and a ce of 0 or below, all treated as
// absent.
func CleanOptional(r map[string]any) map[string]any {
	out := make(map[string]any, len(r))
	for k, v := range r {
		if v == nil {
			continue
		}
		switch k {
		case "hae", "ce", "course", "speed_ms", "type", "stale_ms":
			if !ValidKey(k, v) {
				continue
			}
		}
		if k == "ce" {
			if c, _ := ToFloat(v); c <= 0 {
				continue
			}
		}
		out[k] = v
	}
	return out
}

// ReadReport applies the required-key and optional-key rules. It returns
// the report with absent keys removed, or the first missing required key.
func ReadReport(report map[string]any) (clean map[string]any, missing string) {
	if k := MissingKey(report); k != "" {
		return nil, k
	}
	return CleanOptional(report), ""
}

// EntityKey is the entity key <track.source_id>/<uid> of a report whose
// required keys are valid.
func EntityKey(report map[string]any) (source, key string) {
	source = report["track.source_id"].(string)
	return source, source + "/" + report["uid"].(string)
}

// Environment is the third '-'-separated element of a type string.
func Environment(t string) (string, bool) {
	parts := strings.Split(t, "-")
	if len(parts) < 3 {
		return "", false
	}
	return parts[2], true
}

// Reject is the event of a report missing a required key.
func Reject(missing string) Obj { return Obj{"ev": "reject", "reason": "missing:" + missing} }
