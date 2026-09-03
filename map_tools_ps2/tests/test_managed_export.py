from dataclasses import replace
from types import SimpleNamespace

from map_tools_ps2.managed_export import geometry_key, texture_key
from map_tools_ps2.mta_scene import MtaMaterial, MtaModel
from map_tools_ps2.race_catalog import load_profiles, TRACK_IDS


def model():
    return MtaModel("track31_prop", "prop", "prop", "zone31", (0, 0, 0),
        vertices=[(0,0,0), (1,0,0), (0,1,0)], faces=[(0,1,2)],
        uvs=[(0,0),(1,0),(0,1)], colors=[(255,128,64,255)]*3,
        materials=[MtaMaterial(1,"shared")], face_materials=[0])


def test_geometry_identity_preserves_prelight_and_ignores_placement_names():
    original = model()
    assert geometry_key(original) == geometry_key(replace(original, model_id="track34_prop", zone="other", origin=(20,30,40)))
    assert geometry_key(original) != geometry_key(replace(original, colors=[(128,64,32,255)]*3))


def test_collision_can_be_shared_independently_of_visual_geometry():
    original = model()
    assert geometry_key(original) == geometry_key(replace(original, collision_kind="mesh", collision_vertices=[(9,9,9)]))
    assert geometry_key(original) != geometry_key(replace(original, uvs=[(0,0)]*3))


def test_texture_identity_keeps_surface_alpha_and_animation_semantics():
    texture = SimpleNamespace(png=b"identical decoded pixels", width=32, height=32)
    key = texture_key(texture,"OPAQUE",None,None)
    assert key == texture_key(texture,"OPAQUE",None,None)
    assert key != texture_key(texture,"MASK",0.5,None)
    assert key != texture_key(texture,"OPAQUE",None,"road")
    assert texture_key(texture,"BLEND",None,None,[0,4,["a","b"]]) != texture_key(texture,"BLEND",None,None,[1,4,["a","b"]])


def test_catalog_includes_all_thirty_and_explicit_sprint_endpoints():
    profiles = load_profiles()
    assert set(profiles) == set(TRACK_IDS)
    assert sum(not p["closed"] for p in profiles.values()) == 10
    for profile in profiles.values():
        assert profile["type"] == ("circuit" if profile["closed"] else "sprint")
        assert profile["mainLoop"] and profile["trafficPaths"]
        assert profile["edgeEvidence"]


def test_native_carriers_preserve_surface_area_and_col_coordinate_range():
    from map_tools_ps2.managed_collision import add_carrier_faces
    points = [(900,1200,10),(1900,1200,10),(900,2200,10)]
    models = []
    add_carrier_faces(models,points,[(0,1,2)],27)
    area = 0
    for model in models:
        assert all(abs(v) <= 250 for p in model.collision_vertices for v in p)
        assert all(v == 27 for v in model.collision_materials)
        assert all(c[3] == 0 for c in model.colors)
        for f in model.collision_faces:
            a,b,c = [model.collision_vertices[i] for i in f]
            area += ((b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])) / 2
    assert area == 500000
