package goat.correlate;

import goat.io.LoadError;

/** One pack.def directive: its name, whether it may repeat, and how its line is read into the pack. */
public final class Directive {

    public interface Parser {
        void parse(CorrelatePack pack, String[] tok, int line) throws LoadError;
    }

    public final String name;
    public final boolean repeating;
    public final Parser parser;

    public Directive(String name, boolean repeating, Parser parser) {
        this.name = name;
        this.repeating = repeating;
        this.parser = parser;
    }
}
