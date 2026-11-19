package filter;

/** Spec filter.md, section Geometry. Every formula is evaluated in the order written there. */
final class Geometry {
    private Geometry() {}

    static final double R = 6371008.8;

    static double rad(double x) {
        return x * Math.PI / 180;
    }

    static double deg(double x) {
        return x * 180 / Math.PI;
    }

    /** wrap(x): add or subtract 360 until x is in (-180, 180]. */
    static double wrap(double x) {
        while (x > 180) x -= 360;
        while (x <= -180) x += 360;
        return x;
    }

    /** Distance, haversine, from point 1 (the report) to point 2. */
    static double distance(double lat1, double lon1, double lat2, double lon2) {
        // 1.
        double p1 = rad(lat1), p2 = rad(lat2), dp = rad(lat2 - lat1), dl = rad(wrap(lon2 - lon1));
        // 2.
        double s1 = Math.sin(dp / 2), s2 = Math.sin(dl / 2);
        // 3.
        double h = s1 * s1 + ((Math.cos(p1) * Math.cos(p2)) * s2) * s2;
        // 4.
        return (2 * R) * Math.asin(Math.min(1, Math.sqrt(h)));
    }

    /** Polygon: "boundary", "inside" or "outside" for the point (lat, lon). */
    static String polygon(double[] vlat, double[] vlon, double lat, double lon) {
        int n = vlat.length;
        // Every longitude taken to within 180 degrees of the first vertex.
        double lon0 = vlon[0];
        double[] x = new double[n], y = new double[n];
        x[0] = lon0;
        for (int i = 1; i < n; i++) x[i] = lon0 + wrap(vlon[i] - lon0);
        for (int i = 0; i < n; i++) y[i] = vlat[i];
        double px = lon0 + wrap(lon - lon0), py = lat;

        // 1. Boundary.
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            double c = (x[j] - x[i]) * (py - y[i]) - (y[j] - y[i]) * (px - x[i]);
            if (c == 0
                    && Math.min(x[i], x[j]) <= px && px <= Math.max(x[i], x[j])
                    && Math.min(y[i], y[j]) <= py && py <= Math.max(y[i], y[j]))
                return "boundary";
        }
        // 2. Crossings (even-odd rule).
        boolean inside = false;
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            if ((y[i] > py) != (y[j] > py)) {
                double xc = (x[j] - x[i]) * (py - y[i]) / (y[j] - y[i]) + x[i];
                if (px < xc) inside = !inside;
            }
        }
        return inside ? "inside" : "outside";
    }

    /** Reference prediction: {lat_p, lon_p} of the stored state predicted to time t. */
    static double[] predict(Filter.State ref, long t) {
        // 1.
        double dt = (t - ref.timeMs) / 1000.0;
        // 2.
        double dn = 0, de = 0;
        if (ref.course != null && ref.speedMs != null) {
            dn = ref.speedMs * Math.cos(rad(ref.course)) * dt;
            de = ref.speedMs * Math.sin(rad(ref.course)) * dt;
        }
        // 3.
        double latP = ref.lat + deg(dn / R);
        double lonP = wrap(ref.lon + deg(de / (R * Math.cos(rad(ref.lat)))));
        return new double[] {latP, lonP};
    }
}
