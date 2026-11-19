package quality

// Tick runs the steps of spec: Tick, in order.
func (g *Engine) Tick(now int64) (events, trace []Obj) {
	// 1. Order. An equal tick runs.
	if g.lastTick != nil && now < *g.lastTick {
		return []Obj{{"ev": "reject", "reason": "tick-out-of-order"}}, []Obj{}
	}
	g.lastTick = &now
	events, trace = []Obj{}, []Obj{}

	sourcesAtStart := map[string]bool{}
	for _, e := range g.entities {
		sourcesAtStart[e.source] = true
	}

	// 2. Forget entities, key order.
	for _, key := range sortedKeys(g.entities) {
		if now-g.entities[key].last > g.pack.ForgetMs {
			events = append(events, g.forgetSubject("entity", key)...)
			delete(g.entities, key)
			events = append(events, Obj{"ev": "forget", "entity": key})
		}
	}

	// 3. Forget sources, key order: those that had entities and have none now.
	sources := g.sources()
	for _, source := range sortedKeys(sourcesAtStart) {
		if _, still := sources[source]; !still {
			events = append(events, g.forgetSubject("source", source)...)
			events = append(events, Obj{"ev": "forget", "source": source})
		}
	}

	// 4. Window.
	for _, e := range g.entities {
		e.dropOld(now, g.pack.WindowMs)
	}

	// 5. Entities, key order: measures, quality event, entity rules.
	measures := map[string]Obj{}
	for _, key := range sortedKeys(g.entities) {
		m := g.measures(g.entities[key], now)
		measures[key] = m
		events = append(events, Obj{"ev": "quality", "scope": "entity", "subject": key, "measures": m})
		events, trace = g.evaluate("entity", key, m, events, trace)
	}

	// 6. Sources, key order: measures, quality event, source rules.
	for _, source := range sortedKeys(sources) {
		var of []Obj
		for _, key := range sources[source] { // key order
			of = append(of, measures[key])
		}
		m := sourceMeasuresOf(of)
		events = append(events, Obj{"ev": "quality", "scope": "source", "subject": source, "measures": m})
		events, trace = g.evaluate("source", source, m, events, trace)
	}
	return events, trace
}

// sources maps each source to its entity keys in key order (spec: Source measures).
func (g *Engine) sources() map[string][]string {
	out := map[string][]string{}
	for _, key := range sortedKeys(g.entities) {
		s := g.entities[key].source
		out[s] = append(out[s], key)
	}
	return out
}

// forgetSubject ends every active rule of the scope for the subject, in pack
// order, and removes every rule state for it (spec: Tick, steps 2 and 3).
func (g *Engine) forgetSubject(scope, subject string) []Obj {
	var events []Obj
	for i, rule := range g.pack.Rules {
		if rule.Scope != scope {
			continue
		}
		if st := g.states[i][subject]; st != nil && st.active {
			events = append(events, Obj{"ev": "action-end", "rule": rule.Name, "scope": scope,
				"subject": subject, "action": rule.Action, "reason": "forget", "value": nil})
		}
		delete(g.states[i], subject)
	}
	return events
}

// holds reports whether `v op x` holds, compared as binary64 (spec: Rules).
func holds(v float64, op string, x float64) bool {
	switch op {
	case "<":
		return v < x
	case "<=":
		return v <= x
	case ">":
		return v > x
	}
	return v >= x
}

// evaluate runs each rule of the scope for the subject, in pack order
// (spec: Rules, Evaluation; Trace).
func (g *Engine) evaluate(scope, subject string, m Obj, events, trace []Obj) ([]Obj, []Obj) {
	for i, rule := range g.pack.Rules {
		if rule.Scope != scope {
			continue
		}
		st := g.states[i][subject]
		if st == nil {
			st = &ruleState{}
			g.states[i][subject] = st
		}
		value := m[rule.Measure]
		v, present := asFloat(value)
		var limit float64
		var pass bool
		if !st.active {
			// Not active: count met conditions until `for`.
			limit = rule.Limit
			pass = present && holds(v, rule.Op, rule.Limit)
			if pass {
				st.count++
			} else {
				st.count = 0
			}
			if st.count >= rule.For {
				st.active, st.count = true, 0
				events = append(events, Obj{"ev": "action-start", "rule": rule.Name, "scope": scope,
					"subject": subject, "action": rule.Action, "value": value})
			}
		} else {
			// Active: clear on the other side of `clear`; an absent value never clears.
			limit = rule.Clear
			if above(rule.Op) {
				pass = present && v < rule.Clear
			} else {
				pass = present && v > rule.Clear
			}
			if pass {
				st.active = false
				events = append(events, Obj{"ev": "action-end", "rule": rule.Name, "scope": scope,
					"subject": subject, "action": rule.Action, "reason": "clear", "value": value})
			}
		}
		trace = append(trace, Obj{"stage": "rule", "rule": rule.Name, "subject": subject,
			"measure": rule.Measure, "value": value, "limit": limit, "pass": pass,
			"count": st.count, "active": st.active})
	}
	return events, trace
}
