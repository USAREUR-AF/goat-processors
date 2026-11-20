package goat.correlate;

import goat.io.Json;
import goat.io.LoadError;
import goat.io.Vectors;
import goat.testkit.Check;
import goat.testkit.Fixtures;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * The registration point: a test kind added with one registration, here only, in test code.
 * {@code noop} takes no parameter, always passes, and gives one trace record with no value.
 */
public final class NoopTestKindTest {
    private NoopTestKindTest() {}

    /** The one registration. */
    static final Registry WITH_NOOP = Registry.STANDARD.withTest(new TestKind("noop", List.of(),
            (t, stage, a, b, pb) -> Tests.rec(stage, a, b, t.name, null, null, true, false)));

    static String fixturePack() throws Exception {
        return Vectors.read(Fixtures.fixtures().resolve("correlate-noop/pack.def"));
    }

    /** Invisible: the standard registry has no test noop, so the fixture pack does not load. */
    public static void testStandardRegistryRefusesNoop() throws Exception {
        String text = fixturePack();
        LoadError e = Check.throwsA(LoadError.class, () -> CorrelatePack.parse(text), "standard registry");
        Check.isTrue(e.getMessage().contains("unknown test noop"), e.getMessage());
        Check.isTrue(Registry.STANDARD.test("noop") == null, "standard registry unchanged");
    }

    /** The registered kind loads, with its parameters checked like any test's. */
    public static void testRegisteredNoopLoads() throws Exception {
        CorrelatePack pk = CorrelatePack.parse(fixturePack(), WITH_NOOP);
        Check.eq(4, pk.gate.size(), "gate lines");
        Check.eq("noop", pk.gate.get(3).name, "fourth gate");
        Check.throwsA(LoadError.class, () -> CorrelatePack.parse(fixturePack().replace("gate        noop",
                "gate        noop x=1"), WITH_NOOP), "noop takes no parameter");
    }

    /**
     * Every vector of correlate-assign gives, with the noop line, the same events and snapshot,
     * and the same trace once the noop records are taken out.
     */
    @SuppressWarnings("unchecked")
    public static void testNoopChangesNothingElse() throws Exception {
        String base = Fixtures.packText("correlate-assign");
        String noop = fixturePack();
        int noops = 0;
        for (Map<String, Object> v : Fixtures.vectors("correlate-assign")) {
            Correlator plain = Correlator.fromText(base), with = Correlator.fromText(noop, WITH_NOOP);
            for (Map<String, Object> step : Fixtures.steps(v)) {
                goat.trace.Result a = goat.io.Steps.apply(plain, step), b = goat.io.Steps.apply(with, step);
                Check.eq(Json.write(a.events), Json.write(b.events), v.get("name") + " events");
                List<Map<String, Object>> rest = new ArrayList<>();
                for (Map<String, Object> r : b.trace) {
                    if ("noop".equals(r.get("test"))) noops++;
                    else rest.add(r);
                }
                Check.eq(Json.write(a.trace), Json.write(rest), v.get("name") + " trace");
            }
            Check.eq(Json.write(plain.snapshot()), Json.write(with.snapshot()), v.get("name") + " snapshot");
        }
        Check.isTrue(noops > 0, "the noop test ran");
    }

    /** Its own vector, in spec/vector-format.md, under the fixture pack. */
    @SuppressWarnings("unchecked")
    public static void testNoopVector() throws Exception {
        Path f = Fixtures.fixtures().resolve("correlate-noop/vectors/01-noop-gate.json");
        Map<String, Object> v = (Map<String, Object>) Json.parse(Vectors.read(f));
        Correlator c = Correlator.fromText(fixturePack(), WITH_NOOP);
        int k = 0;
        for (Map<String, Object> step : Fixtures.steps(v)) {
            goat.trace.Result r = goat.io.Steps.apply(c, step);
            String m = Vectors.diff("steps[" + k + "].expect", new ArrayList<Object>(r.events), step.get("expect"));
            if (m == null) m = Vectors.diff("steps[" + k + "].trace", new ArrayList<Object>(r.trace), step.get("trace"));
            Check.eq(null, m, "vector");
            k++;
        }
        Check.eq(null, Vectors.diff("snapshot", c.snapshot(), v.get("snapshot")), "vector snapshot");
    }
}
