import json
import shutil
import struct
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import map_tools_ps2.sound_extract as sound_extract
import pytest
from map_tools_ps2.sound_extract import _jbc_streams, _speech_stream_names, _vag_streams, _write_vag_wav, export_sound


def _fake_mp3_encoder(monkeypatch):
    def encode(wav, mp3):
        mp3.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(wav, mp3)

    monkeypatch.setattr(sound_extract, "_encode_wav_to_mp3", encode)
    monkeypatch.setattr(sound_extract, "_encode_wav_batch", lambda items: [encode(wav, mp3) for wav, mp3 in items])


def _mono_vag(sample_rate: int = 22050) -> bytes:
    header = bytearray(0x30)
    header[0:4] = b"VAGp"
    struct.pack_into(">I", header, 0x04, 2)
    struct.pack_into(">I", header, 0x0C, 16)
    struct.pack_into(">I", header, 0x10, sample_rate)
    frame = bytes((0x00, 0x01)) + bytes(14)
    return bytes(header) + frame


def _stereo_vagx(sample_rate: int = 44100) -> bytes:
    header = bytearray(0x30)
    header[0:4] = b"VAGp"
    struct.pack_into(">I", header, 0x04, 2)
    struct.pack_into(">I", header, 0x0C, 32)
    struct.pack_into(">I", header, 0x10, sample_rate)
    header[0x24:0x28] = b"VAGx"
    struct.pack_into(">I", header, 0x2C, 2)
    left = bytes((0x00, 0x01)) + bytes(14)
    right = bytes((0x00, 0x07)) + bytes(14)
    return bytes(header) + left + right


def _jbc_with_one_track() -> bytes:
    interleave = 0x8000
    payload = bytearray(interleave * 2 + 32)
    payload[len(payload) - 32 + 1] = 0x01
    payload[len(payload) - 16 + 1] = 0x07
    vag = bytearray(0x30)
    vag[0:4] = b"VAGp"
    struct.pack_into(">I", vag, 0x04, 2)
    struct.pack_into(">I", vag, 0x0C, len(payload))
    struct.pack_into(">I", vag, 0x10, 32000)
    vag[0x24:0x28] = b"VAGx"
    struct.pack_into(">I", vag, 0x2C, 2)

    stream_offset = 0x1000
    jbc = bytearray(stream_offset + len(vag) + len(payload))
    struct.pack_into("<I", jbc, 0x00, 0x10)
    struct.pack_into("<I", jbc, 0x04, 2)
    struct.pack_into("<I", jbc, 0x08, 32000)
    struct.pack_into("<I", jbc, 0x20, 1)
    jbc[0x24:0x2A] = b"InGame"
    struct.pack_into("<I", jbc, 0x60, stream_offset)
    jbc[0x6C:0x76] = b"Test Track"
    jbc[stream_offset : stream_offset + len(vag)] = vag
    jbc[stream_offset + len(vag) :] = payload
    return bytes(jbc)


def test_sound_export_decodes_embedded_vag_to_mp3(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    zzdata_dir = tmp_path / "ZZDATA"
    zzdata_dir.mkdir()
    (zzdata_dir / "speech.PCK").write_bytes(bytes(0x100) + _mono_vag())
    (zzdata_dir / "ENGINE.CTB").write_bytes(b"unsupported")

    output = tmp_path / "out"
    manifest = export_sound(zzdata_dir, output)

    assert manifest["summary"] == {
        "files_scanned": 2, "resources": 1, "streams": 1, "written": 1,
        "skipped": 0, "failed": 0, "duplicates": 0, "stale_mp3_removed": 0,
        "stale_cleanup_skipped": False,
    }
    mp3_path = output / "SPEECH" / "speech" / "0001_stream_0001.mp3"
    with wave.open(str(mp3_path), "rb") as reader:
        assert reader.getframerate() == 22050
        assert reader.getnchannels() == 1
        assert reader.getnframes() == 28
    saved = json.loads((output / "sound_manifest.json").read_text(encoding="utf-8"))
    assert saved["resources"][0]["streams"][0]["source_offset"] == 0x100
    assert saved["resources"][0]["streams"][0]["output_format"] == "MP3 (libmp3lame VBR q2)"


def test_hp2_vagx_preserves_native_rate_channels_and_detects_interleave(tmp_path):
    wav_path = tmp_path / "stereo.wav"

    sample_rate, channels, frames, interleave = _write_vag_wav(_stereo_vagx(), wav_path)

    assert (sample_rate, channels, frames, interleave) == (44100, 2, 28, 16)
    with wave.open(str(wav_path), "rb") as reader:
        assert reader.getframerate() == 44100
        assert reader.getnchannels() == 2
        assert reader.getsampwidth() == 2
        assert reader.getnframes() == 28


def test_jbc_uses_index_table_native_rate_and_fixed_0x8000_interleave(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    sound_dir = tmp_path / "ZZDATA" / "SOUND"
    sound_dir.mkdir(parents=True)
    (sound_dir / "JUKEBOXM.JBC").write_bytes(_jbc_with_one_track())

    output = tmp_path / "out"
    manifest = export_sound(sound_dir.parent, output)

    stream = manifest["resources"][0]["streams"][0]
    assert stream["sample_rate"] == 32000
    assert stream["channels"] == 2
    assert stream["interleave_bytes"] == 0x8000
    assert stream["sample_frames"] == ((0x8000 + 16) // 16) * 28
    assert stream["file"] == str(Path("MUSIC") / "SOUND_JUKEBOXM" / "0001_Test_Track.mp3")


def test_sound_export_creates_missing_directories(tmp_path):
    sound_dir = tmp_path / "missing" / "ZZDATA"
    output = tmp_path / "missing" / "out"

    manifest = export_sound(sound_dir, output)

    assert sound_dir.is_dir()
    assert output.is_dir()
    assert manifest["summary"] == {
        "files_scanned": 0, "resources": 0, "streams": 0, "written": 0,
        "skipped": 0, "failed": 0, "duplicates": 0, "stale_mp3_removed": 0,
        "stale_cleanup_skipped": False,
    }
    assert (output / "sound_manifest.json").is_file()


def _raw_header(names: list[str], sample_rate: int = 22050) -> bytes:
    size = 12 + len(names) * 0x34
    data = bytearray(size)
    struct.pack_into("<III", data, 0, size, 0, len(names))
    for index, name in enumerate(names):
        offset = 12 + index * 0x34
        data[offset:offset + len(name)] = name.encode("ascii")
        struct.pack_into("<H", data, offset + 0x22, sample_rate)
    return bytes(data)


def test_raw_sfx_bank_combines_adjacent_same_name_channels(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    unknown = tmp_path / "ZZDATA" / "__Unknown"
    unknown.mkdir(parents=True)
    (unknown / "00000010").write_bytes(_raw_header(["MenuStart", "MenuStart"]))
    frame = bytes((0, 1)) + bytes(14)
    (unknown / "0000000A").write_bytes(frame * 2)

    manifest = export_sound(unknown.parent, tmp_path / "out")

    bank = next(resource for resource in manifest["resources"] if resource["type"] == "raw_sfx_bank")
    assert len(bank["streams"]) == 1
    assert bank["streams"][0]["channels"] == 2
    assert bank["streams"][0]["sample_rate"] == 22050
    assert (tmp_path / "out" / bank["streams"][0]["file"]).is_file()


def test_engine_msb_uses_matching_unknown_index(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    zzdata = tmp_path / "ZZDATA"
    unknown = zzdata / "__Unknown"
    sound = zzdata / "SOUND"
    unknown.mkdir(parents=True)
    sound.mkdir()
    names = ["TstCEHi", "TstCEid", "TstCEMd"] + [f"TstSample{i}" for i in range(10)]
    (unknown / "38AAE9FF").write_bytes(_raw_header(names))
    (sound / "NEWETESTAROSA.MSB").write_bytes((bytes((0, 3)) + bytes(14)) * 13)

    manifest = export_sound(zzdata, tmp_path / "out")

    bank = next(resource for resource in manifest["resources"] if resource["type"] == "engine_msb_bank")
    assert bank["status"] == "written"
    assert len(bank["streams"]) == 13
    assert all(stream["sample_rate"] == 22050 for stream in bank["streams"])


def test_combined_sfx_name_is_read_before_entry_descriptor(tmp_path):
    source = tmp_path / "E2F0CC8A"
    source.write_bytes(b"prefix" + struct.pack("<I", 12) + b"MenuStart\0\0\0" + bytes(8) + _mono_vag())

    streams = _vag_streams(source)

    assert streams[0]["name"] == "MenuStart"


def test_extensionless_jbc_still_uses_track_index_names(tmp_path):
    source = tmp_path / "AD921759"
    source.write_bytes(_jbc_with_one_track())

    streams = _jbc_streams(source)

    assert streams[0]["name"] == "Test_Track"


def test_speech_ban_index_assigns_event_and_take_names(tmp_path):
    dat = tmp_path / "ENGLISHDAT.PCK"
    dat.write_bytes(b"")
    ban = bytearray(32)
    struct.pack_into("<I", ban, 0, 2)
    struct.pack_into("<I", ban, 12, 0x100)
    struct.pack_into("<I", ban, 28, 0x500)
    dat.with_name("ENGLISHBAN.PCK").write_bytes(ban)
    streams = [{"offset": 0x100}, {"offset": 0x200}, {"offset": 0x500}]

    assert _speech_stream_names(dat, streams) == [
        "event_0001_take_001", "event_0001_take_002", "event_0002_take_001",
    ]


def _named_vag_entry(name: str) -> bytes:
    encoded = name.encode("ascii")
    padded_size = (len(encoded) + 3) & ~3
    return struct.pack("<I", padded_size) + encoded.ljust(padded_size, b"\0") + bytes(8) + _mono_vag()


def test_embedded_sfx_content_duplicates_are_written_once(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    unknown = tmp_path / "ZZDATA" / "__Unknown"
    unknown.mkdir(parents=True)
    (unknown / "E2F0CC8A").write_bytes(_named_vag_entry("AliasOne") + _named_vag_entry("AliasTwo"))

    manifest = export_sound(unknown.parent, tmp_path / "out", workers=1)

    resource = next(item for item in manifest["resources"] if item["source"].endswith("E2F0CC8A"))
    assert [item["status"] for item in resource["streams"]] == ["written", "duplicate"]
    assert resource["streams"][0]["aliases"] == ["AliasTwo"]
    assert manifest["summary"]["duplicates"] == 1
    assert len(list((tmp_path / "out" / "SFX_EMBEDDED").rglob("*.mp3"))) == 1


def test_named_jbc_is_preferred_over_extensionless_music_copy(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    zzdata = tmp_path / "ZZDATA"
    sound = zzdata / "SOUND"
    unknown = zzdata / "__Unknown"
    sound.mkdir(parents=True)
    unknown.mkdir()
    (sound / "JUKEBOXM.JBC").write_bytes(_jbc_with_one_track())
    (unknown / "AD921759").write_bytes(_jbc_with_one_track())

    manifest = export_sound(zzdata, tmp_path / "out", workers=1)

    duplicate = next(item for item in manifest["resources"] if item["type"] == "duplicate_music_container")
    assert duplicate["duplicate_of"] == str(Path("SOUND") / "JUKEBOXM.JBC")
    assert manifest["summary"]["duplicates"] == 1
    assert len(list((tmp_path / "out" / "MUSIC").rglob("*.mp3"))) == 1


def test_multiple_embedded_resources_use_parallel_worker_dispatch(tmp_path, monkeypatch):
    _fake_mp3_encoder(monkeypatch)
    monkeypatch.setattr(sound_extract, "ProcessPoolExecutor", ThreadPoolExecutor)
    zzdata = tmp_path / "ZZDATA"
    zzdata.mkdir()
    (zzdata / "one.PCK").write_bytes(_mono_vag())
    (zzdata / "two.PCK").write_bytes(_mono_vag(32000))

    manifest = export_sound(zzdata, tmp_path / "out", workers=2)

    assert manifest["worker_processes"] == 2
    assert manifest["summary"]["written"] == 2


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="FFmpeg is required for process integration")
def test_real_process_pool_exports_multiple_resources(tmp_path):
    zzdata = tmp_path / "ZZDATA"
    zzdata.mkdir()
    (zzdata / "one.PCK").write_bytes(_mono_vag())
    (zzdata / "two.PCK").write_bytes(_mono_vag(32000))

    manifest = export_sound(zzdata, tmp_path / "out", workers=2)

    assert manifest["worker_processes"] == 2
    assert manifest["summary"]["written"] == 2
    assert len(list((tmp_path / "out" / "SPEECH").rglob("*.mp3"))) == 2
