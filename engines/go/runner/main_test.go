package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const root = "../../.."

func TestRun(t *testing.T) {
	vec := filepath.Join(root, "packs", "correlate-gnn", "vectors", "01-two-sources-one-object.json")
	events := filepath.Join(t.TempDir(), "out.jsonl")
	var out, errw bytes.Buffer
	code := run([]string{"--function", "correlate", "--pack", filepath.Join(root, "packs", "correlate-gnn"),
		"--steps", vec, "--events", events, "--trace", "--cpuprofile", filepath.Join(t.TempDir(), "cpu")}, &out, &errw)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw.String())
	}
	var counters map[string]any
	if err := json.Unmarshal(out.Bytes(), &counters); err != nil || strings.Count(out.String(), "\n") != 1 {
		t.Fatalf("stdout %q: %v", out.String(), err)
	}
	if counters["engine"] != "go" || counters["pack"] != "correlate-gnn" || counters["function"] != "correlate" {
		t.Errorf("counters %v", counters)
	}
	steps := counters["steps"].(float64)
	if counters["ingest"].(float64)+counters["tick"].(float64) != steps {
		t.Errorf("counters %v", counters)
	}
	b, _ := os.ReadFile(events)
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if float64(len(lines)) != steps+1 || !strings.HasPrefix(lines[len(lines)-1], `{"snapshot":`) || !strings.Contains(lines[0], `"trace":`) {
		t.Errorf("events file: %d lines for %v steps", len(lines), steps)
	}
	// Without --events and --trace: counters only.
	out.Reset()
	for _, fn := range []string{"filter", "fuse", "quality"} {
		pack := map[string]string{"filter": "filter-thin", "fuse": "fuse-independent", "quality": "quality-feed"}[fn]
		files, _ := filepath.Glob(filepath.Join(root, "packs", pack, "vectors", "*.json"))
		if code := run([]string{"--function", fn, "--pack", filepath.Join(root, "packs", pack), "--steps", files[0]}, &out, &errw); code != 0 {
			t.Errorf("%s: exit %d: %s", fn, code, errw.String())
		}
	}
}

func TestRunFails(t *testing.T) {
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte(`{"steps": 1}`), 0o644)
	notJSON := filepath.Join(dir, "x.json")
	os.WriteFile(notJSON, []byte(`{`), 0o644)
	good := filepath.Join(root, "packs", "correlate-gnn", "vectors", "01-two-sources-one-object.json")
	pack := filepath.Join(root, "packs", "correlate-gnn")
	for name, args := range map[string][]string{
		"unknown function": {"--function", "vote", "--pack", pack, "--steps", good},
		"no steps":         {"--function", "correlate", "--pack", pack},
		"bad flag":         {"--colour"},
		"steps not JSON":   {"--function", "correlate", "--pack", pack, "--steps", notJSON},
		"steps not a list": {"--function", "correlate", "--pack", pack, "--steps", bad},
		"no pack":          {"--function", "correlate", "--pack", dir, "--steps", good},
		"profile dir":      {"--function", "correlate", "--pack", pack, "--steps", good, "--cpuprofile", filepath.Join(dir, "no", "p")},
		"events dir":       {"--function", "correlate", "--pack", pack, "--steps", good, "--events", filepath.Join(dir, "no", "x")},
	} {
		var out, errw bytes.Buffer
		if code := run(args, &out, &errw); code == 0 || out.Len() != 0 || errw.Len() == 0 {
			t.Errorf("%s: exit %d, stdout %q, stderr %q", name, code, out.String(), errw.String())
		}
	}
}
