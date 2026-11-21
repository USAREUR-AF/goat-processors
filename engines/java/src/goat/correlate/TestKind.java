package goat.correlate;

import goat.io.LoadError;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * One kind of test (correlate.md, Tests): its name, its parameters in pack order, which of them
 * are text (the others are numbers), and its formula giving one trace record. A test is added
 * by registering one of these ({@link Registry#withTest}).
 */
public final class TestKind {

    /** The formula: A against B predicted (and moved) to A's time; returns the trace record. */
    public interface Formula {
        Map<String, Object> apply(CorrelatePack.Test t, String stage, Entity a, Entity b, Predicted pb);
    }

    /** Checks of the parameter values once the line is read (correlate.md, Pack); a load error when they fail. */
    public interface Check {
        void check(CorrelatePack.Test t, int line) throws LoadError;
    }

    /** No check beyond the parameters parsing. */
    public static final Check NO_CHECK = (t, line) -> {};

    public final String name;
    public final List<String> params;
    public final Set<String> textParams;
    public final Formula formula;
    public final Check check;

    public TestKind(String name, List<String> params, Set<String> textParams, Check check, Formula formula) {
        this.name = name;
        this.params = List.copyOf(params);
        this.textParams = Set.copyOf(textParams);
        this.check = check;
        this.formula = formula;
    }

    public TestKind(String name, List<String> params, Set<String> textParams, Formula formula) {
        this(name, params, textParams, NO_CHECK, formula);
    }

    public TestKind(String name, List<String> params, Formula formula) {
        this(name, params, Set.of(), formula);
    }
}
