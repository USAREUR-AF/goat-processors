package trace

// Filter records (spec/filter.md Trace).

// Rule is the record of one condition of a rule.
func Rule(rule, entity, test string, negated bool, value, limit any, pass, unknown bool) Obj {
	rec := Obj{"stage": "rule", "rule": rule, "entity": entity, "test": test,
		"negated": negated, "value": value, "limit": limit, "pass": pass}
	if unknown {
		rec["unknown"] = true
	}
	return rec
}

// Forget is the record of the tick's age test of one entity.
func Forget(entity string, age, forgetMs int64, pass bool) Obj {
	return Obj{"stage": "forget", "entity": entity, "test": "age", "value": age, "limit": forgetMs, "pass": pass}
}
