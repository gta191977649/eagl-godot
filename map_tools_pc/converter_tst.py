#!/usr/bin/env python3
from __future__ import annotations

import sys

from main import main


if __name__ == "__main__":
    print("warning: converter_tst.py is deprecated; use main.py instead", file=sys.stderr)
    raise SystemExit(main())
