"""Export HP2 AI driving routes in a readable, lossless text format."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from .model import Scene, TrackRouteSegment
from .progress import report_progress


def _number(value: float) -> str:
    return f"{float(value):.9g}"


def _hex(value: int) -> str:
    return f"0x{int(value) & 0xFFFFFFFF:08x}"


def _position(point: Any) -> tuple[float, float, float]:
    value = point.position_ps2
    return float(value.x), float(value.y), float(value.z)


def _validate_segments(segments: tuple[TrackRouteSegment, ...]) -> tuple[int, int, list[dict[str, Any]]]:
    invalid = 0
    duplicate = 0
    seen_positions: set[tuple[float, float, float]] = set()
    edge_sources: list[dict[str, Any]] = []
    for segment in segments:
        for expected_index, point in enumerate(segment.points):
            if point.index != expected_index:
                invalid += 1
            position = _position(point)
            if not all(math.isfinite(value) for value in position):
                invalid += 1
            if position in seen_positions:
                duplicate += 1
            seen_positions.add(position)
            if point.route_edge_index != 0xFF:
                edge_sources.append({
                    "route_index": segment.route_index,
                    "point_index": point.index,
                    "edge_index": int(point.route_edge_index),
                })
    return invalid, duplicate, edge_sources


def _point_roles(segments: tuple[TrackRouteSegment, ...], edges: tuple[Any, ...], edge_sources: list[dict[str, Any]]) -> dict[tuple[int, int], str]:
    """Infer route roles from the directed segment/edge topology."""
    roles: dict[tuple[int, int], str] = {}
    incoming = {
        (int(edge.target_route_index), int(edge.target_point_index))
        for edge in edges
        if 0 <= int(edge.target_point_index) < 0x400
    }
    outgoing = {
        (int(source["route_index"]), int(source["point_index"]))
        for source in edge_sources
    }
    for segment in segments:
        if segment.points and (segment.route_index, segment.points[0].index) not in incoming:
            roles[(segment.route_index, segment.points[0].index)] = "start"
        if segment.points:
            last = segment.points[-1]
            if (segment.route_index, last.index) not in outgoing:
                roles[(segment.route_index, last.index)] = "end"
    for source in edge_sources:
        key = (int(source["route_index"]), int(source["point_index"]))
        if roles.get(key) not in {"start", "end"}:
            roles[key] = "branch"
    return roles


def write_route_txt(scene: Scene, output: Path, track: int | str = 0, progress: bool = True) -> Path:
    """Write TRACK_ROUTE data and its edge graph to *output*.

    MTA uses the same XYZ axis order as the exported MTA geometry in this
    project, so the single ``position`` field is directly usable by MTA.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    segments = tuple(scene.track_route_segments)
    edges = tuple(scene.track_route_edges)
    radar_points = tuple(scene.route_points)
    invalid_points, duplicate_points, edge_sources = _validate_segments(segments)
    point_roles = _point_roles(segments, edges, edge_sources)
    invalid_edges = 0
    edge_records: list[tuple[Any, str]] = []
    segment_by_route = {segment.route_index: segment for segment in segments}
    for source in edge_sources:
        edge_index = source["edge_index"]
        if edge_index < 0 or edge_index >= len(edges):
            invalid_edges += 1
    lines = [
        "# HP2 AI Route",
        f"# Track: {track}",
        "# Coordinate system: MTA_XYZ",
        "# Position format: x,y,z (MTA world coordinates)",
        "",
        "[ROUTE]",
        f"segments={len(segments)}",
        f"points={sum(len(segment.points) for segment in segments)}",
        f"edges={len(edges)}",
        "",
    ]
    for segment_index, segment in enumerate(segments):
        lines.extend([
            f"[SEGMENT {segment_index}]",
            f"route_index={segment.route_index}",
            f"route_type={segment.route_type}",
            f"flags={_hex(segment.flags)}",
            f"point_count={len(segment.points)}",
            "",
        ])
        point_iter = enumerate(segment.points, 1)
        for point_number, point in point_iter:
            x, y, z = _position(point)
            lines.extend([
                f"POINT {point_number - 1}",
                f"index={point.index}",
                f"position={','.join(_number(value) for value in (x, y, z))}",
                f"forward={','.join(_number(value) for value in point.forward_ps2_2d)}",
                f"left_width={_number(point.left_width)}",
                f"right_width={_number(point.right_width)}",
                f"segment_length={_number(point.segment_length)}",
                f"edge_index={int(point.route_edge_index)}",
                f"edge_flags={_hex(point.route_edge_flags)}",
                f"point_role={point_roles.get((segment.route_index, point.index), 'normal')}",
                "",
            ])
            if progress:
                report_progress("Exporting AI route waypoints", point_number, len(segment.points), f"route {segment.route_index}")

    lines.extend(["[EDGES]", f"count={len(edges)}", ""])
    for edge_index, edge in enumerate(edges):
        valid_source = next((source for source in edge_sources if source["edge_index"] == edge_index), None)
        target_valid = edge.target_route_index in segment_by_route and 0 <= edge.target_point_index < len(segment_by_route[edge.target_route_index].points)
        status = "ok" if valid_source is not None and target_valid else "invalid_target" if not target_valid else "unreferenced"
        lines.extend([
            f"EDGE {edge_index}",
            f"source_route_index={valid_source['route_index'] if valid_source else -1}",
            f"source_point_index={valid_source['point_index'] if valid_source else -1}",
            f"target_route_index={edge.target_route_index}",
            f"target_point_index={edge.target_point_index}",
            f"mode={edge.mode}",
            f"metadata0={_hex(edge.metadata0)}",
            f"metadata1={_hex(edge.metadata1)}",
            f"status={status}",
            "",
        ])
        if progress:
            report_progress("Exporting AI route edges", edge_index + 1, len(edges), f"edge {edge_index}")

    lines.extend(["[RADAR_POINTS]", f"count={len(radar_points)}", ""])
    for point_index, point in enumerate(radar_points):
        x, z = point.get("position_ps2_2d", (0.0, 0.0))
        lines.extend([
            f"POINT {point_index}",
            f"name={point.get('name', '')}",
            f"position={_number(x)},{_number(z)}",
            f"route_sequence={int(point.get('route_sequence', -1))}",
            f"route_group={point.get('route_group', '')}",
            "",
        ])
    output.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    report = {
        "track": int(track) if str(track).isdigit() else str(track),
        "source": "TRACK_ROUTE",
        "segments": len(segments),
        "waypoints": sum(len(segment.points) for segment in segments),
        "edges": len(edges),
        "radar_points": len(radar_points),
        "invalid_points": invalid_points,
        "invalid_edges": invalid_edges,
        "duplicate_points": duplicate_points,
        "start_points": sum(role == "start" for role in point_roles.values()),
        "end_points": sum(role == "end" for role in point_roles.values()),
        "branch_points": sum(role == "branch" for role in point_roles.values()),
        "coordinate_system": "MTA_XYZ",
        "ps2_coordinate_system": "PS2_XYZ",
        "output": output.name,
    }
    output.with_name("route.report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return output
