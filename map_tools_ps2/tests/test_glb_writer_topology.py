from map_tools_ps2.binary import Vec3
from map_tools_ps2.glb_writer import _indices_for_block
from map_tools_ps2.model import DecodedBlock
from map_tools_ps2.vif import VifVertexRun


def _block(vertex_count: int, expected_faces: int) -> DecodedBlock:
    return DecodedBlock(
        run=VifVertexRun(
            vertices=tuple(Vec3(0.0, 0.0, 0.0) for _ in range(vertex_count)),
            texcoords=(),
            packed_values=(),
            header=None,
        ),
        primitive_mode="strip",
        expected_face_count=expected_faces,
        topology_code=0x05,
    )


def _quad_strip_vertices(segment_count: int) -> tuple[Vec3, ...]:
    vertices: list[Vec3] = []
    for segment_index in range(segment_count):
        base = segment_index * 10.0
        vertices.extend(
            (
                Vec3(base, 0.0, 0.0),
                Vec3(base, 1.0, 0.0),
                Vec3(base + 1.0, 0.0, 0.0),
                Vec3(base + 1.0, 1.0, 0.0),
            )
        )
    return tuple(vertices)


def test_topology_05_twenty_vertex_block_emits_five_restarted_strip_segments() -> None:
    assert _indices_for_block(_quad_strip_vertices(5), "XS_LIGHTPOSTA_1_00", _block(20, 10)) == [
        0,
        1,
        2,
        1,
        3,
        2,
        4,
        5,
        6,
        5,
        7,
        6,
        8,
        9,
        10,
        9,
        11,
        10,
        12,
        13,
        14,
        13,
        15,
        14,
        16,
        17,
        18,
        17,
        19,
        18,
    ]


def test_topology_05_eight_vertex_block_emits_two_restarted_strip_segments() -> None:
    assert _indices_for_block(_quad_strip_vertices(2), "STEPHANE_MANSIONA_01", _block(8, 4)) == [
        0,
        1,
        2,
        1,
        3,
        2,
        4,
        5,
        6,
        5,
        7,
        6,
    ]
