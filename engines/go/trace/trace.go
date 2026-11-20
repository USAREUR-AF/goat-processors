// Package trace builds the trace records of every function, one
// constructor per record shape, so that each Trace section of the
// specification has one place in the code (correlate.go: correlate.md and
// correlate-assign.md Trace; filter.go: filter.md Trace; fuse.go: fuse.md
// Trace; quality.go: quality.md Trace). Every constructor is pure.
package trace

import "goat-correlator/engines/go/model"

// Obj is one trace record.
type Obj = model.Obj
