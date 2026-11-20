// Package goengine is the Go engine of goat-correlator: correlate (with
// method assign), filter, fuse and quality, standard library only. This
// root package holds no code; its test runs the correlate conformance
// vectors (the perf harness times that test binary in this directory).
//
// Layout (README.md maps every spec section to its file):
//
//	model/      shared values and pure math: frame, filter, two-model filter, reports, time quality
//	correlate/  correlate.md: the engine, tests, restart, method table, method confirm
//	assign/     correlate-assign.md: method assign
//	filter/     filter.md
//	fuse/       fuse.md
//	quality/    quality.md
//	trace/      every function's trace record shapes
//	snapshot/   snapshot value encoders and decoders
//	io/         JSON input, steps, events file, pack.def helpers, vector comparison
//	runner/     the perf harness's command-line runner
package goengine
