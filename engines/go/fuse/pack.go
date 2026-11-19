package fuse

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Kinematics methods and attribute rules (spec/fuse.md: What fuse does, Attributes).
var (
	kinematicsMethods = []string{"inverse_variance", "covariance_intersection", "best", "priority", "latest"}
	attributeRules    = []string{"priority", "latest", "majority", "max", "min"}
	filterParams      = []string{"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"}
	onceOnly          = []string{"pack", "version", "filter", "kinematics", "stale_ms"}
)

// Attribute is one `attribute <key> rule=<rule>` line.
type Attribute struct{ Key, Rule string }

// Pack is a loaded fuse pack.def (spec/fuse.md: Pack).
type Pack struct {
	Name, Version string
	AccelVar      float64
	DefaultCeM    float64
	VelSigmaMs    float64
	UnknownVelMs  float64
	Kinematics    string
	Attributes    []Attribute // pack order
	Sources       []string    // rank order
	StaleMs       int64
}

// Rank is the index of a source among the `source` lines, or -1 when unlisted
// (spec: Kinematics, Rank).
func (p *Pack) Rank(source string) int {
	for i, s := range p.Sources {
		if s == source {
			return i
		}
	}
	return -1
}

// LoadPack reads <dir>/pack.def (spec: load_pack).
func LoadPack(dir string) (*Pack, error) {
	b, err := os.ReadFile(filepath.Join(dir, "pack.def"))
	if err != nil {
		return nil, err
	}
	return ParsePack(string(b))
}

// A number is an optional '-', digits, optionally '.' and digits, optionally
// 'e' or 'E', an optional sign and digits. An integer is digits (spec: Pack).
var (
	numberRe  = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$`)
	integerRe = regexp.MustCompile(`^[0-9]+$`)
)

func parseNumber(s string) (float64, error) {
	if !numberRe.MatchString(s) {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	return strconv.ParseFloat(s, 64)
}

func parseInteger(s string) (int64, error) {
	if !integerRe.MatchString(s) {
		return 0, fmt.Errorf("not an integer: %q", s)
	}
	return strconv.ParseInt(s, 10, 64)
}

func oneOf(v string, list []string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// parseFilter reads the four `name=value` parameters of the filter line.
func parseFilter(p *Pack, values []string) error {
	got := map[string]float64{}
	for _, f := range values {
		name, value, ok := strings.Cut(f, "=")
		if !ok {
			return fmt.Errorf("filter parameter without '=': %q", f)
		}
		if !oneOf(name, filterParams) {
			return fmt.Errorf("unknown filter parameter %q", name)
		}
		if _, dup := got[name]; dup {
			return fmt.Errorf("repeated filter parameter %q", name)
		}
		x, err := parseNumber(value)
		if err != nil {
			return fmt.Errorf("filter %s: %w", name, err)
		}
		got[name] = x
	}
	for _, name := range filterParams {
		if _, ok := got[name]; !ok {
			return fmt.Errorf("missing filter parameter %q", name)
		}
	}
	p.AccelVar, p.DefaultCeM = got["accel_var"], got["default_ce_m"]
	p.VelSigmaMs, p.UnknownVelMs = got["vel_sigma_ms"], got["unknown_vel_ms"]
	if !(p.DefaultCeM > 0 && p.VelSigmaMs > 0 && p.UnknownVelMs > 0) {
		return fmt.Errorf("filter: default_ce_m, vel_sigma_ms, unknown_vel_ms must be above 0")
	}
	if !(p.AccelVar >= 0) {
		return fmt.Errorf("filter: accel_var must be 0 or above")
	}
	return nil
}

// ParsePack parses the text of a pack.def (spec: Pack).
func ParsePack(text string) (*Pack, error) {
	p := &Pack{}
	seen := map[string]bool{}
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })
		if len(fields) == 0 {
			continue
		}
		if err := p.directive(fields[0], fields[1:], seen); err != nil {
			return nil, fmt.Errorf("line %d: %w", n+1, err)
		}
	}
	for _, d := range onceOnly {
		if !seen[d] {
			return nil, fmt.Errorf("missing directive %q", d)
		}
	}
	return p, nil
}

// directive applies one line to the pack, checking the Count and Rule columns.
func (p *Pack) directive(d string, values []string, seen map[string]bool) error {
	if oneOf(d, onceOnly) {
		if seen[d] {
			return fmt.Errorf("repeated directive %q", d)
		}
		seen[d] = true
	}
	one := func() (string, error) {
		if len(values) != 1 {
			return "", fmt.Errorf("%s takes one value, got %d", d, len(values))
		}
		return values[0], nil
	}
	switch d {
	case "pack", "version":
		v, err := one()
		if d == "pack" {
			p.Name = v
		} else {
			p.Version = v
		}
		return err
	case "filter":
		return parseFilter(p, values)
	case "kinematics":
		v, err := one()
		if err != nil {
			return err
		}
		if !oneOf(v, kinematicsMethods) {
			return fmt.Errorf("unknown kinematics method %q", v)
		}
		p.Kinematics = v
	case "stale_ms":
		v, err := one()
		if err != nil {
			return err
		}
		if p.StaleMs, err = parseInteger(v); err != nil {
			return fmt.Errorf("stale_ms: %w", err)
		}
	case "attribute":
		if len(values) != 2 {
			return fmt.Errorf("attribute takes <key> rule=<rule>")
		}
		key := values[0]
		if strings.Contains(key, "=") {
			return fmt.Errorf("attribute key %q holds '='", key)
		}
		rule, ok := strings.CutPrefix(values[1], "rule=")
		if !ok || !oneOf(rule, attributeRules) {
			return fmt.Errorf("attribute %s: expected rule=<%s>", key, strings.Join(attributeRules, "|"))
		}
		for _, a := range p.Attributes {
			if a.Key == key {
				return fmt.Errorf("attribute %q on two lines", key)
			}
		}
		p.Attributes = append(p.Attributes, Attribute{key, rule})
	case "source":
		v, err := one()
		if err != nil {
			return err
		}
		if p.Rank(v) >= 0 {
			return fmt.Errorf("source %q on two lines", v)
		}
		p.Sources = append(p.Sources, v)
	default:
		return fmt.Errorf("unknown directive %q", d)
	}
	return nil
}
