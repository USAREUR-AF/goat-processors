package goat;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * Runs the engine's unit, property and fuzz tests: every {@code public static void test*()}
 * method of the classes below, in name order. Prints each failure, then
 * {@code tests: N passed, M failed}; exits non-zero on any failure. An argument keeps only the
 * classes whose name contains it.
 */
public final class TestMain {
    private TestMain() {}

    static final List<String> CLASSES = List.of(
            "goat.model.ModelTest",
            "goat.trace.TraceTest",
            "goat.io.IoTest",
            "goat.filter.FilterTest",
            "goat.correlate.CorrelateTest",
            "goat.correlate.NoopTestKindTest",
            "goat.assign.AssignTest",
            "goat.fuse.FuseTest",
            "goat.quality.QualityTest",
            "goat.property.PropertyTest",
            "goat.fuzz.FuzzTest");

    public static void main(String[] args) throws Exception {
        int pass = 0, fail = 0;
        for (String name : CLASSES) {
            if (args.length > 0 && !name.contains(args[0])) continue;
            Class<?> c = Class.forName(name);
            List<Method> tests = new ArrayList<>();
            for (Method m : c.getDeclaredMethods())
                if (m.getName().startsWith("test") && Modifier.isStatic(m.getModifiers())
                        && Modifier.isPublic(m.getModifiers()) && m.getParameterCount() == 0)
                    tests.add(m);
            tests.sort(Comparator.comparing(Method::getName));
            for (Method m : tests) {
                try {
                    m.invoke(null);
                    pass++;
                } catch (InvocationTargetException e) {
                    fail++;
                    Throwable t = e.getCause();
                    System.out.println("FAIL " + c.getSimpleName() + "." + m.getName() + ": " + t);
                    StackTraceElement[] st = t.getStackTrace();
                    for (StackTraceElement el : Arrays.copyOf(st, Math.min(4, st.length))) System.out.println("    at " + el);
                }
            }
        }
        System.out.println("tests: " + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }
}
