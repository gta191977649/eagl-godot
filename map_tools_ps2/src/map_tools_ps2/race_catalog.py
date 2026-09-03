"""Validated HP2 driving profiles, independent of the rendering exporter.

Indices in these profiles are the source route IDs and zero-based point IDs.
Profiles are checked in: inference is an authoring operation, never a runtime
fallback. Mode bit 3 is reverse; low bits 2 and 3 are continuation and terminal.
The remaining bits are retained in edge evidence instead of discarded.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from .chunks import parse_chunks
from .comp import load_bundle_bytes
from .model import _parse_track_route_segments, _parse_track_route_edges

FAMILIES = {10: "parkland", 20: "desert", 30: "medit", 40: "alpine", 60: "tropic"}
TRACK_IDS = tuple(base + variant for base in FAMILIES for variant in range(1, 7))
PROFILE_PATH = Path(__file__).with_name("data") / "race_profiles.json"


def read_graph(game_dir: Path, track_id: int):
    directory = game_dir / "ZZDATA" / "TRACKS"
    source = directory / f"TRACKB{track_id}.LZC"
    if not source.exists():
        source = directory / f"TRACKB{track_id}.BUN"
    data = load_bundle_bytes(source)
    chunks = parse_chunks(data)
    return _parse_track_route_segments(chunks, data), _parse_track_route_edges(chunks, data)


def links_for(routes, edges):
    result = {}
    for route in routes:
        links = []
        for point in route.points:
            if point.route_edge_index < len(edges):
                edge = edges[point.route_edge_index]
                links.append((point.index, edge.target_route_index, edge.target_point_index, edge.mode))
        result[route.route_index] = links
    return result


def _span(route, start, end):
    return {"route": route, "from": start, "to": end}


def author_profile(track_id, routes, edges):
    """Produce a candidate profile with explicit source edge evidence."""
    racing = {r.route_index: r for r in routes if r.route_type == 0}
    links = links_for(routes, edges)
    first = min(racing)
    current, start = first, 0
    spans, used, evidence = [], set(), []
    closed = False
    while current not in used:
        used.add(current)
        route = racing[current]
        terminals = [e for e in links[current] if e[3] & 15 == 3 and e[0] >= start]
        continuations = [e for e in links[current] if e[3] & 15 == 2 and e[0] >= start and e[1] in racing]
        edge = max(terminals or continuations, key=lambda e: e[0]) if terminals or continuations else None
        if edge is None:
            raise ValueError(f"track {track_id}: no authored continuation for route {current}")
        spans.append(_span(current, start, edge[0]))
        evidence.append([current, *edge])
        if edge[3] & 15 == 3:
            reverse_terminals = [e[0] for e in links[first] if e[3] & 15 == 11]
            spans[0]["from"] = min(reverse_terminals) if reverse_terminals else 0
            break
        if edge[1] == first:
            spans[0]["from"] = edge[2]
            closed = True
            break
        current, start = edge[1], edge[2]
    else:
        raise ValueError(f"track {track_id}: continuation enters a secondary cycle")
    main_points = {(s["route"], i) for s in spans for i in range(s["from"], s["to"] + 1)}
    main_edges = {(e[0], e[1], e[2], e[3]) for e in evidence}
    shortcuts = []
    for span in spans:
        for point, target, target_point, mode in links[span["route"]]:
            if mode & 8 or not (span["from"] <= point < span["to"]):
                continue
            if target not in racing or (span["route"], point, target, target_point) in main_edges:
                continue
            branch, seen = [], set()
            cursor = (target, target_point)
            while cursor not in main_points and cursor not in seen:
                seen.add(cursor)
                r, p = cursor
                if r not in racing:
                    break
                # The first rejoin point on this segment wins over its end.
                joins = [i for rr, i in main_points if rr == r and i >= p]
                ends = [e for e in links[r] if e[3] & 15 == 2 and e[0] >= p and e[1] in racing]
                edge = max(ends, key=lambda e: e[0]) if ends else None
                if joins and (edge is None or min(joins) <= edge[0]):
                    end = min(joins)
                    branch.append(_span(r, p, end))
                    cursor = (r, end)
                elif edge:
                    branch.append(_span(r, p, edge[0]))
                    cursor = (edge[1], edge[2])
                else:
                    break
            if cursor in main_points and branch and cursor != (span["route"], point):
                shortcuts.append({"id": f"r{span['route']}_p{point}",
                    "entry": {"route": span["route"], "point": point},
                    "exit": {"route": cursor[0], "point": cursor[1]}, "branches": branch, "risk": 0.25})
    traffic = []
    traffic_routes = {r.route_index: r for r in routes if r.route_type == 1}
    visited = set()
    for route_id in sorted(traffic_routes):
        if route_id in visited:
            continue
        r, p, chain, seen = route_id, 0, [], set()
        while r not in seen:
            seen.add(r)
            candidates = [e for e in links[r] if e[3] & 15 == 2 and e[1] in traffic_routes and e[0] >= p]
            if not candidates:
                break
            edge = max(candidates, key=lambda e: e[0])
            chain.append(_span(r, p, edge[0]))
            if edge[1] == route_id:
                chain[0]["from"] = edge[2]
                traffic.append(chain)
                visited.update(seen)
                break
            r, p = edge[1], edge[2]
    profile = {"id": track_id, "family": FAMILIES[track_id // 10 * 10], "closed": closed,
        "type": "circuit" if closed else "sprint", "mainLoop": spans,
        "spawn": {"route": spans[0]["route"], "point": spans[0]["from"]},
        "shortcuts": shortcuts, "trafficPaths": traffic, "edgeEvidence": evidence}
    validate_profile(profile, routes, edges)
    return profile


def points_for(spans, routes):
    by_id = {r.route_index: r for r in routes}
    result = []
    for span in spans:
        route = by_id[span["route"]]
        step = 1 if span["to"] >= span["from"] else -1
        result.extend(route.points[i] for i in range(span["from"], span["to"] + step, step))
    return result


def validate_profile(profile, routes, edges):
    by_id = {r.route_index: r for r in routes}
    actual = links_for(routes, edges)
    if profile["type"] != ("circuit" if profile["closed"] else "sprint"):
        raise ValueError("race type disagrees with route closure")
    def connected(a, b):
        return a == b or any(e[0] == a[1] and (e[1], e[2]) == b for e in actual[a[0]])
    def check_chain(spans, closed=False):
        pairs = list(zip(spans, spans[1:]))
        if closed:
            pairs.append((spans[-1], spans[0]))
        for a, b in pairs:
            if not connected((a["route"], a["to"]), (b["route"], b["from"])):
                raise ValueError(f"track {profile['id']}: disconnected authored spans {a}, {b}")
    for spans in [profile["mainLoop"], *profile.get("trafficPaths", []),
                  *(s["branches"] for s in profile.get("shortcuts", []))]:
        for span in spans:
            route = by_id.get(span["route"])
            if route is None or min(span["from"], span["to"]) < 0 or max(span["from"], span["to"]) >= len(route.points):
                raise ValueError(f"track {profile['id']}: invalid range {span}")
        points = points_for(spans, routes)
        if len(points) < 2:
            raise ValueError("path needs at least two points")
        for point in points:
            if not all(math.isfinite(v) for v in (point.position_ps2.x, point.position_ps2.y, point.position_ps2.z)):
                raise ValueError("non-finite waypoint")
    # Source-authoritative continuation links must still exist after re-export.
    for route, source, target, target_point, mode in profile.get("edgeEvidence", []):
        if (source, target, target_point, mode) not in actual[route]:
            raise ValueError(f"track {profile['id']}: source graph changed at {route}:{source}")
    check_chain(profile["mainLoop"], profile["closed"])
    for spans in profile.get("trafficPaths", []):
        check_chain(spans, True)
    for shortcut in profile.get("shortcuts", []):
        spans = shortcut["branches"]
        check_chain(spans)
        for a, b in [((shortcut["entry"]["route"], shortcut["entry"]["point"]), (spans[0]["route"], spans[0]["from"])),
                     ((spans[-1]["route"], spans[-1]["to"]), (shortcut["exit"]["route"], shortcut["exit"]["point"]))]:
            if not connected(a, b):
                raise ValueError(f"track {profile['id']}: disconnected shortcut {shortcut['id']}")
    if not profile["closed"]:
        end = profile["mainLoop"][-1]
        if not any(e[0] == end["to"] and e[3] & 7 == 3 for e in actual[end["route"]]):
            raise ValueError(f"track {profile['id']}: sprint endpoint is not a source terminal")


def load_profiles():
    return {int(k): v for k, v in json.loads(PROFILE_PATH.read_text(encoding="utf-8"))["tracks"].items()}
