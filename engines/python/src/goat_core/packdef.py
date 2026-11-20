"""pack.def: the error every function's pack parser raises.

Each function's grammar is in its own module (correlate, filter, fuse,
quality); this holds only what they share."""


class PackError(Exception):
    """A pack.def that does not load (the text is not compared by any vector)."""
