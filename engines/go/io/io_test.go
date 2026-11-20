package io

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"goat-correlator/engines/go/model"
)

func TestDecodeObject(t *testing.T) {
	v, err := DecodeObject([]byte(`{"a": 1.50, "b": [true, null], "c": {"d": "x"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if v["a"] != json.Number("1.50") {
		t.Errorf("a = %#v: numbers are kept as written", v["a"])
	}
	for _, bad := range []string{``, `[1]`, `null`, `{"a":`, `"x"`} {
		if _, err := DecodeObject([]byte(bad)); err == nil {
			t.Errorf("%q decodes", bad)
		}
	}
}

func TestReadObjectAndPackDef(t *testing.T) {
	dir := t.TempDir()
	if _, err := ReadObject(filepath.Join(dir, "none.json")); err == nil {
		t.Error("a missing file reads")
	}
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte("{"), 0o644)
	if _, err := ReadObject(bad); err == nil || !strings.Contains(err.Error(), "bad.json") {
		t.Errorf("err = %v", err)
	}
	if _, err := ReadPackDef(dir); err == nil {
		t.Error("a missing pack.def reads")
	}
	os.WriteFile(filepath.Join(dir, "pack.def"), []byte("pack x\n"), 0o644)
	if text, err := ReadPackDef(dir); err != nil || text != "pack x\n" {
		t.Errorf("ReadPackDef = %q, %v", text, err)
	}
}

func TestParseSteps(t *testing.T) {
	doc, _ := DecodeObject([]byte(`{"name": "x", "steps": [{"ingest": {"uid": "u"}, "expect": []}, {"tick": 5000, "trace": []}]}`))
	steps, err := ParseSteps(doc)
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 2 || steps[0].Report["uid"] != "u" || steps[1].Report != nil || steps[1].Now != 5000 {
		t.Errorf("steps = %v", steps)
	}
	for _, bad := range []string{`{}`, `{"steps": {}}`, `{"steps": [1]}`, `{"steps": [{"ingest": 1}]}`,
		`{"steps": [{"name": "x"}]}`, `{"steps": [{"tick": 1.5}]}`, `{"steps": [{"tick": "1"}]}`} {
		doc, _ := DecodeObject([]byte(bad))
		if _, err := ParseSteps(doc); err == nil {
			t.Errorf("%s parses", bad)
		}
	}
}

// echo is an engine that returns what it was given.
type echo struct{ n int }

func (e *echo) Ingest(r map[string]any) ([]model.Obj, []model.Obj) {
	e.n++
	return []model.Obj{{"ev": "in", "uid": r["uid"]}}, nil
}
func (e *echo) Tick(now int64) ([]model.Obj, []model.Obj) {
	return nil, []model.Obj{{"stage": "tick", "value": now}}
}
func (e *echo) Snapshot() model.Obj { return model.Obj{"n": e.n} }

func TestRunAndEvents(t *testing.T) {
	steps := []Step{{Report: map[string]any{"uid": "u"}}, {Now: 7}}
	results, snap := Run(&echo{}, steps)
	if len(results) != 2 || snap["n"] != 1 {
		t.Fatalf("results %v snap %v", results, snap)
	}
	var b bytes.Buffer
	if err := EncodeEvents(&b, results, snap, true); err != nil {
		t.Fatal(err)
	}
	want := `{"events":[{"ev":"in","uid":"u"}],"step":0,"trace":[]}
{"events":[],"step":1,"trace":[{"stage":"tick","value":7}]}
{"snapshot":{"n":1}}
`
	if b.String() != want {
		t.Errorf("events file:\n%s\nwant\n%s", b.String(), want)
	}
	b.Reset()
	EncodeEvents(&b, results, snap, false)
	if strings.Contains(b.String(), "trace") {
		t.Errorf("trace without --trace: %s", b.String())
	}
	path := filepath.Join(t.TempDir(), "out.jsonl")
	if err := WriteEvents(path, results, snap, true); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != want {
		t.Errorf("WriteEvents wrote %s", got)
	}
	if err := WriteEvents(filepath.Join(t.TempDir(), "no", "dir"), results, snap, true); err == nil {
		t.Error("WriteEvents into a missing directory")
	}
	bad := []Result{{Events: []model.Obj{{"x": func() {}}}}}
	if err := EncodeEvents(&b, bad, snap, false); err == nil {
		t.Error("an unencodable event")
	}
	if err := EncodeEvents(&b, nil, model.Obj{"x": func() {}}, false); err == nil {
		t.Error("an unencodable snapshot")
	}
	if err := WriteEvents(filepath.Join(t.TempDir(), "x"), bad, snap, false); err == nil {
		t.Error("WriteEvents of an unencodable event")
	}
}

func TestParams(t *testing.T) {
	m, err := Params([]string{"a=1", "b=", "c=x=y"}, []string{"a", "b"}, []string{"c", "d"})
	if err != nil || m["a"] != "1" || m["b"] != "" || m["c"] != "x=y" {
		t.Errorf("Params = %v, %v", m, err)
	}
	for _, bad := range [][]string{{"a"}, {"=1", "a=1"}, {"a=1", "a=2"}, {"a=1", "z=1"}, {}} {
		if _, err := Params(bad, []string{"a"}, nil); err == nil {
			t.Errorf("%v parses", bad)
		}
	}
}

func TestMismatch(t *testing.T) {
	for _, c := range []struct {
		got, want any
		same      bool
	}{
		{1.0, json.Number("1.0000001"), true},
		{1.0, json.Number("1.001"), false},
		{1e9, json.Number("1000000001"), true},
		{"1", json.Number("1"), false},
		{nil, nil, true},
		{"a", "a", true},
		{"a", "b", false},
		{true, false, false},
		{[]any{1.0}, []any{json.Number("1")}, true},
		{[]any{}, []any{json.Number("1")}, false},
		{"x", []any{}, false},
		{map[string]any{"a": nil}, map[string]any{"a": nil}, true},
		{map[string]any{}, map[string]any{"a": nil}, false},
		{map[string]any{"a": 1.0}, map[string]any{"a": json.Number("2")}, false},
		{1.0, map[string]any{}, false},
		{1.0, 3 + 4i, false},
	} {
		m := Mismatch("p", c.got, c.want)
		if (m == "") != c.same {
			t.Errorf("Mismatch(%#v, %#v) = %q", c.got, c.want, m)
		}
	}
}

func TestCheckVector(t *testing.T) {
	v, _ := DecodeObject([]byte(`{"steps": [{"ingest": {"uid": "u"}, "expect": [{"ev": "in", "uid": "u"}], "trace": []},
		{"tick": 3, "expect": [], "trace": [{"stage": "tick", "value": 3}]}], "snapshot": {"n": 1}}`))
	if m := CheckVector(&echo{}, v); m != "" {
		t.Error(m)
	}
	for _, change := range []func(v map[string]any){
		func(v map[string]any) { v["snapshot"] = map[string]any{"n": json.Number("2")} },
		func(v map[string]any) { v["steps"].([]any)[0].(map[string]any)["expect"] = []any{} },
		func(v map[string]any) { v["steps"].([]any)[1].(map[string]any)["trace"] = []any{} },
		func(v map[string]any) { v["steps"] = 1 },
	} {
		w, _ := DecodeObject([]byte(`{"steps": [{"ingest": {"uid": "u"}, "expect": [{"ev": "in", "uid": "u"}], "trace": []},
		{"tick": 3, "expect": [], "trace": [{"stage": "tick", "value": 3}]}], "snapshot": {"n": 1}}`))
		change(w)
		if CheckVector(&echo{}, w) == "" {
			t.Error("a changed vector checks")
		}
	}
	if len(Objs([]model.Obj{{}, {}})) != 2 {
		t.Error("Objs")
	}
}

func TestLoadVectors(t *testing.T) {
	dir := t.TempDir()
	if _, err := ReadLoadVectors(dir); err == nil {
		t.Error("no vectors reads")
	}
	os.WriteFile(filepath.Join(dir, "01.json"), []byte(`{"name": "ok", "pack_def": "x", "expect_error": false}`), 0o644)
	os.WriteFile(filepath.Join(dir, "02.json"), []byte(`{"name": "bad", "pack_def": "y", "expect_error": true}`), 0o644)
	vs, err := ReadLoadVectors(dir)
	if err != nil || len(vs) != 2 {
		t.Fatal(vs, err)
	}
	parse := func(text string) error {
		if text == "y" {
			return os.ErrInvalid
		}
		return nil
	}
	for _, v := range vs {
		if m := v.CheckLoad(parse); m != "" {
			t.Error(m)
		}
		if m := v.CheckLoad(func(string) error { return nil }); (m == "") != !v.ExpectError {
			t.Errorf("%s: %q", v.Name, m)
		}
	}
	os.WriteFile(filepath.Join(dir, "03.json"), []byte(`{"name": "x"}`), 0o644)
	if _, err := ReadLoadVectors(dir); err == nil {
		t.Error("a vector without pack_def reads")
	}
	os.WriteFile(filepath.Join(dir, "03.json"), []byte(`{`), 0o644)
	if _, err := ReadLoadVectors(dir); err == nil {
		t.Error("a bad vector reads")
	}
}
