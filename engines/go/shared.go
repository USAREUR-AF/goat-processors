package correlator

// The fuse package (engines/go/fuse) reuses this engine's Frame, Track estimate
// and Reports validation, which spec/fuse.md "Shared with correlate.md" applies
// unchanged. These exported names are that surface; each forwards to the code the
// correlate method itself runs.

// Rad and Deg convert degrees and radians (spec: Frame).
func Rad(x float64) float64 { return rad(x) }
func Deg(x float64) float64 { return deg(x) }

// Predict is step 1 of Track estimate, also the prediction to a time.
func (a Axis) Predict(dt, q float64) Axis { return a.predict(dt, q) }

// UpdatePos is step 2 of Track estimate: position update with z and r = ce².
func (a Axis) UpdatePos(z, r float64) Axis { return a.updatePos(z, r) }

// UpdateVel is step 3 of Track estimate: velocity update with z and r = vel_sigma_ms².
func (a Axis) UpdateVel(z, r float64) Axis { return a.updateVel(z, r) }

// List is the snapshot form [p, v, pp, pv, vv] (spec: Snapshot).
func (a Axis) List() []any { return a.list() }

// Frame is the local plane around the reference point lat0, lon0 (spec: Frame).
type Frame struct{ Lat0, Lon0 float64 }

// ToPlane converts degrees to metres east and north of the reference.
func (f Frame) ToPlane(lat, lon float64) (east, north float64) {
	g := Engine{ref: &[2]float64{f.Lat0, f.Lon0}}
	return g.toPlane(lat, lon)
}

// ToDegrees converts metres east and north of the reference to degrees.
func (f Frame) ToDegrees(east, north float64) (lat, lon float64) {
	g := Engine{ref: &[2]float64{f.Lat0, f.Lon0}}
	return g.toDegrees(east, north)
}

// ValidReportKey reports whether a report value has the type its key requires
// (spec: Reports): strings for track.source_id, uid, type; integers for time_ms,
// stale_ms; numbers for lat, lon, hae, ce, course, speed_ms; any other key any value.
func ValidReportKey(key string, v any) bool { return validKey(key, v) }

// CleanReport returns a copy of a report without the keys Reports treats as
// absent: null values, optional keys of the wrong type, a ce of 0 or below.
func CleanReport(r map[string]any) map[string]any { return cleanOptional(r) }

// ToFloat and ToInt read a JSON number (spec: Reports).
func ToFloat(v any) (float64, bool) { return toFloat(v) }
func ToInt(v any) (int64, bool)     { return toInt(v) }
