package correlator

// Exported report reading, shared with other functions that cite the Reports
// section of spec/correlate.md (spec/filter.md: Reports).

// RequiredKeys are the required report keys, in the order they are checked.
var RequiredKeys = []string{"track.source_id", "uid", "time_ms", "lat", "lon"}

// ReadReport applies the required-key and optional-key rules of spec/correlate.md
// Reports. It returns the report with absent keys removed, or the first missing
// required key (the reject reason is "missing:" + that key).
func ReadReport(report map[string]any) (clean map[string]any, missing string) {
	for _, k := range RequiredKeys {
		if !validKey(k, report[k]) {
			return nil, k
		}
	}
	return cleanOptional(report), ""
}

// ToFloat reads a JSON number (or a Go number) as binary64.
func ToFloat(v any) (float64, bool) { return toFloat(v) }

// ToInt reads a JSON number (or a Go number) as an int64.
func ToInt(v any) (int64, bool) { return toInt(v) }

// IsInt reports whether v is an integer in the sense of spec/correlate.md Reports.
func IsInt(v any) bool { return isInt(v) }
