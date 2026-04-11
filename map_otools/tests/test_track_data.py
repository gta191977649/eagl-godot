from __future__ import annotations

import os
import unittest
from pathlib import Path

from map_otools.parsers.drvpath import parse_drvpath
from map_otools.parsers.level_dat import parse_level_dat
from map_otools.render.layer_policy import LayerPolicy
from map_otools.render.scene_builder import SceneBuilder
from map_otools.route_resolver import RouteResolver
from map_otools.track_catalog import TrackCatalog


NFSHP2_ROOT = Path(os.environ.get("NFSHP2_ROOT", "/Users/nurupo/Desktop/nfshp2"))
TRACKS_ROOT = NFSHP2_ROOT / "tracks"


@unittest.skipUnless(TRACKS_ROOT.exists(), "NFSHP2 data not available")
class TrackDataTests(unittest.TestCase):
    def test_tracks_ini_loads_all_tracks(self) -> None:
        catalog = TrackCatalog(TRACKS_ROOT)
        self.assertEqual(len(catalog.tracks), 12)
        self.assertEqual([item.name_variant_index for item in catalog.name_tracks("Medit")], [1, 2, 3])

    def test_drvpath_parse(self) -> None:
        drvpath = parse_drvpath(TRACKS_ROOT / "Medit" / "level00" / "drvpath.ini")
        self.assertEqual(drvpath.compartment_ids, [5, 9, 10, 11, 12, 13, 14, 15, 16, 17, 6])

    def test_drvpath_parse_uses_numeric_node_order(self) -> None:
        drvpath = parse_drvpath(TRACKS_ROOT / "Parkland" / "level03" / "drvpath.ini")
        self.assertEqual(drvpath.compartment_ids, [1, 11, 10, 9, 8, 7, 6, 5, 30, 4, 3, 2])

    def test_level_dat_parse(self) -> None:
        level_dat = parse_level_dat(TRACKS_ROOT / "Medit" / "level00" / "level.dat")
        self.assertEqual(len(level_dat.placement_records), 206)
        self.assertEqual(len(level_dat.link_records), 24)
        self.assertEqual(len(level_dat.named_object_records), 21)
        self.assertEqual(len(level_dat.levelft_records), 24)
        self.assertEqual(len(level_dat.group_records), 1)
        self.assertEqual(len(level_dat.point_records), 411)
        self.assertIn("000142", [item.model_id for item in level_dat.levelft_records])

    def test_route_resolution(self) -> None:
        catalog = TrackCatalog(TRACKS_ROOT)
        resolver = RouteResolver(TRACKS_ROOT)
        route_context, _ = resolver.resolve(catalog.get_by_id(9))
        self.assertEqual(route_context.level_dir.name, "level00")
        self.assertEqual(route_context.level_index, 0)
        self.assertEqual(route_context.compartment_ids, [5, 9, 10, 11, 12, 13, 14, 15, 16, 17, 6])

    def test_route_resolution_by_level(self) -> None:
        resolver = RouteResolver(TRACKS_ROOT)
        route_context, _ = resolver.resolve_name_level("Medit", 3)
        self.assertEqual(route_context.level_dir.name, "level03")
        self.assertEqual(route_context.level_index, 3)
        self.assertEqual(route_context.compartment_ids, [5, 6, 17, 16, 15, 14, 13, 12, 11, 10, 9])
        self.assertIn("000206", route_context.levelft_ids)

    def test_route_resolution_rejects_missing_level(self) -> None:
        resolver = RouteResolver(TRACKS_ROOT)
        with self.assertRaisesRegex(ValueError, "available levels"):
            resolver.resolve_name_level("Medit", 99)


class LayerPolicyTests(unittest.TestCase):
    def test_faithful_prefers_normal_layers(self) -> None:
        policy = LayerPolicy()
        names = ["opaque", "opaqueLOD", "alpha1LOD", "alpha2", "alpha2LOD", "custom"]
        self.assertEqual(policy.select_indices(names, "faithful"), [0, 3, 5])

    def test_raw_keeps_all_layers(self) -> None:
        policy = LayerPolicy()
        names = ["opaque", "opaqueLOD", "alpha2", "alpha2LOD"]
        self.assertEqual(policy.select_indices(names, "raw"), [0, 1, 2, 3])


class MaterialExportTests(unittest.TestCase):
    def test_material_disables_specular_highlights(self) -> None:
        builder = SceneBuilder.__new__(SceneBuilder)
        state = {
            "materials": [],
            "samplers": [],
            "images": [],
            "textures": [],
            "bufferViews": [],
            "buffers": [],
        }

        material_index = builder._material_for(
            "RoadShader",
            None,
            {},
            state,
            {},
            {},
            {},
            [],
            Path("out.gltf"),
            False,
        )

        self.assertEqual(material_index, 0)
        self.assertEqual(state["extensionsUsed"], ["KHR_materials_specular"])
        self.assertEqual(state["materials"][0]["pbrMetallicRoughness"]["metallicFactor"], 0.0)
        self.assertEqual(state["materials"][0]["pbrMetallicRoughness"]["roughnessFactor"], 1.0)
        self.assertEqual(state["materials"][0]["extensions"]["KHR_materials_specular"]["specularFactor"], 0.0)
