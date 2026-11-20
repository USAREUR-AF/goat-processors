"""pack.def: the error every function's pack parser raises.

Each function's grammar is in its own module (correlate, filter, fuse,
quality); this holds only what they share."""


class PackError(Exception):
    """A pack.def that does not load (the text is not compared by any vector)."""


def decimal_int(v, what):
    """int(v, 10) for a string of ASCII digits the caller has checked, as a
    PackError when it is longer than Python converts (sys.int_info:
    4300 digits by default)."""
    try:
        return int(v, 10)
    except ValueError:
        raise PackError("%s: integer too long: %d digits" % (what, len(v)))
