from map_tools_ps2.primitives import metadata_strip_restart_boundaries


def test_metadata_topology_05_restarts_every_four_vertices_for_20_vertex_blocks() -> None:
    assert metadata_strip_restart_boundaries(0x05, 10, 20) == {4, 8, 12, 16}


def test_metadata_topology_05_restarts_every_four_vertices_for_8_vertex_blocks() -> None:
    assert metadata_strip_restart_boundaries(0x05, 4, 8) == {4}


def test_metadata_topology_05_requires_proven_face_count_relation() -> None:
    assert metadata_strip_restart_boundaries(0x05, 9, 20) == set()


def test_metadata_restart_rule_does_not_apply_to_other_topology_codes() -> None:
    assert metadata_strip_restart_boundaries(0x04, 10, 20) == set()
