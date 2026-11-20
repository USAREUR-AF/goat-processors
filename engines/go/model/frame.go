package model

import "math"

// The local plane (spec/correlate.md: Frame), which filter, fuse and quality
// use as correlate does.

// EarthR is the earth radius of the frame, m.
const EarthR = 6371008.8

// Rad converts degrees to radians.
func Rad(x float64) float64 { return x * math.Pi / 180 }

// Deg converts radians to degrees.
func Deg(x float64) float64 { return x * 180 / math.Pi }

// Wrap180 brings an angle into (-180, 180].
func Wrap180(x float64) float64 {
	for x > 180 {
		x -= 360
	}
	for x <= -180 {
		x += 360
	}
	return x
}

// Frame is the local plane around the reference point Lat0, Lon0.
type Frame struct{ Lat0, Lon0 float64 }

// ToPlane converts degrees to meters east and north of the reference.
func (f Frame) ToPlane(lat, lon float64) (east, north float64) {
	dlon := Wrap180(lon - f.Lon0)
	return EarthR * Rad(dlon) * math.Cos(Rad(f.Lat0)), EarthR * Rad(lat-f.Lat0)
}

// ToDegrees converts meters east and north of the reference to degrees.
func (f Frame) ToDegrees(east, north float64) (lat, lon float64) {
	lat = f.Lat0 + Deg(north/EarthR)
	lon = f.Lon0 + Deg(east/(EarthR*math.Cos(Rad(f.Lat0))))
	return lat, Wrap180(lon)
}

// Velocity is a course (degrees from north) and speed as velocity east and north.
func Velocity(course, speed float64) (ve, vn float64) {
	return speed * math.Sin(Rad(course)), speed * math.Cos(Rad(course))
}

// Course is the course, degrees in [0, 360), of a velocity east and north.
func Course(ve, vn float64) float64 {
	course := Deg(math.Atan2(ve, vn))
	if course < 0 {
		course += 360
	}
	if course >= 360 {
		course -= 360
	}
	return course
}
