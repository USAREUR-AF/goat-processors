package trace

// Quality records (spec/quality.md Trace).

// Sample is the record of one sample taken at ingest.
func Sample(key, name string, value any, inputs ...any) Obj {
	return Obj{"stage": "sample", "entity": key, "sample": name, "value": value, "inputs": inputs}
}

// QualityRule is the record of one rule's evaluation at a tick.
func QualityRule(rule, subject, measure string, value any, limit float64, pass bool, count int64, active bool) Obj {
	return Obj{"stage": "rule", "rule": rule, "subject": subject, "measure": measure, "value": value,
		"limit": limit, "pass": pass, "count": count, "active": active}
}
