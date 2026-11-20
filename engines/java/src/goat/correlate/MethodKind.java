package goat.correlate;

import goat.io.LoadError;

import java.util.List;

/**
 * One correlate method (correlate.md, Pack, {@code method}): its name, how to make it, the
 * directives only it takes, the directives it requires (in the order they are checked), and its
 * checks once the whole pack is read. A method is added by registering one of these
 * ({@link Registry#withMethod}).
 */
public final class MethodKind {

    public interface Factory {
        Method create(Correlator engine, CorrelatePack pack);
    }

    public interface Check {
        void check(CorrelatePack pack) throws LoadError;
    }

    public final String name;
    public final Factory factory;
    public final List<Directive> directives;
    public final List<String> required;
    public final Check check;

    public MethodKind(String name, Factory factory, List<Directive> directives, List<String> required, Check check) {
        this.name = name;
        this.factory = factory;
        this.directives = List.copyOf(directives);
        this.required = List.copyOf(required);
        this.check = check;
    }
}
