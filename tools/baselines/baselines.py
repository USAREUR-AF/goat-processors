"""The outside baselines the benchmark scores beside the packs.

Each is a tracker written with another project's code, run on the same
scenarios and scored by the same scorer. They need their own dependencies
(requirements.txt here); nothing else in the benchmark does.
"""

NAMES = ["stonesoup-gnn"]


def require():
    """Refuse, with what to do, when a baseline's dependencies are not installed."""
    try:
        import stonesoup  # noqa: F401
    except ImportError:
        raise SystemExit("the outside baselines need Stone Soup: pip install -r tools/baselines/requirements.txt")


def run(name, vector):
    """Run baseline `name` on one scenario; return its events file object."""
    if name == "stonesoup-gnn":
        import stonesoup_gnn
        return stonesoup_gnn.run(vector)
    raise ValueError("no baseline %s" % name)
