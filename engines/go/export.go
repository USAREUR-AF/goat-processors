package correlator

// Exported pieces of this engine that spec/quality.md reuses by citation, so that
// the quality module (engines/go/quality) runs the same code as correlate:
//
//   - correlate.md, Frame: ToPlane.
//   - correlate.md, Track estimate: Axis.Predict, Axis.UpdatePos, Axis.UpdateVel.
//   - correlate.md, Reports: ValidKey, IsInt, ToFloat, ToInt.

// Predict is step 1 of Track estimate, on a copy of the axis.
func (a Axis) Predict(dt, q float64) Axis { return a.predict(dt, q) }

// UpdatePos is step 2 of Track estimate, position update with measurement z and variance r.
func (a Axis) UpdatePos(z, r float64) Axis { return a.updatePos(z, r) }

// UpdateVel is step 3 of Track estimate, velocity update with measurement z and variance r.
func (a Axis) UpdateVel(z, r float64) Axis { return a.updateVel(z, r) }

// List is the axis as written in a snapshot: [p, v, pp, pv, vv].
func (a Axis) List() []any { return a.list() }

// ToPlane converts degrees to metres east and north of the reference ref = [lat0, lon0] (Frame).
func ToPlane(ref [2]float64, lat, lon float64) (east, north float64) {
	g := Engine{ref: &ref}
	return g.toPlane(lat, lon)
}

// ValidKey reports whether a report key holds a value of its type (Reports).
func ValidKey(key string, v any) bool { return validKey(key, v) }

// IsInt reports whether v is a JSON integer: written without fraction or exponent (Reports).
func IsInt(v any) bool { return isInt(v) }

// ToFloat reads a JSON number as binary64; false when v is not a number (a boolean never is).
func ToFloat(v any) (float64, bool) { return toFloat(v) }

// ToInt reads a JSON number as an integer.
func ToInt(v any) (int64, bool) { return toInt(v) }
