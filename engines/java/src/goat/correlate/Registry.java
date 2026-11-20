package goat.correlate;

import goat.assign.Assign;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The extension point of correlate: the tests, the methods and the directives a pack may use.
 * Immutable; {@link #STANDARD} is the specification's, and {@link #withTest} and
 * {@link #withMethod} give a new registry with one more entry. A pack is read against one
 * registry ({@link CorrelatePack#parse(String, Registry)}).
 */
public final class Registry {

    /** The tests of correlate.md, Tests, and the methods confirm and assign. */
    public static final Registry STANDARD = new Registry(Map.of(), Map.of(), CorrelatePack.SHARED)
            .withTests(Tests.STANDARD)
            .withMethod(Confirm.KIND)
            .withMethod(Assign.KIND);

    /** The method of a pack without a {@code method} line. */
    public static final String DEFAULT_METHOD = "confirm";

    private final Map<String, TestKind> tests;
    private final Map<String, MethodKind> methods;
    private final Map<String, Directive> directives;
    /** The method that owns each method-only directive. */
    private final Map<String, String> owner;

    private Registry(Map<String, TestKind> tests, Map<String, MethodKind> methods, Iterable<Directive> shared) {
        this.tests = new LinkedHashMap<>(tests);
        this.methods = new LinkedHashMap<>(methods);
        this.directives = new LinkedHashMap<>();
        this.owner = new LinkedHashMap<>();
        for (Directive d : shared) directives.put(d.name, d);
    }

    private Registry copy() {
        Registry r = new Registry(tests, methods, directives.values());
        r.owner.putAll(owner);
        return r;
    }

    /** This registry with one more test kind (or one replaced, by name). */
    public Registry withTest(TestKind kind) {
        Registry r = copy();
        r.tests.put(kind.name, kind);
        return r;
    }

    private Registry withTests(Iterable<TestKind> kinds) {
        Registry r = this;
        for (TestKind k : kinds) r = r.withTest(k);
        return r;
    }

    /** This registry with one more method and its directives. */
    public Registry withMethod(MethodKind kind) {
        Registry r = copy();
        r.methods.put(kind.name, kind);
        for (Directive d : kind.directives) {
            r.directives.put(d.name, d);
            r.owner.put(d.name, kind.name);
        }
        return r;
    }

    public TestKind test(String name) {
        return tests.get(name);
    }

    public MethodKind method(String name) {
        return methods.get(name);
    }

    public Map<String, MethodKind> methods() {
        return Collections.unmodifiableMap(methods);
    }

    public Directive directive(String name) {
        return directives.get(name);
    }

    /** The method that alone takes this directive, or null when every method takes it. */
    public String ownerOf(String directive) {
        return owner.get(directive);
    }
}
