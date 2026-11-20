package snapshot

import (
	"bytes"
	"encoding/json"
	"testing"

	"goat-correlator/engines/go/model"
)

func TestEncoders(t *testing.T) {
	if Ref(nil) != nil {
		t.Error("Ref(nil)")
	}
	r := Ref(&model.Frame{Lat0: 1, Lon0: 2}).([]any)
	if r[0] != 1.0 || r[1] != 2.0 {
		t.Errorf("Ref = %v", r)
	}
	i, f, s := int64(3), 2.5, "x"
	if OptInt(nil) != nil || OptInt(&i) != int64(3) || OptFloat(nil) != nil || OptFloat(&f) != 2.5 ||
		OptString(nil) != nil || OptString(&s) != "x" {
		t.Error("Opt*")
	}
	m := model.Model{East: model.Axis{P: 1, V: 2, PP: 3, PV: 4, VV: 5}, North: model.Axis{P: 6}}
	if fl := Filter(m); len(fl["east"].([]any)) != 5 {
		t.Errorf("Filter = %v", fl)
	}
}

// TestDecoderRoundTrip encodes values, decodes them as JSON does, and reads them back.
func TestDecoderRoundTrip(t *testing.T) {
	i, f, s := int64(-7), 0.1, "drifting"
	m := model.Model{East: model.Axis{P: 1.25, V: -2, PP: 3e-9, PV: 4, VV: 5}, North: model.Axis{P: 6, V: 7, PP: 8, PV: 9, VV: 10}}
	snap := Obj{"ref": Ref(&model.Frame{Lat0: 50.1, Lon0: -8}), "i": i, "f": f, "s": s, "b": true,
		"oi": OptInt(&i), "of": OptFloat(&f), "os": OptString(&s), "ni": OptInt(nil), "nf": OptFloat(nil), "ns": OptString(nil),
		"filter": Filter(m), "list": []any{1, 2}}
	for _, decoded := range []bool{false, true} {
		v := snap
		if decoded {
			b, _ := json.Marshal(snap)
			d := json.NewDecoder(bytes.NewReader(b))
			d.UseNumber()
			v = nil
			if err := d.Decode(&v); err != nil {
				t.Fatal(err)
			}
		}
		var d Decoder
		ref := d.Ref(v["ref"])
		got := d.Filter("filter", v["filter"])
		if ref == nil || ref.Lat0 != 50.1 || ref.Lon0 != -8 || got != m {
			t.Errorf("decoded=%v: ref %v filter %v", decoded, ref, got)
		}
		if d.Int("i", v["i"]) != i || d.Float("f", v["f"]) != f || d.String("s", v["s"]) != s || !d.Bool("b", v["b"]) {
			t.Errorf("decoded=%v: scalars", decoded)
		}
		if *d.OptInt("oi", v["oi"]) != i || *d.OptFloat("of", v["of"]) != f || *d.OptString("os", v["os"]) != s {
			t.Errorf("decoded=%v: optional values", decoded)
		}
		if d.OptInt("ni", v["ni"]) != nil || d.OptFloat("nf", v["nf"]) != nil || d.OptString("ns", v["ns"]) != nil || d.Ref(nil) != nil {
			t.Errorf("decoded=%v: nulls", decoded)
		}
		if len(d.List("list", v["list"])) != 2 || d.Object("o", map[string]any{}) == nil {
			t.Errorf("decoded=%v: containers", decoded)
		}
		if d.Err != nil {
			t.Errorf("decoded=%v: %v", decoded, d.Err)
		}
	}
}

func TestDecoderErrors(t *testing.T) {
	for name, read := range map[string]func(d *Decoder){
		"object":   func(d *Decoder) { d.Object("x", 1) },
		"list":     func(d *Decoder) { d.List("x", "a") },
		"float":    func(d *Decoder) { d.Float("x", "a") },
		"int":      func(d *Decoder) { d.Int("x", 2.5) },
		"int text": func(d *Decoder) { d.Int("x", json.Number("2.5")) },
		"string":   func(d *Decoder) { d.String("x", 1) },
		"bool":     func(d *Decoder) { d.Bool("x", "true") },
		"axis":     func(d *Decoder) { d.Axis("x", []any{1.0}) },
		"ref":      func(d *Decoder) { d.Ref([]any{1.0}) },
		"filter":   func(d *Decoder) { d.Filter("x", map[string]any{"east": []any{}}) },
	} {
		var d Decoder
		read(&d)
		if d.Err == nil {
			t.Errorf("%s: no error", name)
		}
		first := d.Err
		d.Fail("later", nil)
		if d.Err != first {
			t.Errorf("%s: a later failure replaced the first", name)
		}
	}
}
