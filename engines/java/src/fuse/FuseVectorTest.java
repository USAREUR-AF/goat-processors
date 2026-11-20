package fuse;

/**
 * The fuse conformance vectors (goat.io.Vectors). Kept under this name for the perf harness and
 * CI, which run {@code java -cp build fuse.FuseVectorTest <root>}.
 */
public final class FuseVectorTest {
    private FuseVectorTest() {}

    public static void main(String[] args) throws java.io.IOException {
        java.nio.file.Path root = java.nio.file.Paths.get(args.length > 0 ? args[0] : ".");
        System.exit(goat.io.Vectors.run("fuse", root) == 0 ? 0 : 1);
    }
}
