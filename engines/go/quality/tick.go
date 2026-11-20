package quality

import (
	"goat-correlator/engines/go/model"
)

// Tick runs the steps of spec: Tick, in order.
func (g *Engine) Tick(now int64) (events, tr []Obj) {
	// 1. Order. An equal tick runs.
	if g.lastTick != nil && now < *g.lastTick {
		return []Obj{{"ev": "reject", "reason": "tick-out-of-order"}}, []Obj{}
	}
	g.lastTick = &now
	events, tr = []Obj{}, []Obj{}

	sourcesAtStart := map[string]bool{}
	for _, e := range g.entities {
		sourcesAtStart[e.source] = true
	}

	// 2. Forget entities, key order.
	for _, key := range model.SortedKeys(g.entities) {
		if now-g.entities[key].last > g.pack.ForgetMs {
			events = append(events, g.forgetSubject("entity", key)...)
			delete(g.entities, key)
			events = append(events, Obj{"ev": "forget", "entity": key})
		}
	}

	// 3. Forget sources, key order: those that had entities and have none now.
	sources := g.sources()
	for _, source := range model.SortedKeys(sourcesAtStart) {
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
	for _, key := range model.SortedKeys(g.entities) {
		m := g.measures(g.entities[key], now)
		measures[key] = m
		events = append(events, Obj{"ev": "quality", "scope": "entity", "subject": key, "measures": m})
		events, tr = g.evaluate("entity", key, m, events, tr)
	}

	// 6. Sources, key order: measures, quality event, source rules.
	for _, source := range model.SortedKeys(sources) {
		var of []Obj
		for _, key := range sources[source] { // key order
			of = append(of, measures[key])
		}
		m := sourceMeasuresOf(of)
		events = append(events, Obj{"ev": "quality", "scope": "source", "subject": source, "measures": m})
		events, tr = g.evaluate("source", source, m, events, tr)
	}
	return events, tr
}

// sources maps each source to its entity keys in key order (spec: Source measures).
func (g *Engine) sources() map[string][]string {
	out := map[string][]string{}
	for _, key := range model.SortedKeys(g.entities) {
		s := g.entities[key].source
		out[s] = append(out[s], key)
	}
	return out
}
