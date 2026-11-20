package fuse

import (
	"goat-correlator/engines/go/model"
)

// group is one output group: its name ("" for an unnamed group) and its members
// in key order.
type group struct {
	name    string
	members []*Entity
}

// groups lists the groups in output order (Groups: Output order of groups):
// named groups in byte order of their name, then the unnamed groups in key order
// of their one member.
func (g *Engine) groups() []group {
	named := map[string][]*Entity{}
	var unnamed []group
	for _, k := range model.SortedKeys(g.entities) {
		e := g.entities[k]
		if e.Group == "" {
			unnamed = append(unnamed, group{"", []*Entity{e}})
		} else {
			named[e.Group] = append(named[e.Group], e)
		}
	}
	var out []group
	for _, name := range model.SortedKeys(named) {
		out = append(out, group{name, named[name]})
	}
	return append(out, unnamed...)
}
