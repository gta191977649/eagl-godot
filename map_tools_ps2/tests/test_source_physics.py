import struct

from map_tools_ps2.chunks import Chunk
from map_tools_ps2.source_physics import parse_source_physics


def fixture():
    data = bytearray(1024)
    # Each aligned structure has a deliberately misaligned payload; bindings
    # deliberately start unaligned. Engine section id is 11, not enumerate=0.
    template = Chunk(0x34026, 232, 0, 8)
    struct.pack_into('<I', data, 16 + 0x70, 0x12345678)
    data[24:30] = b'ANY_CS'
    struct.pack_into('<f', data, 16 + 0x20, 0.005)
    header = Chunk(0x34021, 104, 240, 248)
    struct.pack_into('<I', data, 256 + 0x30, 0x12345678)
    points = Chunk(0x34024, 28, 352, 360)
    struct.pack_into('<3f', data, 368 + 4, 1, 2, 3)
    collisions = Chunk(0x80034020, 148, 232, 240, (header, points))
    section_header = Chunk(0x34101, 56, 400, 408)
    struct.pack_into('<I', data, 416 + 8, 11)
    info = Chunk(0x34102, 40, 464, 472)
    # The LOD thresholds must never participate in collision binding.
    struct.pack_into('<3I3h', data, 472, 0xdeadbeef, 0, 0, 300, 100, 5)
    instances = Chunk(0x34103, 56, 512, 520)
    struct.pack_into('<h', data, 528 + 12, 0)
    section = Chunk(0x80034100, 176, 392, 400, (section_header, info, instances))
    bindings = Chunk(0x34027, 8, 580, 588)
    struct.pack_into('<Ihh', data, 588, 0x12345678, 11, 0)
    return data, (template, collisions, section, bindings)


def test_engine_alignment_and_hash_instance_join():
    data, chunks = fixture()
    result = parse_source_physics(chunks, bytes(data))
    assert not result.errors
    template, = result.templates
    binding, = result.bindings
    assert template.name == 'ANY_CS'
    assert template.collision_header_offset == 256
    assert template.collision_points == ((1, 2, 3),)
    assert abs(template.mass_engine_units - .005) < 1e-9
    assert binding.model_hashes == (0xdeadbeef, 0, 0)
    assert binding.instance_chunk_offset == 512
    assert binding.section_id == 11
    assert binding.error is None


def test_unknown_template_does_not_fall_back_to_name_or_lod():
    data, chunks = fixture()
    struct.pack_into('<I', data, 588, 300)
    binding, = parse_source_physics(chunks, bytes(data)).bindings
    assert binding.error == 'missing_physics_template'
    assert binding.template_hash == 300


def test_invalid_instance_is_reported_without_out_of_bounds_read():
    data, chunks = fixture()
    struct.pack_into('<h', data, 594, 1)
    binding, = parse_source_physics(chunks, bytes(data)).bindings
    assert binding.error == 'invalid_instance_index'
    assert binding.model_hashes is None


def test_unknown_section_does_not_fall_back_to_enumeration():
    data, chunks = fixture()
    struct.pack_into('<h', data, 592, 0)
    binding, = parse_source_physics(chunks, bytes(data)).bindings
    assert binding.error == 'missing_section_or_instances'


def test_malformed_template_stride_is_not_silently_accepted():
    data, chunks = fixture()
    malformed = Chunk(0x34026, 231, 0, 8)
    result = parse_source_physics((malformed, *chunks[1:]), bytes(data))
    assert result.errors == ('invalid_template_stride@0',)
    assert not result.templates


def test_same_model_hash_can_have_different_physics_per_instance():
    data, chunks = fixture()
    # Add a second binding to the same model, with a different source template
    # hash: retain both records, including the unresolved state.
    struct.pack_into('<Ihh', data, 596, 0x87654321, 11, 0)
    bindings = Chunk(0x34027, 16, 580, 588)
    result = parse_source_physics((*chunks[:-1], bindings), bytes(data))
    assert len(result.bindings) == 2
    assert result.bindings[0].model_hashes == result.bindings[1].model_hashes
    assert result.bindings[0].template_hash != result.bindings[1].template_hash


def test_streaming_dedup_preserves_different_physics_and_positions():
    from dataclasses import replace
    from map_tools_ps2.model import SceneryInstance
    from map_tools_ps2.mta_scene import _deduplicate_scenery_instances
    transform = ((1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1))
    first = SceneryInstance(0, 'same_name', transform, 100, 0)
    same = replace(first, source_chunk_offset=200)
    other_physics = replace(first, source_chunk_offset=300)
    other_position = replace(first, transform=(*transform[:3], (10, 0, 0, 1)))
    states = {(100, 0): ((1, None),), (200, 0): ((1, None),), (300, 0): ((2, None),)}
    unique, report = _deduplicate_scenery_instances([first, same, other_physics, other_position], states)
    assert unique == [first, other_physics, other_position]
    assert report['duplicate_placements_removed'] == 1


def test_unresolved_physics_does_not_merge_with_static_placement():
    from dataclasses import replace
    from map_tools_ps2.model import SceneryInstance
    from map_tools_ps2.mta_scene import _deduplicate_scenery_instances
    transform = ((1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1))
    first = SceneryInstance(0, 'same_name', transform, 100, 0)
    second = replace(first, source_chunk_offset=200)
    unique, _ = _deduplicate_scenery_instances(
        [first, second], {(100, 0): ((123, 'missing_physics_template'),)})
    assert len(unique) == 2
