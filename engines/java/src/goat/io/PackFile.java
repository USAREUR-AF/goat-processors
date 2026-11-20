package goat.io;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** load_pack(dir): the text of {@code dir/pack.def}. */
public final class PackFile {
    private PackFile() {}

    public static String read(Path dir) throws IOException {
        return new String(Files.readAllBytes(dir.resolve("pack.def")), StandardCharsets.UTF_8);
    }
}
