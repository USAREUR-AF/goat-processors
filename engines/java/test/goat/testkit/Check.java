package goat.testkit;

import goat.io.Json;

import java.util.Objects;

/** Assertions for the engine's tests (standard library only): each failure is an AssertionError. */
public final class Check {
    private Check() {}

    public static void isTrue(boolean cond, String what) {
        if (!cond) throw new AssertionError(what);
    }

    public static void eq(Object want, Object got, String what) {
        if (!Objects.equals(want, got))
            throw new AssertionError(what + ": want " + show(want) + ", got " + show(got));
    }

    /** Doubles equal bit for bit (the engine's output must not change by one bit). */
    public static void same(double want, double got, String what) {
        if (Double.doubleToRawLongBits(want) != Double.doubleToRawLongBits(got))
            throw new AssertionError(what + ": want " + want + ", got " + got);
    }

    public static void near(double want, double got, double tol, String what) {
        if (!(Math.abs(want - got) <= tol)) throw new AssertionError(what + ": want " + want + " ± " + tol + ", got " + got);
    }

    /** The same JSON text. */
    public static void sameJson(Object want, Object got, String what) {
        eq(Json.write(want), Json.write(got), what);
    }

    public interface Body {
        void run() throws Exception;
    }

    /** The body throws an exception of the class. */
    public static <T extends Throwable> T throwsA(Class<T> type, Body body, String what) {
        try {
            body.run();
        } catch (Throwable t) {
            if (type.isInstance(t)) return type.cast(t);
            throw new AssertionError(what + ": want " + type.getSimpleName() + ", got " + t, t);
        }
        throw new AssertionError(what + ": want " + type.getSimpleName() + ", got no exception");
    }

    private static String show(Object o) {
        try {
            return Json.write(o);
        } catch (RuntimeException e) {
            return String.valueOf(o);
        }
    }
}
