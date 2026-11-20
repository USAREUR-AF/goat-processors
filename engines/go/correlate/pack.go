package correlate

import (
	"fmt"
	"strconv"
	"strings"

	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
)

// Test is one configured test from a gate, confirm or hold line (spec: Tests, Pack).
type Test struct {
	Name string
	Num  map[string]float64
	Key  string // for "same"
}

// Pack is a loaded pack.def (spec: correlate.md Pack, correlate-assign.md Pack).
type Pack struct {
	Name    string
	Version string
	model.FilterParams
	Gate         []Test
	Confirm      []Test
	Hold         []Test
	ConfirmCount int64
	HoldFailures int64
	StaleMs      int64
	SameSource   string // "forbid" or "allow"
	Output       string // "priority" or "latest"
	Priority     map[string]int64
	Method       string // a name of the method table (methods.go)
	NewCost      float64
	KeepBonus    float64

	// maneuver line (spec: correlate.md Two-model filter)
	HasManeuver bool
	model.Maneuver

	// method assign window (spec: correlate-assign.md Window)
	Window     int64 // n, default 1
	Hypotheses int64 // k, default 1

	// restart line (spec: correlate.md Restart)
	HasRestart  bool
	RestartGate float64 // g

	// bias line (spec: correlate-assign.md Sensor bias)
	HasBias   bool
	BiasSigma float64 // s
	BiasFloor float64 // f
	BiasGate  float64 // g

	// margin line (spec: correlate-assign.md Window)
	HasMargin bool
	Margin    float64 // m

	// time_default lines, by source id (spec: correlate.md Pack, Time quality)
	TimeDefaults map[string]model.TimeDefault

	// time_offset line (spec: correlate-assign.md Sensor bias, Time offset)
	HasTimeOffset     bool
	TimeOffsetSigmaMs float64 // t
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
	text, err := io.ReadPackDef(dir)
	if err != nil {
		return nil, err
	}
	return ParsePack(text)
}

// parseFloat is the number grammar of the pack: Go's decimal syntax without
// hexadecimal, inf, nan or '_'.
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

// floats reads named parameters of one line into the given fields.
func floats(tokens []string, names []string, into ...*float64) error {
	m, err := io.Params(tokens, names, nil)
	if err != nil {
		return err
	}
	for i, n := range names {
		if *into[i], err = parseFloat(m[n]); err != nil {
			return err
		}
	}
	return nil
}

func parseTest(fields []string) (Test, error) {
	if len(fields) == 0 {
		return Test{}, fmt.Errorf("test name missing")
	}
	names, ok := testParams[fields[0]]
	if !ok {
		return Test{}, fmt.Errorf("unknown test %q", fields[0])
	}
	params, err := io.Params(fields[1:], names, nil)
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

// repeatable are the directives that may be given on more than one line.
var repeatable = map[string]bool{"gate": true, "confirm": true, "hold": true, "priority": true, "time_default": true}

// ParsePack parses the text of a pack.def (spec: Pack).
func ParsePack(text string) (*Pack, error) {
	p := &Pack{SameSource: "forbid", Output: "priority", Priority: map[string]int64{}, Method: "confirm", Window: 1, Hypotheses: 1,
		TimeDefaults: map[string]model.TimeDefault{}}
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
		if !repeatable[d] && seen[d] {
			return nil, fmt.Errorf("line %d: repeated directive %q", n+1, d)
		}
		seen[d] = true
		if err := p.directive(d, rest); err != nil {
			return nil, fmt.Errorf("line %d: %w", n+1, err)
		}
	}
	if err := p.check(seen); err != nil {
		return nil, err
	}
	return p, nil
}

// directive applies one line.
func (p *Pack) directive(d string, rest []string) error {
	var err error
	var v string
	switch d {
	case "pack":
		p.Name, err = oneValue(d, rest)
	case "version":
		p.Version, err = oneValue(d, rest)
	case "filter":
		f := &p.FilterParams
		err = floats(rest, []string{"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"},
			&f.AccelVar, &f.DefaultCeM, &f.VelSigmaMs, &f.UnknownVelMs)
	case "maneuver":
		m := &p.Maneuver
		if err = floats(rest, []string{"accel_var", "p_enter", "p_leave"}, &m.Var, &m.PEnter, &m.PLeave); err == nil {
			p.HasManeuver = true
		}
	case "restart":
		if err = floats(rest, []string{"gate"}, &p.RestartGate); err == nil {
			p.HasRestart = true
			if !(p.RestartGate > 0) {
				err = fmt.Errorf("restart: gate must be above 0")
			}
		}
	case "bias":
		if err = floats(rest, []string{"sigma_m", "floor_m", "gate"}, &p.BiasSigma, &p.BiasFloor, &p.BiasGate); err == nil {
			p.HasBias = true
		}
	case "time_default":
		var src string
		var td model.TimeDefault
		if src, td, err = model.ParseTimeDefault(rest, parseFloat); err == nil {
			if _, dup := p.TimeDefaults[src]; dup {
				err = fmt.Errorf("time_default: second line for source %q", src)
			}
			p.TimeDefaults[src] = td
		}
	case "time_offset":
		if err = floats(rest, []string{"sigma_ms"}, &p.TimeOffsetSigmaMs); err == nil {
			p.HasTimeOffset = true
			if !(p.TimeOffsetSigmaMs > 0) {
				err = fmt.Errorf("time_offset: sigma_ms must be above 0")
			}
		}
	case "margin":
		if v, err = oneValue(d, rest); err == nil {
			p.HasMargin = true
			if p.Margin, err = parseFloat(v); err == nil && !(p.Margin > 0) {
				err = fmt.Errorf("margin must be above 0")
			}
		}
	case "window", "hypotheses":
		if v, err = oneValue(d, rest); err == nil {
			var i int64
			if i, err = parseInt(v); err == nil {
				if i < 1 {
					err = fmt.Errorf("%s must be 1 or above", d)
				} else if d == "window" {
					p.Window = i
				} else {
					p.Hypotheses = i
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
	case "method":
		if v, err = oneValue(d, rest); err == nil {
			if _, known := methods[v]; !known {
				err = fmt.Errorf("unknown method %q", v)
			}
			p.Method = v
		}
	case "new_cost", "keep_bonus":
		if v, err = oneValue(d, rest); err == nil {
			var f float64
			if f, err = parseFloat(v); err == nil {
				if d == "new_cost" {
					p.NewCost = f
				} else {
					p.KeepBonus = f
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
	return err
}

// check applies the method's required and refused directives, then the
// value ranges (spec: correlate.md Pack, correlate-assign.md Pack).
func (p *Pack) check(seen map[string]bool) error {
	m := methods[p.Method]
	for _, d := range m.refused {
		if seen[d] {
			return fmt.Errorf("directive %q not allowed with method %s", d, p.Method)
		}
	}
	for _, d := range m.required {
		if !seen[d] {
			return fmt.Errorf("missing directive %q", d)
		}
	}
	f := p.FilterParams
	if !(f.DefaultCeM > 0 && f.VelSigmaMs > 0 && f.UnknownVelMs > 0 && f.AccelVar >= 0) {
		return fmt.Errorf("filter: default_ce_m, vel_sigma_ms, unknown_vel_ms must be above 0 and accel_var 0 or above")
	}
	if m.check != nil {
		if err := m.check(p); err != nil {
			return err
		}
	}
	if p.HasManeuver && !(p.PEnter > 0 && p.PLeave > 0 && p.PEnter+p.PLeave < 1 && p.Maneuver.Var > p.AccelVar) {
		return fmt.Errorf("maneuver: p_enter and p_leave must be above 0 with a sum below 1, and accel_var above filter's")
	}
	if p.Hypotheses > 1 && p.Window == 1 {
		return fmt.Errorf("hypotheses above 1 needs window above 1")
	}
	if p.HasBias && !(p.BiasSigma > 0 && p.BiasGate > 0 && p.BiasFloor > 0 && p.BiasFloor <= p.BiasSigma) {
		return fmt.Errorf("bias: sigma_m and gate must be above 0, floor_m above 0 and at most sigma_m")
	}
	if p.HasTimeOffset && !p.HasBias {
		return fmt.Errorf("time_offset needs bias")
	}
	if p.HasMargin && p.Hypotheses <= 1 {
		return fmt.Errorf("margin needs hypotheses above 1")
	}
	return nil
}
