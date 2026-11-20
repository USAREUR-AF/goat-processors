// Package quality is the Go engine of spec/quality.md (version 0.2).
//
// Each file implements named sections of the specification:
//
//	pack.go        Pack (the pack.def reader)
//	engine.go      What quality does (Engine, New, Load)
//	reports.go     Reports
//	time.go        Reports, Time quality; Input clock
//	ingest.go      Order, Frame and filter, Samples, Ingest
//	forwarding.go  Forwarding
//	measures.go    Window, Entity measures, Source measures
//	tick.go        Tick
//	rules.go       Rules
//	snapshot.go    Snapshot
//
// The frame, the filter, the report type checks and the time quality keys
// and time_default line are package model's (spec/correlate.md 0.8), as
// spec/quality.md cites correlate.md for them.
package quality

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"

	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
)

// Rule is one rule line (spec: Rules, Pack).
type Rule struct {
	Name    string
	Scope   string // "entity" or "source"
	Measure string
	Op      string // "<", "<=", ">", ">="
	Limit   float64
	For     int64
	Clear   float64
	Action  string  // "mark", "downgrade", "drop", "alert"
	Factor  float64 // downgrade only
}

// Pack is a loaded pack.def (spec: Pack).
type Pack struct {
	Name, Version string

	// filter line, the parameters of correlate.md Track estimate
	AccelVar, DefaultCeM, VelSigmaMs, UnknownVelMs float64

	// window line
	WindowMs, MinSamples, ForgetMs int64

	Rules []Rule // pack order

	// time_default lines by source id (spec: Reports, Time quality)
	TimeDefaults map[string]model.TimeDefault
}

// entityMeasures and sourceMeasures are the measures tables, in table order
// (spec: Entity measures, Source measures).
var entityMeasures = []string{
	"reports", "interval_last", "interval_mean", "interval_max", "age",
	"latency_mean", "latency_max", "lateness_mean", "lateness_max", "lateness_min",
	"nis_mean", "speed_err_mean", "out_of_order", "duplicate", "source_out_of_order",
	"missing_ce", "missing_vel", "missing_hae",
	"time_error_mean", "time_error_max", "time_state_last", "time_state_worst", "missing_time",
}

var sourceMeasures = append(append([]string{}, entityMeasures...), "entities")

// Values (spec: Pack, Values).
var (
	numberRe   = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
	integerRe  = regexp.MustCompile(`^[0-9]+$`)
	ruleNameRe = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

func parseNumber(s string) (float64, error) {
	if !numberRe.MatchString(s) {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	x, err := strconv.ParseFloat(s, 64) // nearest binary64
	if err != nil || math.IsInf(x, 0) {
		return 0, fmt.Errorf("number not finite: %q", s)
	}
	return x, nil
}

func parseInteger(s string) (int64, error) {
	if !integerRe.MatchString(s) {
		return 0, fmt.Errorf("not an integer: %q", s)
	}
	return strconv.ParseInt(s, 10, 64)
}

// LoadPack reads <dir>/pack.def (spec: load_pack).
func LoadPack(dir string) (*Pack, error) {
	text, err := io.ReadPackDef(dir)
	if err != nil {
		return nil, err
	}
	return ParsePack(text)
}

// params splits name=value tokens. Every name must be in required or optional,
// appear at most once, and every required name must be present.
func params(tokens []string, required, optional []string) (map[string]string, error) {
	known := map[string]bool{}
	for _, n := range required {
		known[n] = true
	}
	for _, n := range optional {
		known[n] = true
	}
	out := map[string]string{}
	for _, tok := range tokens {
		name, value, ok := strings.Cut(tok, "=")
		if !ok {
			return nil, fmt.Errorf("parameter without '=': %q", tok)
		}
		if !known[name] {
			return nil, fmt.Errorf("unknown parameter %q", name)
		}
		if _, seen := out[name]; seen {
			return nil, fmt.Errorf("repeated parameter %q", name)
		}
		out[name] = value
	}
	for _, n := range required {
		if _, ok := out[n]; !ok {
			return nil, fmt.Errorf("missing parameter %q", n)
		}
	}
	return out, nil
}

// ParsePack parses the text of a pack.def (spec: Pack). Every row of the
// load-error table is a returned error.
func ParsePack(text string) (*Pack, error) {
	p := &Pack{TimeDefaults: map[string]model.TimeDefault{}}
	seen := map[string]bool{}
	ruleNames := map[string]bool{}
	for n, line := range packLines(text) {
		// 2. A control character other than tab, or a CR left inside the line.
		if hasControl(line) {
			return nil, fmt.Errorf("pack.def line %d: control character", n+1)
		}
		// 3. A comment runs to the end of the line.
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		// 4 and 5. Tokens are separated by runs of space and tab only; an empty
		// line is ignored.
		tokens := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		if len(tokens) == 0 {
			continue
		}
		directive, rest := tokens[0], tokens[1:]
		var err error
		switch directive {
		case "pack", "version", "filter", "window":
			if seen[directive] {
				err = fmt.Errorf("repeated directive")
				break
			}
			seen[directive] = true
			switch directive {
			case "pack", "version":
				if len(rest) != 1 {
					err = fmt.Errorf("needs exactly one value")
				} else if directive == "pack" {
					p.Name = rest[0]
				} else {
					p.Version = rest[0]
				}
			case "filter":
				err = p.parseFilter(rest)
			case "window":
				err = p.parseWindow(rest)
			}
		case "rule":
			var r Rule
			r, err = parseRule(rest)
			if err == nil && ruleNames[r.Name] {
				err = fmt.Errorf("rule name %q used by an earlier rule", r.Name)
			}
			if err == nil {
				ruleNames[r.Name] = true
				p.Rules = append(p.Rules, r)
			}
		case "time_default":
			// The grammar of correlate.md, Pack, with this pack's number grammar.
			var source string
			var d model.TimeDefault
			source, d, err = model.ParseTimeDefault(rest, parseNumber)
			if _, given := p.TimeDefaults[source]; err == nil && given {
				err = fmt.Errorf("source %q given on an earlier time_default", source)
			}
			if err == nil {
				p.TimeDefaults[source] = d
			}
		default:
			err = fmt.Errorf("unknown directive")
		}
		if err != nil {
			return nil, fmt.Errorf("pack.def line %d (%s): %w", n+1, directive, err)
		}
	}
	for _, d := range []string{"pack", "version", "filter", "window"} {
		if !seen[d] {
			return nil, fmt.Errorf("pack.def: missing directive %q", d)
		}
	}
	return p, nil
}

// packLines splits pack.def text into lines (spec: Pack, step 1). Lines end at
// LF; one CR at the end of a line is removed; a final LF does not start
// another line.
func packLines(text string) []string {
	text = strings.TrimSuffix(text, "\n")
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimSuffix(line, "\r")
	}
	return lines
}

// hasControl reports whether a line holds U+0000 to U+001F other than tab, or
// U+007F (spec: Pack, step 2). A CR still in the line is one of them.
func hasControl(line string) bool {
	for i := 0; i < len(line); i++ {
		c := line[i]
		if (c < 0x20 && c != '\t') || c == 0x7f {
			return true
		}
	}
	return false
}

func (p *Pack) parseFilter(tokens []string) error {
	m, err := params(tokens, []string{"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"}, nil)
	if err != nil {
		return err
	}
	v := map[string]float64{}
	for k, s := range m {
		if v[k], err = parseNumber(s); err != nil {
			return err
		}
	}
	if v["accel_var"] < 0 {
		return fmt.Errorf("accel_var below 0")
	}
	for _, k := range []string{"default_ce_m", "vel_sigma_ms", "unknown_vel_ms"} {
		if v[k] <= 0 {
			return fmt.Errorf("%s 0 or below", k)
		}
	}
	p.AccelVar, p.DefaultCeM, p.VelSigmaMs, p.UnknownVelMs = v["accel_var"], v["default_ce_m"], v["vel_sigma_ms"], v["unknown_vel_ms"]
	return nil
}

func (p *Pack) parseWindow(tokens []string) error {
	m, err := params(tokens, []string{"window_ms", "min_samples", "forget_ms"}, nil)
	if err != nil {
		return err
	}
	v := map[string]int64{}
	for k, s := range m {
		if v[k], err = parseInteger(s); err != nil {
			return err
		}
		if v[k] < 1 {
			return fmt.Errorf("%s below 1", k)
		}
	}
	p.WindowMs, p.MinSamples, p.ForgetMs = v["window_ms"], v["min_samples"], v["forget_ms"]
	return nil
}

func parseRule(tokens []string) (Rule, error) {
	var r Rule
	if len(tokens) == 0 || !ruleNameRe.MatchString(tokens[0]) {
		return r, fmt.Errorf("rule without a valid name")
	}
	r.Name = tokens[0]
	m, err := params(tokens[1:], []string{"scope", "measure", "op", "limit", "for", "clear", "action"}, []string{"factor"})
	if err != nil {
		return r, err
	}
	r.Scope, r.Measure, r.Op, r.Action = m["scope"], m["measure"], m["op"], m["action"]

	var measures []string
	switch r.Scope {
	case "entity":
		measures = entityMeasures
	case "source":
		measures = sourceMeasures
	default:
		return r, fmt.Errorf("scope %q", r.Scope)
	}
	if !contains(measures, r.Measure) {
		return r, fmt.Errorf("measure %q not a %s measure", r.Measure, r.Scope)
	}
	if !contains([]string{"<", "<=", ">", ">="}, r.Op) {
		return r, fmt.Errorf("op %q", r.Op)
	}
	if !contains([]string{"mark", "downgrade", "drop", "alert"}, r.Action) {
		return r, fmt.Errorf("action %q", r.Action)
	}
	if r.Limit, err = parseNumber(m["limit"]); err != nil {
		return r, err
	}
	if r.Clear, err = parseNumber(m["clear"]); err != nil {
		return r, err
	}
	if r.For, err = parseInteger(m["for"]); err != nil {
		return r, err
	}
	if r.For < 1 {
		return r, fmt.Errorf("for below 1")
	}
	if above(r.Op) && r.Clear > r.Limit {
		return r, fmt.Errorf("clear above limit for op %s", r.Op)
	}
	if !above(r.Op) && r.Clear < r.Limit {
		return r, fmt.Errorf("clear below limit for op %s", r.Op)
	}
	factor, hasFactor := m["factor"]
	switch {
	case r.Action == "downgrade" && !hasFactor:
		return r, fmt.Errorf("downgrade without factor")
	case r.Action != "downgrade" && hasFactor:
		return r, fmt.Errorf("factor with action %s", r.Action)
	case hasFactor:
		if r.Factor, err = parseNumber(factor); err != nil {
			return r, err
		}
		if r.Factor < 1 {
			return r, fmt.Errorf("factor below 1")
		}
	}
	return r, nil
}

// above reports whether op is > or >=: the rule watches for a measure above its limit.
func above(op string) bool { return op == ">" || op == ">=" }

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
