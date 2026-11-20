package goat.coverage;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/** Loads and initializes every class of a classes directory, so the coverage tool sees every line. */
public final class LoadAll {
    private LoadAll() {}

    public static void main(String[] args) throws IOException {
        Path dir = Paths.get(args[0]);
        List<String> names;
        try (Stream<Path> s = Files.walk(dir)) {
            names = s.filter(p -> p.toString().endsWith(".class"))
                    .map(p -> dir.relativize(p).toString().replace(java.io.File.separatorChar, '.'))
                    .map(n -> n.substring(0, n.length() - ".class".length()))
                    .sorted().collect(Collectors.toList());
        }
        for (String n : names) {
            try {
                Class.forName(n, true, LoadAll.class.getClassLoader());
            } catch (Throwable t) {
                System.err.println("coverage: cannot load " + n + ": " + t);
            }
        }
    }
}
