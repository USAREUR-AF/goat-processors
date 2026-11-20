package assign

import (
	"fmt"
	"sort"
	"strconv"

	"goat-correlator/engines/go/model"
)

// Memberships (spec: Memberships).

// Membership is one picture of the system tracks.
type Membership struct {
	Systems map[string][]string // system track name -> members in key order
	Next    int                 // the counter that names the next system track
}

func newMembership() Membership { return Membership{Systems: map[string][]string{}, Next: 1} }

func (m Membership) copy() Membership {
	c := Membership{Systems: make(map[string][]string, len(m.Systems)), Next: m.Next}
	for k, v := range m.Systems {
		c.Systems[k] = append([]string(nil), v...)
	}
	return c
}

// order returns the system track names in creation order, which is the order of
// their numbers.
func (m Membership) order() []string {
	names := model.SortedKeys(m.Systems)
	num := func(s string) int { n, _ := strconv.Atoi(s[1:]); return n }
	sort.Slice(names, func(i, j int) bool { return num(names[i]) < num(names[j]) })
	return names
}

// systemOf returns the system track holding entity k, or "".
func (m Membership) systemOf(k string) string {
	for name, members := range m.Systems {
		for _, e := range members {
			if e == k {
				return name
			}
		}
	}
	return ""
}

// leave removes k from its system track (event leave); a track left empty ends (event end).
func (m *Membership) leave(k, reason string, events []Obj) []Obj {
	name := m.systemOf(k)
	events = append(events, Obj{"ev": "leave", "system": name, "entity": k, "reason": reason})
	var rest []string
	for _, e := range m.Systems[name] {
		if e != k {
			rest = append(rest, e)
		}
	}
	if len(rest) > 0 {
		m.Systems[name] = rest
		return events
	}
	delete(m.Systems, name)
	return append(events, Obj{"ev": "end", "system": name})
}

// join adds k to system track name (event join).
func (m *Membership) join(k, name string, events []Obj) []Obj {
	members := append(m.Systems[name], k)
	sort.Strings(members)
	m.Systems[name] = members
	return append(events, Obj{"ev": "join", "system": name, "entity": k})
}

// start makes a new system track holding k alone, named by the counter (event start).
func (m *Membership) start(k string, events []Obj) []Obj {
	name := fmt.Sprintf("s%d", m.Next)
	m.Next++
	m.Systems[name] = []string{k}
	return append(events, Obj{"ev": "start", "system": name, "entity": k})
}

// Choice is one [entity, chosen] pair of a record; chosen is a system track or "alone".
type Choice struct{ Entity, Chosen string }

// Record is one pending tick of a history.
type Record struct {
	Cost    float64
	Choices []Choice
	Events  []Obj
	M       Membership // the membership after that tick
}

// History is a list of pending ticks, oldest first.
type History struct{ Records []Record }

// total is the sum, left to right from 0, of the records' cost, oldest first.
func (h History) total() float64 {
	t := 0.0
	for _, r := range h.Records {
		t = t + r.Cost
	}
	return t
}

// latest returns the membership of the newest record, or the committed one.
func (h History) latest(committed Membership) Membership {
	if len(h.Records) == 0 {
		return committed
	}
	return h.Records[len(h.Records)-1].M
}

func sameChoices(a, b []Choice) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
