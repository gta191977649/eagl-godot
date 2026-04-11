from __future__ import annotations

import configparser
from pathlib import Path

from ..models import DrvPath


def parse_drvpath(path: Path) -> DrvPath:
    cfg = configparser.ConfigParser(strict=False)
    cfg.optionxform = str.lower
    cfg.read(path, encoding="latin1")

    node_count = cfg.getint("path", "nodenum", fallback=-1)
    node_indices = [
        int(section[4:])
        for section in cfg.sections()
        if section.lower().startswith("node")
        and section[4:].isdigit()
        and cfg.has_option(section, "compartmentid")
    ]
    if node_count < 0 and node_indices:
        node_count = max(node_indices) + 1
    if node_count >= 0x40:
        node_count = 0x3F
    compartment_ids = [
        cfg.getint(f"node{index}", "compartmentid")
        for index in range(max(0, node_count))
        if cfg.has_option(f"node{index}", "compartmentid")
    ]
    start_nodes = []
    for section in cfg.sections():
        if cfg.has_option(section, "startnode"):
            start_nodes.append(cfg.getint(section, "startnode"))
    return DrvPath(compartment_ids=compartment_ids, start_nodes=start_nodes)
