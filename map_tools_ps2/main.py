from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from map_tools_ps2.cli import main


if __name__ == "__main__":
    if len(sys.argv) == 1 or sys.argv[1] == "--gui":
        from map_tools_ps2.gui import run_gui

        raise SystemExit(run_gui())
    raise SystemExit(main())
