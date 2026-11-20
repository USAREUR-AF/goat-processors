package goat.io;

import goat.correlate.Correlator;
import goat.filter.FilterProcessor;
import goat.fuse.Fuse;
import goat.quality.Quality;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** The functions of this engine, by the name the runner and the vectors use: one table entry each. */
public final class Functions {
    private Functions() {}

    /** A function's load_pack from the text of its pack.def, giving a fresh processor. */
    public interface Loader {
        Processor fromText(String packDef) throws LoadError;
    }

    private static final Map<String, Loader> TABLE = new LinkedHashMap<>();
    static {
        TABLE.put("correlate", Correlator::fromText);
        TABLE.put("filter", FilterProcessor::fromText);
        TABLE.put("fuse", Fuse::fromText);
        TABLE.put("quality", Quality::fromText);
    }

    public static Set<String> names() {
        return Collections.unmodifiableSet(TABLE.keySet());
    }

    /** load_pack of the function from pack.def text; an unknown function is an IllegalArgumentException. */
    public static Processor fromText(String function, String packDef) throws LoadError {
        Loader l = TABLE.get(function);
        if (l == null) throw new IllegalArgumentException("unknown function " + function);
        return l.fromText(packDef);
    }

    /** load_pack(dir) of the function. */
    public static Processor load(String function, Path dir) throws LoadError {
        if (!TABLE.containsKey(function)) throw new IllegalArgumentException("unknown function " + function);
        String text;
        try {
            text = PackFile.read(dir);
        } catch (IOException e) {
            throw new LoadError("cannot read " + dir + ": " + e.getMessage());
        }
        return fromText(function, text);
    }
}
