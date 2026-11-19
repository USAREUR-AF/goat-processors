package correlator

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Test is one configured test from a gate, confirm or hold line (spec: Tests, Pack).
type Test struct {
	Name string
	Num  map[string]float64
	Key  string // for "same"
}

// Pack is a loaded pack.def (spec: Pack).
type Pack struct {
	Name         string
	Version      string
	AccelVar     float64
	DefaultCeM   float64
	VelSigmaMs   float64
	UnknownVelMs float64
	Gate         []Test
	Confirm      []Test
	Hold         []Test
	ConfirmCount int64
	HoldFailures int64
	StaleMs      int64
	SameSource   string // "forbid" or "allow"
	Output       string // "priority" or "latest"
	Priority     map[string]int64
}

// testParams lists every test and its parameters (spec: Tests table).
var testParams = map[string][]string{
	"distance":    {"max_m"},
	"window":      {"multiplier", "window_m", "err_min_m", "err_max_m"},
	"mahalanobis": {"gate"},
	"course":      {"max_deg", "min_speed_ms"},
	"speed":       {"max_pct", "min_speed_ms"},
	"altitude":    {"max_m"},
	"same":        {"key"},
}

// LoadPack reads <dir>/pack.def (spec: load_pack).
func LoadPack(dir string) (*Pack, error) {
	b, err := os.ReadFile(filepath.Join(dir, "pack.def"))
	if err != nil {
		return nil, err
	}
	return ParsePack(string(b))
}

func parseFloat(s string) (float64, error) {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || strings.ContainsAny(s, "xXpPiInN_") {
		return 0, fmt.Errorf("not a decimal number: %q", s)
	}
	return v, nil
}

func parseInt(s string) (int64, error) {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("not a decimal integer: %q", s)
	}
	return v, nil
}

// parseParams splits name=value fields and requires exactly the names given.
func parseParams(fields []string, names []string) (map[string]string, error) {
	out := map[string]string{}
	for _, f := range fields {
		k, v, ok := strings.Cut(f, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("parameter without '=': %q", f)
		}
		if _, dup := out[k]; dup {
			return nil, fmt.Errorf("repeated parameter %q", k)
		}
		out[k] = v
	}
	for k := range out {
		known := false
		for _, n := range names {
			if n == k {
				known = true
			}
		}
		if !known {
			return nil, fmt.Errorf("unknown parameter %q", k)
		}
	}
	for _, n := range names {
		if _, ok := out[n]; !ok {
			return nil, fmt.Errorf("missing parameter %q", n)
		}
	}
	return out, nil
}

func parseTest(fields []string) (Test, error) {
	if len(fields) == 0 {
		return Test{}, fmt.Errorf("test name missing")
	}
	names, ok := testParams[fields[0]]
	if !ok {
		return Test{}, fmt.Errorf("unknown test %q", fields[0])
	}
	params, err := parseParams(fields[1:], names)
	if err != nil {
		return Test{}, err
	}
	t := Test{Name: fields[0], Num: map[string]float64{}}
	for k, v := range params {
		if t.Name == "same" {
			t.Key = v
			continue
		}
		f, err := parseFloat(v)
		if err != nil {
			return Test{}, err
		}
		t.Num[k] = f
	}
	return t, nil
}

func oneValue(d string, rest []string) (string, error) {
	if len(rest) != 1 {
		return "", fmt.Errorf("%s takes one value", d)
	}
	return rest[0], nil
}

// ParsePack parses the text of a pack.def (spec: Pack).
func ParsePack(text string) (*Pack, error) {
	p := &Pack{SameSource: "forbid", Output: "priority", Priority: map[string]int64{}}
	seen := map[string]bool{}
	for n, line := range strings.Split(text, "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		d, rest := fields[0], fields[1:]
		repeats := d == "gate" || d == "confirm" || d == "hold" || d == "priority"
		if !repeats {
			if seen[d] {
				return nil, fmt.Errorf("line %d: repeated directive %q", n+1, d)
			}
			seen[d] = true
		}
		var err error
		var v string
		switch d {
		case "pack":
			p.Name, err = oneValue(d, rest)
		case "version":
			p.Version, err = oneValue(d, rest)
		case "filter":
			var m map[string]string
			m, err = parseParams(rest, []string{"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"})
			if err == nil {
				for _, f := range []struct {
					k string
					p *float64
				}{{"accel_var", &p.AccelVar}, {"default_ce_m", &p.DefaultCeM}, {"vel_sigma_ms", &p.VelSigmaMs}, {"unknown_vel_ms", &p.UnknownVelMs}} {
					if *f.p, err = parseFloat(m[f.k]); err != nil {
						break
					}
				}
			}
		case "gate", "confirm", "hold":
			var t Test
			if t, err = parseTest(rest); err == nil {
				switch d {
				case "gate":
					p.Gate = append(p.Gate, t)
				case "confirm":
					p.Confirm = append(p.Confirm, t)
				case "hold":
					p.Hold = append(p.Hold, t)
				}
			}
		case "confirm_count", "hold_failures", "stale_ms":
			if v, err = oneValue(d, rest); err == nil {
				var i int64
				if i, err = parseInt(v); err == nil {
					switch d {
					case "confirm_count":
						p.ConfirmCount = i
					case "hold_failures":
						p.HoldFailures = i
					case "stale_ms":
						p.StaleMs = i
					}
				}
			}
		case "same_source":
			if v, err = oneValue(d, rest); err == nil {
				if v != "forbid" && v != "allow" {
					err = fmt.Errorf("same_source must be forbid or allow")
				}
				p.SameSource = v
			}
		case "output":
			if v, err = oneValue(d, rest); err == nil {
				if v != "priority" && v != "latest" {
					err = fmt.Errorf("output must be priority or latest")
				}
				p.Output = v
			}
		case "priority":
			if len(rest) != 2 {
				err = fmt.Errorf("priority takes <source_id> <n>")
			} else {
				var i int64
				if i, err = parseInt(rest[1]); err == nil {
					p.Priority[rest[0]] = i
				}
			}
		default:
			err = fmt.Errorf("unknown directive %q", d)
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", n+1, err)
		}
	}
	for _, d := range []string{"pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"} {
		if !seen[d] {
			return nil, fmt.Errorf("missing directive %q", d)
		}
	}
	return p, nil
}
