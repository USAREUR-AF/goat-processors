package io

import (
	"fmt"
	"path/filepath"
	"sort"
)

// LoadVector is one load vector (spec/vector-format.md: Load vectors).
type LoadVector struct {
	Name        string
	PackDef     string
	ExpectError bool
}

// ReadLoadVectors reads every load vector in dir, in file name order.
func ReadLoadVectors(dir string) ([]LoadVector, error) {
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		return nil, fmt.Errorf("no load vectors in %s", dir)
	}
	out := make([]LoadVector, 0, len(files))
	for _, f := range files {
		v, err := ReadObject(f)
		if err != nil {
			return nil, err
		}
		name, _ := v["name"].(string)
		def, ok1 := v["pack_def"].(string)
		want, ok2 := v["expect_error"].(bool)
		if !ok1 || !ok2 {
			return nil, fmt.Errorf("%s: not a load vector", f)
		}
		out = append(out, LoadVector{name, def, want})
	}
	return out, nil
}

// CheckLoad returns "" when parse fails exactly as the vector expects.
func (v LoadVector) CheckLoad(parse func(text string) error) string {
	err := parse(v.PackDef)
	if (err != nil) != v.ExpectError {
		return fmt.Sprintf("%s: expect_error=%v, got error %v", v.Name, v.ExpectError, err)
	}
	return ""
}
