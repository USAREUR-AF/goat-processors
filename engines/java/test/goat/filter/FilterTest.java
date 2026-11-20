package goat.filter;

import goat.io.LoadError;
import goat.testkit.Check;
import goat.trace.Result;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the filter module: Geometry, FilterPack, FilterProcessor. */
public final class FilterTest {
    private FilterTest() {}

    public static void testWrap() {
        Check.same(-170, Geometry.wrap(190), "190");
        Check.same(180, Geometry.wrap(-180), "-180 is 180");
        Check.same(180, Geometry.wrap(540), "540");
    }

    public static void testDistance() {
        Check.same(0, Geometry.distance(10, 20, 10, 20), "same point");
        double oneDegree = Geometry.distance(0, 0, 1, 0);
        Check.near(2 * Math.PI * Geometry.R / 360, oneDegree, 1e-6, "one degree of latitude");
        Check.near(Geometry.distance(0, 179.5, 0, -179.5), Geometry.distance(0, 0, 0, 1), 1e-6, "across the dateline");
    }

    public static void testPolygon() {
        double[] lat = {0, 0, 10, 10}, lon = {0, 10, 10, 0};
        Check.eq("inside", Geometry.polygon(lat, lon, 5, 5), "inside");
        Check.eq("outside", Geometry.polygon(lat, lon, 15, 5), "outside");
        Check.eq("boundary", Geometry.polygon(lat, lon, 0, 5), "on an edge");
        Check.eq("boundary", Geometry.polygon(lat, lon, 10, 10), "a vertex");
        double[] dlat = {-1, -1, 1, 1}, dlon = {179, -179, -179, 179};
        Check.eq("inside", Geometry.polygon(dlat, dlon, 0, 180), "across the dateline");
    }

    public static void testPredict() {
        FilterProcessor.State s = new FilterProcessor.State();
        s.timeMs = 1000;
        s.lat = 10;
        s.lon = 20;
        double[] still = Geometry.predict(s, 5000);
        Check.eq(List.of(10.0, 20.0), List.of(still[0], still[1]), "no course: no move");
        s.course = 0.0;
        s.speedMs = 100.0;
        double[] north = Geometry.predict(s, 11000);
        Check.near(10 + Geometry.deg(1000 / Geometry.R), north[0], 1e-12, "1 km north");
    }

    static final String PACK = "pack p\nversion 1\ndefault keep\nforget_ms 1000\n"
            + "rule near-home drop\nwhen circle lat=0 lon=0 radius_m=1000\nwhen not env in=A,S\n";

    public static void testPackParses() throws LoadError {
        FilterPack p = FilterPack.parse(PACK);
        Check.eq("keep", p.defaultAction, "default");
        Check.eq(1000L, p.forgetMs, "forget_ms");
        Check.eq(1, p.rules.size(), "rules");
        Check.eq(2, p.rules.get(0).conditions.size(), "conditions");
        Check.isTrue(p.rules.get(0).conditions.get(1).negated, "not");
        Check.eq(List.of("A", "S"), p.rules.get(0).conditions.get(1).in, "list");
    }

    public static void testPackErrors() {
        for (String bad : List.of(
                PACK.replace("default keep", "default maybe"),
                PACK.replace("forget_ms 1000", "forget_ms 0"),
                PACK.replace("forget_ms 1000", "forget_ms -1"),
                PACK.replace("radius_m=1000", "radius_m=-1"),
                PACK.replace("lat=0", "lat=91"),
                PACK.replace("in=A,S", "in=A,,S"),
                PACK.replace("rule near-home drop", "rule default drop"),
                PACK + "rule empty keep\n",
                "when order\n" + PACK,
                PACK + "when circle lat=0 lon=0\n",
                PACK + "when key name=x min=2 max=1\n",
                PACK + "pack again\n",
                PACK.replace("version 1\n", ""),
                PACK + "when polygon vertices=0,0;1,1\n",
                PACK + "when bogus\n"))
            Check.throwsA(LoadError.class, () -> FilterPack.parse(bad), "load error: " + bad);
    }

    public static void testIsNumber() {
        Check.isTrue(FilterPack.isNumber("-1.5"), "-1.5");
        Check.isTrue(!FilterPack.isNumber("1e3"), "no exponent");
        Check.isTrue(!FilterPack.isNumber(".5"), "digits first");
    }

    public static void testEnvironmentAndAffiliation() {
        Check.eq("A", FilterProcessor.environment("a-f-A-M"), "third element");
        Check.eq(null, FilterProcessor.environment("a-f"), "too short");
        Check.eq("f", FilterProcessor.affiliation("a-f-A"), "second when the first is a");
        Check.eq(null, FilterProcessor.affiliation("b-f-A"), "first not a");
    }

    static Map<String, Object> report(String uid, long t, double lat, double lon) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("track.source_id", "s");
        r.put("uid", uid);
        r.put("time_ms", t);
        r.put("lat", lat);
        r.put("lon", lon);
        r.put("type", "a-f-G");
        return r;
    }

    public static void testIngestTickSnapshot() throws LoadError {
        FilterProcessor f = FilterProcessor.fromText(PACK);
        Result r = f.ingest(report("u", 100, 0, 0));
        Check.eq("drop", r.events.get(0).get("ev"), "inside the circle, not air or surface: dropped");
        Check.eq("near-home", r.events.get(0).get("rule"), "by the rule");
        Check.eq(2, r.trace.size(), "two condition records");
        Result far = f.ingest(report("v", 100, 10, 10));
        Check.eq("keep", far.events.get(0).get("ev"), "outside: default");
        Check.eq(1, far.trace.size(), "the first condition fails and ends the rule");
        Result reject = f.ingest(Map.of("uid", "x"));
        Check.eq("missing:track.source_id", reject.events.get(0).get("reason"), "reject");
        Check.eq(2, ((Map<?, ?>) f.snapshot().get("entities")).size(), "two entities");
        Result tick = f.tick(1101);
        Check.eq(2, tick.events.size(), "both forgotten after forget_ms");
        Check.eq(0, ((Map<?, ?>) f.snapshot().get("entities")).size(), "none left");
    }
}
