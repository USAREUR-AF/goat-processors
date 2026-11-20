"""The no-op test kind of tests/test_registration.py, registered here and
nowhere else: one gate.extend call."""

from goat_core import gate


def _noop(eng, prm, a, b):
    """Always passes; value and limit null."""
    return None, None, True


NOOP = gate.TestKind(params=(), evaluate=_noop)
TESTS_WITH_NOOP = gate.extend(gate.TESTS, "noop", NOOP)
