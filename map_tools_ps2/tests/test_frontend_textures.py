import json
from types import SimpleNamespace

from map_tools_ps2 import frontend_textures
from map_tools_ps2.textures import _flip_rgba_vertical


def test_flip_rgba_vertical_reorders_rows_without_mirroring_pixels():
    rgba = bytes(value for pixel in range(6) for value in (pixel, 0, 0, 255))
    flipped = _flip_rgba_vertical(rgba, 3, 2)
    assert [flipped[offset] for offset in range(0, len(flipped), 4)] == [3, 4, 5, 0, 1, 2]


def test_frontend_export_writes_source_scoped_pngs_and_manifest(tmp_path, monkeypatch):
    frontend = tmp_path / "FRONTEND"
    (frontend / "nested").mkdir(parents=True)
    (frontend / "FRONTB.BUN").write_bytes(b"bun")
    (frontend / "FRONTB.LZC").write_bytes(b"lzc")
    (frontend / "nested" / "TSELECT.BIN").write_bytes(b"bin")
    (frontend / "empty.BIN").write_bytes(b"")
    (frontend / "preview.DDS").write_bytes(b"dds")

    monkeypatch.setattr(frontend_textures, "load_bundle_bytes", lambda path: path.read_bytes())

    def fake_read(data, source, **_kwargs):
        if data == b"bin":
            return (SimpleNamespace(name="DUPLICATE", tex_hash=0x22, width=8, height=4, png=b"bin-png"),)
        return (
            SimpleNamespace(name="DUPLICATE", tex_hash=0x11, width=16, height=8, png=b"bun-png"),
            SimpleNamespace(name="DUPLICATE", tex_hash=0x11, width=16, height=8, png=b"bun-png-2"),
        )

    monkeypatch.setattr(frontend_textures, "read_ps2_tpk_bytes", fake_read)
    output = tmp_path / "out"
    manifest = frontend_textures.export_frontend_textures(frontend, output)

    assert manifest["summary"] == {"resources": 3, "written": 2, "textures": 3, "skipped": 1}
    assert (output / "FRONTB" / "DUPLICATE_00000011.png").read_bytes() == b"bun-png"
    assert (output / "FRONTB" / "DUPLICATE_00000011_2.png").read_bytes() == b"bun-png-2"
    assert (output / "nested_TSELECT" / "DUPLICATE_00000022.png").read_bytes() == b"bin-png"
    assert not (output / "FRONTB_LZC").exists()

    saved = json.loads((output / "frontend_manifest.json").read_text(encoding="utf-8"))
    assert saved["resources"][0]["source"] == "empty.BIN"
    assert saved["resources"][0]["reason"] == "empty file"
    assert saved["unprocessed_files"] == [{"source": "preview.DDS", "reason": "unsupported extension"}]


def test_frontend_export_continues_after_invalid_resource(tmp_path, monkeypatch):
    frontend = tmp_path / "FRONTEND"
    frontend.mkdir()
    (frontend / "bad.BIN").write_bytes(b"bad")
    (frontend / "good.BIN").write_bytes(b"good")

    monkeypatch.setattr(frontend_textures, "load_bundle_bytes", lambda path: path.read_bytes())
    monkeypatch.setattr(
        frontend_textures,
        "read_ps2_tpk_bytes",
        lambda data, _source, **_kwargs: (_ for _ in ()).throw(ValueError("invalid chunk"))
        if data == b"bad"
        else (SimpleNamespace(name="OK", tex_hash=1, width=1, height=1, png=b"png"),),
    )

    manifest = frontend_textures.export_frontend_textures(frontend, tmp_path / "out")
    records = {record["source"]: record for record in manifest["resources"]}
    assert records["bad.BIN"]["status"] == "skipped"
    assert "invalid chunk" in records["bad.BIN"]["reason"]
    assert records["good.BIN"]["status"] == "written"


def test_frontend_export_creates_missing_input_and_output_directories(tmp_path):
    frontend = tmp_path / "missing" / "FRONTEND"
    output = tmp_path / "missing" / "out"
    manifest = frontend_textures.export_frontend_textures(frontend, output)

    assert frontend.is_dir()
    assert output.is_dir()
    assert manifest["summary"] == {"resources": 0, "written": 0, "textures": 0, "skipped": 0}
    assert (output / "frontend_manifest.json").is_file()
