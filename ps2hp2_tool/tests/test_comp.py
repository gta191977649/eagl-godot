from pathlib import Path
import unittest

from map_tools_ps2.binary import Vec3
from map_tools_ps2.cli import _resolve_track_input
from map_tools_ps2.comp import decompress_lzc
from map_tools_ps2.glb_writer import (
    _indices_for_block,
    _indices_for_run,
    _ps2_to_gltf_vec3,
    _should_export_vif_colors,
    _should_prioritize_target_count,
    _should_replace_topology,
    _should_skip_object,
    _strip_indices,
    _strip_indices_for_vertices,
    _topology_score,
    _texture_hash_for_run,
)
from map_tools_ps2.model import DecodedBlock, _extract_blocks_from_strip_entries, _read_run_texture_indices, _read_run_unknown_counts
from map_tools_ps2.textures import _alpha_mode_for_rgba, _decode_ps2_alpha, decode_indexed_texture, read_ps2_tpk
from map_tools_ps2.vif import VifVertexRun, extract_vif_vertex_runs
import struct


TRACKS_ROOT = Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS")


class CompTests(unittest.TestCase):
    def test_ea_comp_matches_known_decompressed_bundle(self):
        compressed = TRACKS_ROOT / "TRACKB24.LZC"
        decompressed = TRACKS_ROOT / "TRACKB24.BUN"
        if not compressed.exists() or not decompressed.exists():
            self.skipTest("TRACKB24 fixture is not available")
        self.assertEqual(decompress_lzc(compressed.read_bytes()), decompressed.read_bytes())


class CliTests(unittest.TestCase):
    def test_resolve_track_input_prefers_bun_in_game_dir(self):
        args = type(
            "Args",
            (),
            {
                "input": None,
                "game_dir": "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile",
                "track": 44,
            },
        )()
        self.assertEqual(
            _resolve_track_input(args),
            Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB44.BUN"),
        )

    def test_export_parser_defaults_vertex_colors_to_auto(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile", "--track", "44"]
        )
        self.assertEqual(args.vertex_colors, "auto")

    def test_export_parser_accepts_vertex_colors_override(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile", "--track", "44", "--vertex-colors", "always"]
        )
        self.assertEqual(args.vertex_colors, "always")


class TextureTests(unittest.TestCase):
    def test_ps2_full_alpha_maps_to_opaque(self):
        self.assertEqual(_decode_ps2_alpha(0), 0)
        self.assertEqual(_decode_ps2_alpha(0x40), 0x80)
        self.assertEqual(_decode_ps2_alpha(0x7F), 0xFF)

    def test_alpha_mode_ignores_near_opaque_alpha(self):
        self.assertIsNone(_alpha_mode_for_rgba(bytes([1, 2, 3, 250, 4, 5, 6, 255])))

    def test_alpha_mode_distinguishes_mask_from_blend(self):
        self.assertEqual(_alpha_mode_for_rgba(bytes([1, 2, 3, 0, 4, 5, 6, 255])), "MASK")
        self.assertEqual(_alpha_mode_for_rgba(bytes([1, 2, 3, 128, 4, 5, 6, 255])), "BLEND")

    def test_subpage_4bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(16))
        rgba = decode_indexed_texture(4, 4, bytes([0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE]), palette)
        self.assertEqual([rgba[offset] for offset in range(0, 16 * 4, 4)], list(range(16)))

    def test_subpage_8bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(256))
        image = bytes(range(64)) + bytes(64 * 64 - 64)
        rgba = decode_indexed_texture(64, 64, image, palette)
        self.assertEqual(
            [rgba[offset] for offset in range(0, 16 * 4, 4)],
            [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23],
        )

    def test_subpage_32color_8bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(32))
        rgba = decode_indexed_texture(4, 4, bytes(range(16)), palette)
        self.assertEqual([rgba[offset] for offset in range(0, 16 * 4, 4)], list(range(16)))

    def test_fixture_billboard_textures_decode_from_0x80_palette_entries(self):
        location_bin = TRACKS_ROOT / "TEX24LOCATION.BIN"
        if not location_bin.exists():
            self.skipTest("TEX24LOCATION.BIN fixture is not available")

        names = {texture.name for texture in read_ps2_tpk(location_bin)}
        self.assertIn("BILLBOARD-REAR", names)
        self.assertIn("BILLBOARD_04", names)


class GlbMaterialTests(unittest.TestCase):
    def test_texture_hash_uses_run_metadata_when_present(self):
        texture_hashes = (0x10, 0x20, 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (2, 0), 0), 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (2, 0), 1), 0x10)

    def test_texture_hash_falls_back_to_clamped_run_order_without_metadata(self):
        texture_hashes = (0x10, 0x20, 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (), 0), 0x10)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (), 5), 0x30)

    def test_strip_indices_exports_full_decoded_strip(self):
        self.assertEqual(_strip_indices(0, 5), [0, 1, 2, 1, 3, 2, 2, 3, 4])

    def test_strip_indices_drop_zero_area_restart_triangles(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 2.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices),
            [0, 1, 2, 3, 5, 4],
        )

    def test_strip_indices_keep_regular_ladder_strip(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6, 5, 7, 6],
        )

    def test_topology_score_does_not_flag_regular_ladder_strip_as_corrupt(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _topology_score(vertices, _strip_indices_for_vertices(vertices)),
            (0, 1.0, 6),
        )

    def test_track_sections_drop_far_two_vertex_tail_when_strip_restart_is_cleaner(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_strip_indices_for_vertices(vertices, "RD_SECTION80_CHOP5"), [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4])

    def test_prop_tail_restart_split_keeps_short_tail_props_separate(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_strip_indices_for_vertices(vertices, "XB_WELLL_A1_00"), [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4])

    def test_strip_indices_split_repeated_anchor_pairs_when_segmented_strip_is_cleaner(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(100.0, 0.0, 0.0),
            Vec3(100.0, 1.0, 0.0),
            Vec3(101.0, 0.0, 0.0),
            Vec3(101.0, 1.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices, "TRN_SECTION80_CHOP2"),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 8, 9, 10, 9, 11, 10],
        )

    def test_indices_for_run_switches_to_triangle_list_when_metadata_matches_and_strip_spikes(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(11.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_indices_for_run(vertices, "TEST_OBJECT", 2), [0, 1, 2, 3, 4, 5])

    def test_indices_for_run_uses_explicit_triangle_list_when_metadata_matches(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
        )
        self.assertEqual(_indices_for_run(vertices, "XB_SAMPLE", 2), [0, 1, 2, 3, 4, 5])

    def test_indices_for_run_switches_to_quad_batches_when_metadata_matches_and_strip_spikes(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(11.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
            Vec3(11.0, 1.0, 0.0),
        )
        self.assertEqual(_indices_for_run(vertices, "TEST_OBJECT", 4), [0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6])

    def test_indices_for_run_uses_explicit_quad_batches_when_metadata_matches(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "XB_SAMPLE", 4),
            [0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6],
        )

    def test_indices_for_run_keeps_regular_strip_when_alternate_layout_is_not_better(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "TEST_OBJECT", 4),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6, 5, 7, 6],
        )

    def test_indices_for_run_prefers_exact_segmented_strip_for_track_sections(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "RD_SECTION80_CHOP5", 4),
            [0, 1, 2, 3, 4, 5, 4, 6, 5, 5, 6, 7],
        )

    def test_indices_for_run_allows_short_restart_padding_inside_exact_track_strip(self):
        vertices = (
            Vec3(921.3474731445312, 1755.8338623046875, 320.3931579589844),
            Vec3(922.7384033203125, 1754.625732421875, 318.7872619628906),
            Vec3(920.2958374023438, 1751.8114013671875, 318.7872314453125),
            Vec3(920.2958374023438, 1751.8114013671875, 318.7872314453125),
            Vec3(918.9049682617188, 1753.0191650390625, 320.3931579589844),
            Vec3(921.3474731445312, 1755.8338623046875, 320.3931579589844),
            Vec3(918.1378784179688, 1760.0091552734375, 321.600341796875),
            Vec3(918.16796875, 1759.9832763671875, 328.3869934082031),
            Vec3(919.951416015625, 1758.434326171875, 322.1894836425781),
            Vec3(919.9813842773438, 1758.4080810546875, 328.97613525390625),
            Vec3(921.764892578125, 1756.859375, 321.5624084472656),
            Vec3(921.7950439453125, 1756.8331298828125, 328.34906005859375),
            Vec3(910.7485961914062, 1756.277587890625, 291.2479553222656),
            Vec3(915.084228515625, 1761.2735595703125, 291.2479553222656),
            Vec3(912.6417236328125, 1758.458984375, 313.944091796875),
            Vec3(915.084228515625, 1761.2735595703125, 313.944091796875),
            Vec3(912.9859008789062, 1758.1597900390625, 316.5558776855469),
            Vec3(915.4284057617188, 1760.9744873046875, 316.5558776855469),
            Vec3(913.8870849609375, 1757.3773193359375, 318.83062744140625),
            Vec3(916.3296508789062, 1760.19189453125, 318.83062744140625),
            Vec3(915.2780151367188, 1756.1693115234375, 320.43109130859375),
            Vec3(917.7205200195312, 1758.9840087890625, 320.43109130859375),
            Vec3(908.3317260742188, 1744.2841796875, 293.76885986328125),
            Vec3(909.9971923828125, 1746.396240234375, 293.76885986328125),
            Vec3(908.3317260742188, 1744.2841796875, 321.5653076171875),
            Vec3(909.9971923828125, 1746.396240234375, 321.5653076171875),
            Vec3(908.3317260742188, 1744.2841796875, 293.76885986328125),
            Vec3(908.3317260742188, 1744.2841796875, 321.5653076171875),
            Vec3(905.1217651367188, 1746.685302734375, 326.34820556640625),
        )
        self.assertEqual(
            _indices_for_run(vertices, "TRN_SECTION40_WALLS_PRO", 17),
            [
                0, 1, 2,
                3, 5, 4,
                4, 5, 6,
                5, 7, 6,
                6, 7, 8,
                7, 9, 8,
                8, 9, 10,
                9, 11, 10,
                12, 13, 14,
                13, 15, 14,
                14, 15, 16,
                15, 17, 16,
                16, 17, 18,
                17, 19, 18,
                18, 19, 20,
                19, 21, 20,
                24, 25, 26,
            ],
        )

    def test_ps2_to_gltf_vec3_rotates_z_up_world_to_y_up(self):
        self.assertEqual(_ps2_to_gltf_vec3(Vec3(1.0, 2.0, 3.0)), Vec3(1.0, 3.0, -2.0))

    def test_indices_for_block_uses_metadata_subtype_hybrid_pass(self):
        vertices = (
            Vec3(-41.856, 1859.195, 277.876),
            Vec3(-43.198, 1860.374, 279.533),
            Vec3(-44.315, 1858.974, 277.876),
            Vec3(-44.020, 1861.310, 279.533),
            Vec3(-45.475, 1860.247, 277.876),
            Vec3(-44.058, 1862.728, 279.533),
            Vec3(-45.285, 1862.879, 277.876),
            Vec3(-43.472, 1864.008, 279.533),
            Vec3(-44.434, 1864.903, 277.876),
            Vec3(-42.334, 1864.723, 279.533),
            Vec3(-42.654, 1866.011, 277.876),
            Vec3(-40.909, 1864.670, 279.533),
            Vec3(-40.318, 1865.910, 277.876),
            Vec3(-39.844, 1863.825, 279.533),
            Vec3(-38.560, 1864.565, 277.876),
            Vec3(-39.660, 1862.463, 279.533),
            Vec3(-38.297, 1862.337, 277.876),
            Vec3(-40.397, 1861.125, 279.533),
            Vec3(-39.410, 1860.227, 277.876),
            Vec3(-41.903, 1860.573, 279.533),
            Vec3(-41.856, 1859.195, 277.876),
            Vec3(-43.198, 1860.374, 279.533),
            Vec3(-0.258, 1838.290, 285.113),
            Vec3(-8.055, 1827.850, 284.700),
            Vec3(-1.128, 1819.325, 287.802),
            Vec3(-15.853, 1817.410, 284.287),
            Vec3(-28.698, 1806.706, 283.754),
            Vec3(-19.559, 1802.941, 286.954),
        )
        block = DecodedBlock(
            run=VifVertexRun(vertices, (), (), (28, 6, 84, 252)),
            primitive_mode="strip",
            expected_face_count=22,
            topology_code=0x05,
        )
        self.assertEqual(len(_indices_for_block(vertices, "TRN_SECTION80_CHOP2", block)) // 3, 22)

    def test_target_count_priority_includes_track_sections(self):
        self.assertTrue(_should_prioritize_target_count("TRN_SECTION40_WALLS_PRO"))
        self.assertTrue(_should_prioritize_target_count("RD_SECTION70_CHOP4"))
        self.assertFalse(_should_prioritize_target_count("TEST_OBJECT"))

    def test_should_export_vif_colors_honors_mode_override(self):
        self.assertTrue(_should_export_vif_colors("TEST_OBJECT", None, "always"))
        self.assertFalse(_should_export_vif_colors("RD_SECTION70_CHOP4", 0x4041, "off"))

    def test_should_replace_topology_prefers_exact_prop_count_when_candidate_has_no_bad_faces(self):
        self.assertTrue(
            _should_replace_topology(
                (0, 3.0, 20),
                (0, 1.2, 15),
                20,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_rejects_exact_prop_count_when_distortion_is_too_high(self):
        self.assertFalse(
            _should_replace_topology(
                (0, 3.7, 20),
                (0, 1.2, 15),
                20,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_allows_exact_prop_count_when_metadata_gap_is_large(self):
        self.assertTrue(
            _should_replace_topology(
                (4, 13.1, 22),
                (0, 1.0, 16),
                22,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_prefers_lower_distortion_when_face_counts_tie(self):
        self.assertTrue(
            _should_replace_topology(
                (0, 1.2, 14),
                (0, 1.8, 14),
                14,
                prefer_target_count=True,
            )
        )

    def test_skip_object_filters_background_meshes(self):
        self.assertTrue(_should_skip_object("SKYDOME"))
        self.assertTrue(_should_skip_object("SKYDOME_ENVMAP"))
        self.assertTrue(_should_skip_object("BACKGROUND"))
        self.assertFalse(_should_skip_object("RD_SECTION80_CHOP5"))


class ModelRunMetadataTests(unittest.TestCase):
    def test_run_texture_indices_accept_no_prefix_table(self):
        payload = (0).to_bytes(4, "little") + bytes(60) + (2).to_bytes(4, "little") + bytes(60)
        self.assertEqual(_read_run_texture_indices(payload, 2), (0, 2))

    def test_run_texture_indices_accept_prefixed_table(self):
        payload = b"\x11" * 8 + (1).to_bytes(4, "little") + bytes(60)
        self.assertEqual(_read_run_texture_indices(payload, 1), (1,))

    def test_run_unknown_counts_read_packed_count_like_byte(self):
        record = bytearray(64)
        record[0x1C:0x20] = (0xFF121E03).to_bytes(4, "little")
        self.assertEqual(_read_run_unknown_counts(bytes(record), 1), (0x12,))

    def test_strip_entry_records_can_segment_vif_payload_into_runs(self):
        def build_run(base: float) -> bytes:
            payload = bytearray()
            payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
            payload.extend(bytes((4, 0, 0, 0)))
            payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6C))
            payload.extend(
                struct.pack(
                    "<12f",
                    base + 0.0,
                    base + 1.0,
                    base + 2.0,
                    base + 3.0,
                    base + 10.0,
                    base + 11.0,
                    base + 12.0,
                    base + 13.0,
                    base + 20.0,
                    base + 21.0,
                    base + 22.0,
                    base + 23.0,
                )
            )
            payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))
            return bytes(payload)

        run0 = build_run(0.0)
        run1 = build_run(100.0)
        vif_payload = run0 + run1

        record0 = bytearray(64)
        record0[0x08:0x0C] = (0).to_bytes(4, "little")
        record0[0x0C:0x10] = (len(run0) // 16).to_bytes(4, "little")

        record1 = bytearray(64)
        record1[0x08:0x0C] = len(run0).to_bytes(4, "little")
        record1[0x0C:0x10] = (len(run1) // 16).to_bytes(4, "little")

        blocks = _extract_blocks_from_strip_entries(vif_payload, bytes(record0 + record1), "XB_SAMPLE")
        self.assertEqual(len(blocks), 2)
        self.assertEqual(blocks[0].run.vertices[0], Vec3(0.0, 10.0, 20.0))
        self.assertEqual(blocks[1].run.vertices[0], Vec3(100.0, 110.0, 120.0))
        self.assertEqual(blocks[0].primitive_mode, "strip")


class VifDecodeTests(unittest.TestCase):
    def test_v4_16_position_rows_decode_to_scaled_vertices(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 0, 0)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6D))
        payload.extend(
            struct.pack(
                "<12h",
                4096,
                8192,
                12288,
                16384,
                2048,
                4096,
                6144,
                8192,
                -4096,
                -8192,
                -12288,
                -16384,
            )
        )
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].vertices,
            (
                Vec3(1.0, 0.5, -1.0),
                Vec3(2.0, 1.0, -2.0),
                Vec3(3.0, 1.5, -3.0),
                Vec3(4.0, 2.0, -4.0),
            ),
        )

    def test_v4_8_position_rows_decode_to_scaled_vertices(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 0, 0)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6E))
        payload.extend(struct.pack("<12b", 64, 32, 0, -32, 0, 32, 64, 96, -64, -32, 0, 32))
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].vertices,
            (
                Vec3(0.5, 0.0, -0.5),
                Vec3(0.25, 0.25, -0.25),
                Vec3(0.0, 0.5, 0.0),
                Vec3(-0.25, 0.75, 0.25),
            ),
        )

    def test_v4_32_uv_rows_swap_the_second_pair(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 12, 252)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6C))
        payload.extend(
            struct.pack(
                "<12f",
                0.0,
                1.0,
                2.0,
                3.0,
                10.0,
                11.0,
                12.0,
                13.0,
                20.0,
                21.0,
                22.0,
                23.0,
            )
        )

        payload.extend(struct.pack("<HBB", 0xC020, 2, 0x6C))
        payload.extend(struct.pack("<8f", 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0))
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].texcoords,
            ((0.0, 1.0), (0.0, 0.0), (1.0, 1.0), (1.0, 0.0)),
        )
