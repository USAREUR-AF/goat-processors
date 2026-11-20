package trace

// Fuse records (spec/fuse.md Trace).

// Kinematics is the record of a group's kinematics method.
func Kinematics(group any, method string, candidates []any, winner any) Obj {
	return Obj{"stage": "kinematics", "group": group, "method": method, "candidates": candidates, "winner": winner}
}

// KinematicsCandidate is one candidate of a kinematics record.
func KinematicsCandidate(member string, variance float64, timeMs int64, rank any) Obj {
	return Obj{"member": member, "var": variance, "time_ms": timeMs, "rank": rank}
}

// Intersect is the record of one covariance-intersection fold.
func Intersect(group any, member string, w float64) Obj {
	return Obj{"stage": "intersect", "group": group, "member": member, "value": w}
}

// Attribute is the record of one attribute decision.
func Attribute(group any, key, rule string, candidates []any, winner, value any) Obj {
	return Obj{"stage": "attribute", "group": group, "key": key, "rule": rule,
		"candidates": candidates, "winner": winner, "value": value}
}

// AttributeCandidate is one candidate of an attribute record.
func AttributeCandidate(member string, value any, timeMs int64, rank any) Obj {
	return Obj{"member": member, "value": value, "time_ms": timeMs, "rank": rank}
}
