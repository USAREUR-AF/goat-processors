// Package filter implements spec/filter.md (version 0.1): ordered keep/drop
// rules over reports, with state per entity and a forgetting tick.
package filter

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"goat-correlator/engines/go/io"
)

// Condition is one `when` line of a rule (spec: Pack, Conditions).
type Condition struct {
	Name    string // condition name as written: circle, polygon, near, env, ...
	Negated bool   // written with `not`

	// Parameters, parsed. Only those the condition takes are set.
	Lat, Lon, RadiusM float64  // circle; RadiusM also for near
	Vertices          []Vertex // polygon
	Reference         string   // near
	MaxAgeMs          int64    // near
	In                []string // env, affiliation, source, uid, key form in
	KeyName           string   // key, has
	Eq                string   // key form eq
	Min, Max          *float64 // key form range, speed, altitude; nil = no bound
	MinMs             int64    // interval

	eval func(c Condition, r *report, states map[string]*State) result // from the conditions table
}

// Vertex is one polygon vertex, in degrees.
type Vertex struct{ Lat, Lon float64 }

// Rule is a named action with its conditions in pack order.
type Rule struct {
	Name       string
	Action     string // "keep" or "drop"
	Conditions []Condition
}

// Pack is a loaded pack.def.
type Pack struct {
	Name, Version string
	Default       string // "keep" or "drop"
	ForgetMs      int64
	Rules         []Rule
}

// LoadPack reads <dir>/pack.def.
func LoadPack(dir string) (*Pack, error) {
	text, err := io.ReadPackDef(dir)
	if err != nil {
		return nil, err
	}
	return ParsePack(text)
}

// Value grammars (spec: Pack, Values).
var (
	numberRe  = regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
	integerRe = regexp.MustCompile(`^[0-9]+$`)
)

// parseNumber reads a pack number as the nearest binary64.
func parseNumber(s string) (float64, error) {
	if !numberRe.MatchString(s) {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	return strconv.ParseFloat(s, 64)
}

// parseInteger reads a pack integer, at most 9223372036854775807.
func parseInteger(s string) (int64, error) {
	if !integerRe.MatchString(s) {
		return 0, fmt.Errorf("not an integer: %q", s)
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("integer out of range: %q", s)
	}
	return v, nil
}

func parseLat(s string) (float64, error) {
	v, err := parseNumber(s)
	if err == nil && (v < -90 || v > 90) {
		err = fmt.Errorf("lat out of range: %q", s)
	}
	return v, err
}

func parseLon(s string) (float64, error) {
	v, err := parseNumber(s)
	if err == nil && (v < -180 || v > 180) {
		err = fmt.Errorf("lon out of range: %q", s)
	}
	return v, err
}

// parseVertices reads `<lat>,<lon>;<lat>,<lon>;...`, at least three pairs.
func parseVertices(s string) ([]Vertex, error) {
	var out []Vertex
	for _, pair := range strings.Split(s, ";") {
		la, lo, ok := strings.Cut(pair, ",")
		if !ok {
			return nil, fmt.Errorf("bad vertex: %q", pair)
		}
		lat, err := parseLat(la)
		if err != nil {
			return nil, err
		}
		lon, err := parseLon(lo)
		if err != nil {
			return nil, err
		}
		out = append(out, Vertex{lat, lon})
	}
	if len(out) < 3 {
		return nil, fmt.Errorf("polygon needs at least three vertices: %q", s)
	}
	return out, nil
}

// parseList reads `in`: one or more non-empty items separated by `,`.
func parseList(s string) ([]string, error) {
	items := strings.Split(s, ",")
	for _, it := range items {
		if it == "" {
			return nil, fmt.Errorf("empty list item in %q", s)
		}
	}
	return items, nil
}

func nonEmpty(name, s string) (string, error) {
	if s == "" {
		return "", fmt.Errorf("%s is empty", name)
	}
	return s, nil
}

// matchesSet reports whether the given parameter names are exactly one of the sets.
func matchesSet(params map[string]string, sets [][]string) bool {
	for _, set := range sets {
		if len(set) != len(params) {
			continue
		}
		all := true
		for _, n := range set {
			if _, ok := params[n]; !ok {
				all = false
			}
		}
		if all {
			return true
		}
	}
	return false
}

// parseWhen reads the arguments of a `when` line:
// [not] <condition> <param>=<value> ...
func parseWhen(args []string) (Condition, error) {
	var c Condition
	if len(args) > 0 && args[0] == "not" {
		c.Negated = true
		args = args[1:]
	}
	if len(args) == 0 {
		return c, fmt.Errorf("when without a condition")
	}
	c.Name = args[0]
	kind, ok := conditions[c.Name]
	if !ok {
		return c, fmt.Errorf("unknown condition %q", c.Name)
	}

	// name=value; the name is the text before the first `=`.
	params := map[string]string{}
	for _, a := range args[1:] {
		k, v, ok := strings.Cut(a, "=")
		if !ok {
			return c, fmt.Errorf("parameter without '=': %q", a)
		}
		if _, dup := params[k]; dup {
			return c, fmt.Errorf("parameter given twice: %q", k)
		}
		params[k] = v
	}
	c.eval = kind.eval
	if !matchesSet(params, kind.sets) {
		return c, fmt.Errorf("condition %s: wrong parameters", c.Name)
	}

	// Values and their limits (spec: Pack, Values).
	var err error
	for k, v := range params {
		switch k {
		case "lat":
			c.Lat, err = parseLat(v)
		case "lon":
			c.Lon, err = parseLon(v)
		case "radius_m":
			c.RadiusM, err = parseNumber(v)
			if err == nil && c.RadiusM < 0 {
				err = fmt.Errorf("radius_m below 0: %q", v)
			}
		case "vertices":
			c.Vertices, err = parseVertices(v)
		case "reference":
			c.Reference, err = nonEmpty(k, v)
		case "max_age_ms":
			c.MaxAgeMs, err = parseInteger(v)
		case "in":
			c.In, err = parseList(v)
		case "name":
			c.KeyName, err = nonEmpty(k, v)
		case "eq":
			c.Eq, err = nonEmpty(k, v)
		case "min", "max":
			var f float64
			f, err = parseNumber(v)
			if k == "min" {
				c.Min = &f
			} else {
				c.Max = &f
			}
		case "min_ms":
			c.MinMs, err = parseInteger(v)
			if err == nil && c.MinMs <= 0 {
				err = fmt.Errorf("min_ms must be above 0: %q", v)
			}
		}
		if err != nil {
			return c, err
		}
	}
	if c.Min != nil && c.Max != nil && *c.Min > *c.Max {
		return c, fmt.Errorf("min above max")
	}
	return c, nil
}

func parseAction(s string) (string, error) {
	if s != "keep" && s != "drop" {
		return "", fmt.Errorf("action must be keep or drop: %q", s)
	}
	return s, nil
}

// ParsePack reads the text of a pack.def (spec: Pack).
func ParsePack(text string) (*Pack, error) {
	p := &Pack{}
	seen := map[string]bool{} // pack, version, default, forget_ms
	ruleNames := map[string]bool{}
	current := -1 // index of the rule `when` lines attach to; -1 before the first rule

	for n, line := range strings.Split(text, "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' || r == '\r' })
		if len(fields) == 0 {
			continue
		}
		d, args := fields[0], fields[1:]
		fail := func(err error) (*Pack, error) { return nil, fmt.Errorf("line %d: %v", n+1, err) }

		switch d {
		case "pack", "version", "default", "forget_ms":
			if seen[d] {
				return fail(fmt.Errorf("repeated %s", d))
			}
			seen[d] = true
			if len(args) != 1 {
				return fail(fmt.Errorf("%s takes one argument", d))
			}
			var err error
			switch d {
			case "pack":
				p.Name = args[0]
			case "version":
				p.Version = args[0]
			case "default":
				p.Default, err = parseAction(args[0])
			case "forget_ms":
				p.ForgetMs, err = parseInteger(args[0])
				if err == nil && p.ForgetMs <= 0 {
					err = fmt.Errorf("forget_ms must be above 0")
				}
			}
			if err != nil {
				return fail(err)
			}

		case "rule":
			if len(args) != 2 {
				return fail(fmt.Errorf("rule takes a name and an action"))
			}
			name := args[0]
			if name == "default" {
				return fail(fmt.Errorf("a rule cannot be named default"))
			}
			if ruleNames[name] {
				return fail(fmt.Errorf("two rules named %q", name))
			}
			ruleNames[name] = true
			action, err := parseAction(args[1])
			if err != nil {
				return fail(err)
			}
			p.Rules = append(p.Rules, Rule{Name: name, Action: action})
			current = len(p.Rules) - 1

		case "when":
			if current < 0 {
				return fail(fmt.Errorf("when before the first rule"))
			}
			c, err := parseWhen(args)
			if err != nil {
				return fail(err)
			}
			p.Rules[current].Conditions = append(p.Rules[current].Conditions, c)

		default:
			return fail(fmt.Errorf("unknown directive %q", d))
		}
	}

	for _, d := range []string{"pack", "version", "default", "forget_ms"} {
		if !seen[d] {
			return nil, fmt.Errorf("missing %s", d)
		}
	}
	for _, r := range p.Rules {
		if len(r.Conditions) == 0 {
			return nil, fmt.Errorf("rule %q has no when line", r.Name)
		}
	}
	return p, nil
}
