import json
from types import SimpleNamespace

from map_tools_ps2 import cli
from map_tools_ps2.textures import TextureLibrary


def test_export_skybox_writes_referenced_pngs_and_manifest(tmp_path, monkeypatch):
    source = tmp_path / "TRACKB31.BUN"
    source.write_bytes(b"placeholder")
    sky = SimpleNamespace(name="SKYDOME_MAIN", texture_hashes=(0x10, 0x20))
    skybox = SimpleNamespace(name="SKYBOX_FALLBACK", texture_hashes=(0x30,))
    texture = SimpleNamespace(name="SKYBLUE", png=b"png", width=64, height=32)
    scene = SimpleNamespace(objects=(sky, skybox))
    monkeypatch.setattr(cli, "load_bundle_bytes", lambda _path: b"data")
    monkeypatch.setattr(cli, "parse_chunks", lambda _data: ())
    monkeypatch.setattr(cli, "parse_scene", lambda _chunks, _data: scene)
    monkeypatch.setattr(cli, "load_texture_library_for_track", lambda _path, _dir: TextureLibrary({0x10: texture}))

    output = tmp_path / "skybox"
    args = SimpleNamespace(input=str(source), game_dir=None, track=None, texture_dir=None, output=str(output))
    assert cli._cmd_export_skybox(args) == 0

    assert (output / "textures" / "SKYBLUE_00000010.png").read_bytes() == b"png"
    manifest = json.loads((output / "skybox_manifest.json").read_text(encoding="utf-8"))
    assert manifest["track"] == 31
    assert manifest["objects"] == ["SKYDOME_MAIN", "SKYBOX_FALLBACK"]
    assert [item["status"] for item in manifest["textures"]] == ["written", "missing", "missing"]
