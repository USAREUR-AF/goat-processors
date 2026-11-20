package goat.io;

/** A pack that does not load: load_pack's error, for every function. */
public final class LoadError extends Exception {
    private static final long serialVersionUID = 1L;

    public LoadError(String message) {
        super(message);
    }
}
