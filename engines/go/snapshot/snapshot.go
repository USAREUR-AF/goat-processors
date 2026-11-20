// Package snapshot holds the value encoders every function's Snapshot uses,
// and the decoders its Restore uses to read a snapshot back (a snapshot
// decoded from JSON with numbers as json.Number). Each function's Snapshot
// section is in that function's snapshot.go; this package is the shared part.
package snapshot

import (
	"encoding/json"
	"fmt"

	"goat-correlator/engines/go/model"
)

// Obj is one snapshot object.
type Obj = model.Obj

// Ref is the reference point [lat0, lon0], or null when there is none.
func Ref(f *model.Frame) any {
	if f == nil {
		return nil
	}
	return []any{f.Lat0, f.Lon0}
}

// Filter is the snapshot of a filter: {"east": [...], "north": [...]}.
func Filter(m model.Model) Obj {
	return Obj{"east": m.East.List(), "north": m.North.List()}
}

// OptInt is *p, or null.
func OptInt(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

// OptFloat is *p, or null.
func OptFloat(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

// OptString is *p, or null.
func OptString(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

// Decoder reads a snapshot back; the first error is kept and every later
// read returns a zero value.
type Decoder struct{ Err error }

func (d *Decoder) fail(what string, v any) {
	if d.Err == nil {
		d.Err = fmt.Errorf("snapshot: %s: unexpected %T %v", what, v, v)
	}
}

// Object reads an object.
func (d *Decoder) Object(what string, v any) Obj {
	o, ok := v.(map[string]any)
	if !ok {
		d.fail(what, v)
	}
	return o
}

// List reads a list.
func (d *Decoder) List(what string, v any) []any {
	l, ok := v.([]any)
	if !ok {
		d.fail(what, v)
	}
	return l
}

// Float reads a number.
func (d *Decoder) Float(what string, v any) float64 {
	f, ok := model.ToFloat(v)
	if !ok {
		d.fail(what, v)
	}
	return f
}

// Int reads an integer.
func (d *Decoder) Int(what string, v any) int64 {
	if n, ok := v.(json.Number); ok {
		i, err := n.Int64()
		if err != nil {
			d.fail(what, v)
		}
		return i
	}
	i, ok := v.(int64)
	if !ok {
		d.fail(what, v)
	}
	return i
}

// String reads a string.
func (d *Decoder) String(what string, v any) string {
	s, ok := v.(string)
	if !ok {
		d.fail(what, v)
	}
	return s
}

// Bool reads a boolean.
func (d *Decoder) Bool(what string, v any) bool {
	b, ok := v.(bool)
	if !ok {
		d.fail(what, v)
	}
	return b
}

// OptInt reads an integer or null.
func (d *Decoder) OptInt(what string, v any) *int64 {
	if v == nil {
		return nil
	}
	i := d.Int(what, v)
	return &i
}

// OptFloat reads a number or null.
func (d *Decoder) OptFloat(what string, v any) *float64 {
	if v == nil {
		return nil
	}
	f := d.Float(what, v)
	return &f
}

// OptString reads a string or null.
func (d *Decoder) OptString(what string, v any) *string {
	if v == nil {
		return nil
	}
	s := d.String(what, v)
	return &s
}

// Axis reads [p, v, pp, pv, vv].
func (d *Decoder) Axis(what string, v any) model.Axis {
	l := d.List(what, v)
	if len(l) != 5 {
		d.fail(what, v)
		return model.Axis{}
	}
	return model.Axis{P: d.Float(what, l[0]), V: d.Float(what, l[1]), PP: d.Float(what, l[2]),
		PV: d.Float(what, l[3]), VV: d.Float(what, l[4])}
}

// Filter reads {"east": [...], "north": [...]}.
func (d *Decoder) Filter(what string, v any) model.Model {
	o := d.Object(what, v)
	return model.Model{East: d.Axis(what+".east", o["east"]), North: d.Axis(what+".north", o["north"])}
}

// Ref reads [lat0, lon0] or null.
func (d *Decoder) Ref(v any) *model.Frame {
	if v == nil {
		return nil
	}
	l := d.List("ref", v)
	if len(l) != 2 {
		d.fail("ref", v)
		return nil
	}
	return &model.Frame{Lat0: d.Float("ref", l[0]), Lon0: d.Float("ref", l[1])}
}
