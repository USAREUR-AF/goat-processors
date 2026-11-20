package filter

import (
	"strings"

	"goat-correlator/engines/go/model"
)

// report is one accepted report, read by the rules of Reports.
type report struct {
	key      string         // entity key <track.source_id>/<uid>
	values   map[string]any // the report with absent keys removed
	source   string
	uid      string
	timeMs   int64
	lat, lon float64
}

func (r *report) num(k string) *float64 {
	if v, ok := r.values[k]; ok {
		f, _ := model.ToFloat(v)
		return &f
	}
	return nil
}

func (r *report) str(k string) (string, bool) {
	s, ok := r.values[k].(string)
	return s, ok
}

// environment is the third `-`-separated element of type (spec: Reports).
func (r *report) environment() (string, bool) {
	t, ok := r.str("type")
	if !ok {
		return "", false
	}
	return model.Environment(t)
}

// affiliation is the second element of type when the first is exactly `a`.
func (r *report) affiliation() (string, bool) {
	t, ok := r.str("type")
	if !ok {
		return "", false
	}
	parts := strings.Split(t, "-")
	if len(parts) < 2 || parts[0] != "a" {
		return "", false
	}
	return parts[1], true
}
