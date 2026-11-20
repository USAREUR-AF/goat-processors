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
	// One literal per shape, so that the map is made at its full size.
	return Obj{"stage": stage, "a": a, "b": b, "test": test, "value": nil, "limit": nil, "pass": true, "skipped": true}
}

// Time is the filter record of a report with a time error above 0.
func Time(key string, te, varEast, varNorth float64) Obj {
	return Obj{"stage": "filter", "a": key, "b": nil, "test": "time", "value": te, "limit": nil,
		"pass": true, "var_east": varEast, "var_north": varNorth}
}

// Bias is the record of stage bias for one pair (correlate-assign.md
// Sensor bias, Update step 4), with the pair's state after the update;
// timeOffsetMs is added when not nil.
func Bias(a, b string, d2, gate float64, pass bool, east, north, variance float64, pairs int64, timeOffsetMs any) Obj {
	if timeOffsetMs != nil {
		return Obj{"stage": "bias", "a": a, "b": b, "test": "offset", "value": d2, "limit": gate, "pass": pass,
			"east": east, "north": north, "var": variance, "pairs": pairs, "time_offset_ms": timeOffsetMs}
	}
	return Obj{"stage": "bias", "a": a, "b": b, "test": "offset", "value": d2, "limit": gate, "pass": pass,
		"east": east, "north": north, "var": variance, "pairs": pairs}
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
