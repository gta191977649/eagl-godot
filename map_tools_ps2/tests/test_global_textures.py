import json
from types import SimpleNamespace

from map_tools_ps2 import global_textures


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
