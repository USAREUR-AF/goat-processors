package correlator

// Exported pieces of this engine that spec/quality.md reuses by citation, so that
// the quality module (engines/go/quality) runs the same code as correlate:
//
//   - correlate.md, Frame: ToPlane.
//   - correlate.md, Track estimate: Axis.Predict, Axis.UpdatePos, Axis.UpdateVel
//     (in shared.go, shared with fuse/).
//   - correlate.md, Reports: ValidKey, and IsInt, ToFloat, ToInt (in reports.go,
//     shared with filter/).
//   - correlate.md 0.8, Reports "Time quality" and Pack time_default:
//     ValidTimeError, ValidTimeState, IsTimeState, ParseTimeDefault (in time.go).

// ToPlane converts degrees to meters east and north of the reference ref = [lat0, lon0] (Frame).
func ToPlane(ref [2]float64, lat, lon float64) (east, north float64) {
	g := Engine{ref: &ref}
	return g.toPlane(lat, lon)
}

// ValidKey reports whether a report key holds a value of its type (Reports).
func ValidKey(key string, v any) bool { return validKey(key, v) }
