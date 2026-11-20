package goat.model;

/** correlate.md, Frame: degrees to the local plane and back, about a reference (lat0, lon0). */
public final class Frame {
    private Frame() {}

    public static final double R = 6371008.8;

    public static double rad(double x) {
        return x * Math.PI / 180;
    }

    public static double deg(double x) {
        return x * 180 / Math.PI;
    }

    public static double wrapLon(double lon) {
        while (lon > 180) lon -= 360;
        while (lon <= -180) lon += 360;
        return lon;
    }

    /** Degrees to meters east and north of the reference (lat0, lon0). */
    public static double[] toPlane(double lat0, double lon0, double lat, double lon) {
        double dlon = wrapLon(lon - lon0);
        return new double[] {R * rad(dlon) * Math.cos(rad(lat0)), R * rad(lat - lat0)};
    }

    /** Back to degrees. */
    public static double[] toDegrees(double lat0, double lon0, double east, double north) {
        double lat = lat0 + deg(north / R);
        double lon = wrapLon(lon0 + deg(east / (R * Math.cos(rad(lat0)))));
        return new double[] {lat, lon};
    }

    /** correlate.md, Association, On each tick, Fused output: course in [0, 360). */
    public static double course(double ve, double vn) {
        double course = deg(Math.atan2(ve, vn));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;
        return course;
    }
}
