package trace

// Correlate records (spec/correlate.md Trace, spec/correlate-assign.md
// Trace): stage, a, b, test, value, limit, pass; some stages add keys.

// Record is the one record shape of correlate: a and b are entity keys,
// model names, system track names, history indexes or null.
func Record(stage string, a, b any, test string, value, limit any, pass bool) Obj {
	return Obj{"stage": stage, "a": a, "b": b, "test": test, "value": value, "limit": limit, "pass": pass}
}

// Skipped is a test record of a test that could not be run (Tests: "skipped").
func Skipped(stage, a, b, test string) Obj {
	r := Record(stage, a, b, test, nil, nil, true)
	r["skipped"] = true
	return r
}

// Time is the filter record of a report with a time error above 0.
func Time(key string, te, varEast, varNorth float64) Obj {
	r := Record("filter", key, nil, "time", te, nil, true)
	r["var_east"], r["var_north"] = varEast, varNorth
	return r
}

// Restart is the filter record of the restart test.
func Restart(key string, d2, gate float64, pass bool) Obj {
	return Record("filter", key, nil, "restart", d2, gate, pass)
}

// Model is a filter record of the two-model filter: likelihood or mode of
// one model.
func Model(key, model, test string, value float64) Obj {
	return Record("filter", key, model, test, value, nil, true)
}

// Assign is a record of stage assign: cost or choice of row a, column b.
func Assign(a, b, test string, value any, pass bool) Obj {
	return Record("assign", a, b, test, value, nil, pass)
}

// History is a record of stage history: total or commit.
func History(a, b any, test string, value float64, pass bool) Obj {
	return Record("history", a, b, test, value, nil, pass)
}

// Tag adds the given key and value pairs to each record.
func Tag(recs []Obj, kv ...any) []Obj {
	for _, r := range recs {
		for i := 0; i < len(kv); i += 2 {
			r[kv[i].(string)] = kv[i+1]
		}
	}
	return recs
}
