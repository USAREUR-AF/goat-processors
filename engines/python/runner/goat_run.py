"""Command-line runner of the Python engine: tools/perf/README.md, "Runner
contract". The runner itself is goat_core.io.main."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

from goat_core import FUNCTIONS  # noqa: E402
from goat_core.io import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], FUNCTIONS))
