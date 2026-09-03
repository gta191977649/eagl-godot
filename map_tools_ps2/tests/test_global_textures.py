import json
import struct
from pathlib import Path
from types import SimpleNamespace

from map_tools_ps2 import global_textures, textures
from map_tools_ps2.textures import TextureAnimation, read_ps2_texture_animations


def test_global_export_writes_pngs_and_prefers_bun(tmp_path, monkeypatch):
    global_dir = tmp_path / "GLOBAL"
    global_dir.mkdir()
    (global_dir / "COMMON.BUN").write_bytes(b"bun")
    (global_dir / "COMMON.LZC").write_bytes(b"lzc")
    (global_dir / "empty.BIN").write_bytes(b"")

    monkeypatch.setattr(global_textures, "load_bundle_bytes", lambda path: path.read_bytes())
    monkeypatch.setattr(
        global_textures,
        "read_ps2_tpk_bytes",
        lambda data, _source, **_kwargs: (SimpleNamespace(name="ICON", tex_hash=0x42, width=8, height=8, png=data + b"-png"),),
    )

    output = tmp_path / "out"
    manifest = global_textures.export_global_textures(global_dir, output)

    assert manifest["summary"] == {"resources": 2, "written": 1, "textures": 1, "skipped": 1}
    assert (output / "COMMON" / "ICON_00000042.png").read_bytes() == b"bun-png"
    saved = json.loads((output / "global_manifest.json").read_text(encoding="utf-8"))
    assert saved["resources"][0]["source"] == "COMMON.BUN"


def test_global_export_creates_missing_input_and_output_directories(tmp_path):
    global_dir = tmp_path / "missing" / "GLOBAL"
    output = tmp_path / "missing" / "out"

    manifest = global_textures.export_global_textures(global_dir, output)

    assert global_dir.is_dir()
    assert output.is_dir()
    assert manifest["summary"] == {"resources": 0, "written": 0, "textures": 0, "skipped": 0}
    assert (output / "global_manifest.json").is_file()


def test_reads_hp2_texture_animation_table():
    def chunk(chunk_id, payload):
        return struct.pack("<II", chunk_id, len(payload)) + payload

    name = b"TRACK_BARRIER_NEON".ljust(0x18, b"\0")
    frame_hashes = (0x1861DE29, 0xB85212CA, 0xB85212CB, 0xB85212CC)
    metadata = name + struct.pack("<III", frame_hashes[0], 4, 4) + bytes(16)
    frames = b"".join(struct.pack("<I", value) + bytes(12) for value in frame_hashes)
    children = chunk(0x30300102, metadata) + chunk(0x30300103, frames)
    data = chunk(0xB0300100, children)

    animations = read_ps2_texture_animations(data, Path("INGAMEB.BUN"))

    assert len(animations) == 1
    assert animations[0].name == "TRACK_BARRIER_NEON"
    assert animations[0].base_hash == frame_hashes[0]
    assert animations[0].frame_hashes == frame_hashes
    assert animations[0].frames_per_second == 4.0


def test_track_texture_library_merges_ingameb_but_keeps_local_precedence(tmp_path, monkeypatch):
    tracks_dir = tmp_path / "ZZDATA" / "TRACKS"
    global_dir = tmp_path / "ZZDATA" / "GLOBAL"
    tracks_dir.mkdir(parents=True)
    global_dir.mkdir()
    track = tracks_dir / "TRACKB31.LZC"
    track.write_bytes(b"track")
    for suffix in ("LOCATION", "TRACK"):
        (tracks_dir / f"TEX31{suffix}.BIN").write_bytes(b"local")
    ingame = global_dir / "INGAMEB.BUN"
    ingame.write_bytes(b"global")

    local = SimpleNamespace(tex_hash=0x10, name="LOCAL")
    global_conflict = SimpleNamespace(tex_hash=0x10, name="GLOBAL_CONFLICT")
    global_only = SimpleNamespace(tex_hash=0x20, name="GLOBAL_ONLY")
    animation = TextureAnimation("ANIM", 0x20, (0x20,), 1.0, ingame)
    monkeypatch.setattr(textures, "read_ps2_tpk", lambda _path: (local,))
    monkeypatch.setattr(textures, "load_bundle_bytes", lambda _path: b"global")
    monkeypatch.setattr(textures, "read_ps2_tpk_bytes", lambda _data, _path: (global_conflict, global_only))
    monkeypatch.setattr(textures, "read_ps2_texture_animations", lambda _data, _path: (animation,))

    library = textures.load_texture_library_for_track(track, tracks_dir)

    assert library.get(0x10).name == "LOCAL"
    assert library.get(0x20).name == "GLOBAL_ONLY"
    assert library.animations == {0x20: animation}
    assert library.global_source == ingame
    assert library.source_paths[-1] == ingame
