"""Correlate (spec/correlate.md, spec/correlate-assign.md): the tables a
correlate pack is read with, and the engine of a pack's method.

METHODS is the one table of methods and gate.TESTS the one table of tests.
Adding a method is one METHODS entry (its engine class, the directives it
requires and those it refuses); adding a test is one TESTS entry. A test or
method for one use only (a test fixture, an experiment) is given to
parse_pack with gate.extend / extend_methods, and no other pack sees it."""

from types import MappingProxyType

from . import correlate_pack
from .assign import AssignEngine
from .confirm import ConfirmEngine
from .correlate_pack import Pack, PackError  # noqa: F401  (re-exported)
from .gate import TESTS
from .packdef import read_pack_def


class Method:
    """One correlate method: its engine class (a tracks.Correlator), the
    directives a pack of this method must hold, and those it must not
    (a stage name, gate, confirm or hold, refuses every test line of it)."""

    __slots__ = ("engine", "required", "refused")

    def __init__(self, engine, required, refused):
        self.engine = engine
        self.required = required
        self.refused = refused


METHODS = MappingProxyType({
    "confirm": Method(ConfirmEngine,
                      required=("pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"),
                      refused=("new_cost", "keep_bonus", "window", "hypotheses", "bias", "margin",
                               "time_offset")),
    "assign": Method(AssignEngine,
                     required=("pack", "version", "filter", "new_cost", "keep_bonus", "stale_ms"),
                     refused=("confirm", "hold", "confirm_count", "hold_failures", "same_source",
                              "output", "priority", "sprt")),
})


def extend_methods(methods, name, method):
    """A new table: `methods` with one more method. The table given is unchanged."""
    if name in methods:
        raise ValueError("method %s is already in the table" % name)
    out = dict(methods)
    out[name] = method
    return MappingProxyType(out)


def parse_pack(text, tests=TESTS, methods=METHODS):
    """A correlate pack.def; raises PackError."""
    return correlate_pack.parse_pack(text, tests, methods)


def load_pack(directory, tests=TESTS, methods=METHODS):
    return parse_pack(read_pack_def(directory), tests, methods)


def make_engine(pack):
    """The engine of the pack's method."""
    return pack.methods[pack.method].engine(pack)
