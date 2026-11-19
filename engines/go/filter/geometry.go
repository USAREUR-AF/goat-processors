package filter

import "math"

// Geometry (spec/filter.md: Geometry). Every formula is evaluated in the order
// the specification writes it.

const earthR = 6371008.8

func rad(x float64) float64 { return x * math.Pi / 180 }
func deg(x float64) float64 { return x * 180 / math.Pi }

// wrap adds or subtracts 360 until x is in (-180, 180].
func wrap(x float64) float64 {
	for x > 180 {
		x -= 360
	}
	for x <= -180 {
		x += 360
	}
	return x
}

// distance is the haversine great-circle distance, m, from point 1 (the report)
// to point 2.
func distance(lat1, lon1, lat2, lon2 float64) float64 {
	// 1.
	p1, p2 := rad(lat1), rad(lat2)
	dp := rad(lat2 - lat1)
	dl := rad(wrap(lon2 - lon1))
	// 2.
	s1, s2 := math.Sin(dp/2), math.Sin(dl/2)
	// 3.
	h := s1*s1 + ((math.Cos(p1)*math.Cos(p2))*s2)*s2
	// 4.
	return (2 * earthR) * math.Asin(math.Min(1, math.Sqrt(h)))
}

// Polygon results.
const (
	boundary = "boundary"
	inside   = "inside"
	outside  = "outside"
)

// polygonTest places the report (lat, lon) against a polygon on the flat
// plane x = longitude, y = latitude, longitudes unwrapped to within 180
// degrees of the first vertex.
func polygonTest(vs []Vertex, lat, lon float64) string {
	n := len(vs)
	lon0 := vs[0].Lon
	x := make([]float64, n)
	y := make([]float64, n)
	x[0], y[0] = lon0, vs[0].Lat
	for i := 1; i < n; i++ {
		x[i] = lon0 + wrap(vs[i].Lon-lon0)
		y[i] = vs[i].Lat
	}
	px, py := lon0+wrap(lon-lon0), lat

	// 1. Boundary: on an edge or a vertex.
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		c := (x[j]-x[i])*(py-y[i]) - (y[j]-y[i])*(px-x[i])
		if c == 0 &&
			math.Min(x[i], x[j]) <= px && px <= math.Max(x[i], x[j]) &&
			math.Min(y[i], y[j]) <= py && py <= math.Max(y[i], y[j]) {
			return boundary
		}
	}

	// 2. Crossings (even-odd rule).
	in := false
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		if (y[i] > py) != (y[j] > py) {
			xc := (x[j]-x[i])*(py-y[i])/(y[j]-y[i]) + x[i]
			if px < xc {
				in = !in
			}
		}
	}
	if in {
		return inside
	}
	return outside
}

// predict is the position of a reference entity predicted to time t
// (Reference prediction).
func predict(s *State, t int64) (lat, lon float64) {
	// 1.
	dt := float64(t-s.TimeMs) / 1000
	// 2.
	var dn, de float64
	if s.Course != nil && s.SpeedMs != nil {
		dn = *s.SpeedMs * math.Cos(rad(*s.Course)) * dt
		de = *s.SpeedMs * math.Sin(rad(*s.Course)) * dt
	}
	// 3.
	lat = s.Lat + deg(dn/earthR)
	lon = wrap(s.Lon + deg(de/(earthR*math.Cos(rad(s.Lat)))))
	return lat, lon
}
