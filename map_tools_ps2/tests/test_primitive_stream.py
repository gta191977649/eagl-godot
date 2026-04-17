import struct
import unittest

from map_tools_ps2.binary import Vec3
from map_tools_ps2.model import DecodedBlock
from map_tools_ps2.primitive_stream import (
    GS_PRIM_TRIANGLE,
    GS_PRIM_TRIANGLE_FAN,
    GS_PRIM_TRIANGLE_STRIP,
    PrimitiveStream,
    adc_disabled_from_vif_control,
    assemble_primitive_stream_indices,
    primitive_stream_for_block,
)
from map_tools_ps2.strip_entries import parse_strip_entry_record
from map_tools_ps2.vif import VifVertexRun, parse_vif_command_events


def _vertices(count: int) -> tuple[Vec3, ...]:
    return tuple(Vec3(float(index), 0.0, 0.0) for index in range(count))


def _stream(prim_type: int, count: int, disabled: set[int] | None = None) -> PrimitiveStream:
    return PrimitiveStream(
        prim_type=prim_type,
        vertices=_vertices(count),
        texcoords=(),
        packed_values=(),
        metadata_record=None,
        adc_disabled=tuple(index in (disabled or set()) for index in range(count)),
        segments=((0, count),),
        source_proof="fallback",
    )


class PrimitiveStreamTests(unittest.TestCase):
    def test_triangle_list_skips_triangle_when_trigger_vertex_is_adc_disabled(self):
        self.assertEqual(
            assemble_primitive_stream_indices(_stream(GS_PRIM_TRIANGLE, 6, {2})),
            [3, 4, 5],
        )

    def test_triangle_strip_uses_gs_winding_and_adc_skip(self):
        self.assertEqual(
            assemble_primitive_stream_indices(_stream(GS_PRIM_TRIANGLE_STRIP, 6, {4})),
            [0, 1, 2, 3, 2, 1, 3, 4, 5],
        )

    def test_triangle_strip_resets_winding_after_adc_skip(self):
        self.assertEqual(
            assemble_primitive_stream_indices(_stream(GS_PRIM_TRIANGLE_STRIP, 8, {0, 1, 4, 5})),
            [0, 1, 2, 3, 2, 1, 4, 5, 6, 7, 6, 5],
        )

    def test_triangle_fan_skips_triangle_when_incoming_vertex_is_adc_disabled(self):
        self.assertEqual(
            assemble_primitive_stream_indices(_stream(GS_PRIM_TRIANGLE_FAN, 5, {3})),
            [0, 1, 2, 0, 3, 4],
        )

    def test_topology_metadata_without_vif_control_stays_fallback(self):
        block = DecodedBlock(
            run=VifVertexRun(_vertices(20), (), (), (20, 4, 60, 252)),
            primitive_mode="strip",
            expected_face_count=10,
            topology_code=0x05,
        )
        stream = primitive_stream_for_block(_vertices(20), block)

        self.assertEqual(stream.source_proof, "fallback")
        self.assertEqual(stream.segments, ((0, 20),))
        self.assertEqual(tuple(index for index, disabled in enumerate(stream.adc_disabled) if disabled), ())

    def test_vif_control_mask_builds_source_backed_adc_stream(self):
        block = DecodedBlock(
            run=VifVertexRun(
                _vertices(20),
                (),
                (),
                (20, 4, 60, 252),
                (0x00286666, 0, 0, 0x00433330),
            ),
            primitive_mode="strip",
            expected_face_count=10,
            topology_code=0x08,
        )
        stream = primitive_stream_for_block(_vertices(20), block)

        self.assertEqual(stream.source_proof, "vif_control")
        self.assertEqual(stream.segments, ((0, 4), (4, 8), (8, 12), (12, 16), (16, 20)))
        self.assertEqual(
            tuple(index for index, disabled in enumerate(stream.adc_disabled) if disabled),
            (0, 1, 4, 5, 8, 9, 12, 13, 16, 17),
        )
        self.assertEqual(len(assemble_primitive_stream_indices(stream)) // 3, 10)
        self.assertEqual(
            assemble_primitive_stream_indices(stream)[:6],
            [0, 1, 2, 3, 2, 1],
        )

    def test_vif_control_mask_matches_modelulator_skip_pattern(self):
        self.assertEqual(
            adc_disabled_from_vif_control(
                (28, 6, 84, 252),
                (0x00286666, 0, 0, 0x00433330),
                28,
            ),
            tuple(index in {0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25} for index in range(28)),
        )

    def test_unproven_block_stays_explicit_fallback(self):
        block = DecodedBlock(
            run=VifVertexRun(_vertices(20), (), (), None),
            primitive_mode="strip",
            expected_face_count=9,
            topology_code=0x05,
        )

        self.assertEqual(primitive_stream_for_block(_vertices(20), block).source_proof, "fallback")


class StripEntryRecordTests(unittest.TestCase):
    def test_strip_entry_parser_preserves_raw_fields(self):
        record = bytearray(0x40)
        struct.pack_into("<I", record, 0x00, 4)
        struct.pack_into("<I", record, 0x08, 0x1170)
        struct.pack_into("<I", record, 0x0C, 0x1234001F)
        struct.pack_into("<I", record, 0x1C, 0xFC140405)

        parsed = parse_strip_entry_record(bytes(record))

        self.assertEqual(parsed.raw, bytes(record))
        self.assertEqual(parsed.texture_index, 4)
        self.assertEqual(parsed.vif_offset, 0x1170)
        self.assertEqual(parsed.qword_count, 0x1F)
        self.assertEqual(parsed.qword_size, 0x1F0)
        self.assertEqual(parsed.render_flags, 0x1234)
        self.assertEqual(parsed.topology_code, 0x05)
        self.assertEqual(parsed.vertex_count_byte, 0x04)
        self.assertEqual(parsed.count_byte, 0x14)
        self.assertEqual(parsed.packed_ff_or_zero, 0xFC)


class VifCommandEventTests(unittest.TestCase):
    def test_parse_vif_command_events_preserves_unpack_payloads_and_flush(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((20, 4, 60, 252)))
        payload.extend(struct.pack("<HBB", 0xC034, 4, 0x6F))
        payload.extend(struct.pack("<HHHH", 1, 2, 3, 4))
        payload.extend(struct.pack("<HBB", 0, 0, 0x14))

        events = parse_vif_command_events(bytes(payload))

        self.assertEqual(len(events), 3)
        self.assertEqual(events[0].unpack_destination, 0)
        self.assertTrue(events[0].unpack_add_tops)
        self.assertEqual(events[0].payload, bytes((20, 4, 60, 252)))
        self.assertEqual(events[1].unpack_destination, 0x34)
        self.assertTrue(events[1].unpack_add_tops)
        self.assertTrue(events[1].unpack_unsigned)
        self.assertEqual(events[1].decoded, (1, 2, 3, 4))
        self.assertEqual(events[2].command, 0x14)
        self.assertEqual(events[2].raw, struct.pack("<HBB", 0, 0, 0x14))

    def test_parse_vif_command_events_accepts_masked_unpack_range(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0xC034, 4, 0x7F))
        payload.extend(struct.pack("<HHHH", 1, 2, 3, 4))

        event = parse_vif_command_events(bytes(payload))[0]

        self.assertEqual(event.unpack_destination, 0x34)
        self.assertEqual(event.unpack_qword_address, 0x34)
        self.assertEqual(event.unpack_byte_address, 0x340)
        self.assertTrue(event.unpack_masked)
        self.assertEqual(event.unpack_format, "V4_5")
        self.assertEqual(event.decoded, (1, 2, 3, 4))

    def test_parse_vif_command_events_preserves_modelulator_unpack_address_bits(self):
        payload = struct.pack("<HBB", 0xC05C, 1, 0x6E) + bytes((1, 2, 3, 4))

        event = parse_vif_command_events(payload)[0]

        self.assertEqual(event.unpack_destination, 0x5C)
        self.assertEqual(event.unpack_qword_address, 0x1C)
        self.assertEqual(event.unpack_byte_address, 0x1C0)
        self.assertTrue(event.unpack_add_tops)
        self.assertTrue(event.unpack_unsigned)
        self.assertEqual(event.unpack_format, "V4_8")

    def test_parse_vif_command_events_skips_non_unpack_payloads(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0, 0, 0x30))
        payload.extend(struct.pack("<IIII", 1, 2, 3, 4))
        payload.extend(struct.pack("<HBB", 0, 0, 0x14))

        events = parse_vif_command_events(bytes(payload))

        self.assertEqual([event.command for event in events], [0x30, 0x14])
        self.assertEqual(events[0].payload, struct.pack("<IIII", 1, 2, 3, 4))
        self.assertEqual(events[0].decoded, (1, 2, 3, 4))

    def test_parse_vif_command_events_skips_mpg_payload(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x0010, 2, 0x4A))
        payload.extend(bytes(range(16)))
        payload.extend(struct.pack("<HBB", 0, 0, 0x00))

        events = parse_vif_command_events(bytes(payload))

        self.assertEqual([event.command for event in events], [0x4A, 0x00])
        self.assertEqual(events[0].payload, bytes(range(16)))


if __name__ == "__main__":
    unittest.main()
