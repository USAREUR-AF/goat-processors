package quality;

/**
 * The quality conformance vectors (goat.io.Vectors). Kept under this name for the perf harness and
 * CI, which run {@code java -cp build quality.VectorTest <root>}.
 */
public final class VectorTest {
    private VectorTest() {}

    public static void main(String[] args) throws java.io.IOException {
        java.nio.file.Path root = java.nio.file.Paths.get(args.length > 0 ? args[0] : ".");
        System.exit(goat.io.Vectors.run("quality", root) == 0 ? 0 : 1);
    }
}
