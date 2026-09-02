import json

from map_tools_ps2.binary import Vec3
from map_tools_ps2.model import Scene, TrackRouteEdge, TrackRoutePoint, TrackRouteSegment
from map_tools_ps2.route_export import write_route_txt


def _point(index: int, z: float, edge_index: int = 0xFF) -> TrackRoutePoint:
    return TrackRoutePoint(
        index=index,
        position_ps2=Vec3(10.0 + index, 20.0, z),
        forward_ps2_2d=(1.0, 0.0),
        segment_length=4.5,
        left_width=3.0,
        right_width=3.5,
        route_edge_index=edge_index,
        route_edge_flags=0xFF,
        boundary_offsets_raw=(0, 0, 0, 0),
        boundary_offsets=(0.0, 0.0, 0.0, 0.0),
        source_record_offset=0,
    )


def test_write_route_txt_preserves_segments_edges_and_coordinate_conventions(tmp_path):
    scene = Scene(
        track_route_segments=[
            TrackRouteSegment(0, 7, 1, 2, (_point(0, 30.0), _point(1, 32.0, 0)), 0, 0),
            TrackRouteSegment(1, 9, 2, 3, (_point(0, 40.0),), 0, 0),
        ],
            track_route_edges=[TrackRouteEdge(0, 9, 0, 0, 5, 6, 0, 0)],
        route_points=[
            {
                "name": "TRACK_ROUTE_000",
                "position_ps2_2d": (10.0, 30.0),
                "route_sequence": 0,
                "route_group": "TRACK_ROUTE",
            }
        ],
    )
    output = write_route_txt(scene, tmp_path / "nested" / "route.txt", 31)
    text = output.read_text(encoding="utf-8")
    report = json.loads((output.parent / "route.report.json").read_text(encoding="utf-8"))

    assert output.exists()
    assert "position=10,20,30" in text
    assert "position=10,20,30" in text
    assert "mta_position=" not in text
    assert "ps2_position=" not in text
    assert "route_index=7" in text
    assert "target_route_index=9" in text
    assert "status=ok" in text
    assert "point_role=start" in text
    assert "point_role=end" in text
    assert "point_role=branch" in text
    assert "boundary_offsets=0,0,0,0" in text
    assert "[TRAFFIC_CANDIDATES]" in text
    assert "TRAFFIC_ROUTE 7" in text
    assert "[RADAR_POINTS]" in text
    assert report["segments"] == 2
    assert report["waypoints"] == 3
    assert report["edges"] == 1
    assert report["invalid_edges"] == 0
    assert report["traffic_candidates"][0]["route_index"] == 7


def test_write_route_txt_handles_empty_route(tmp_path):
    output = write_route_txt(Scene(), tmp_path / "new" / "route.txt", 61)
    text = output.read_text(encoding="utf-8")
    report = json.loads((output.parent / "route.report.json").read_text(encoding="utf-8"))

    assert "segments=0" in text
    assert "points=0" in text
    assert report["waypoints"] == 0
    assert report["radar_points"] == 0
