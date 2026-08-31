"""Extract HP2 PS2 music, speech, SFX, and engine banks as MP3 files."""

from __future__ import annotations

import json
import hashlib
import mmap
import os
import re
import shutil
import struct
import subprocess
import tempfile
import wave
from array import array
from bisect import bisect_right
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, wait
from pathlib import Path

from .progress import report_progress

VAG_MAGIC = b"VAGp"
VAG_HEADER_SIZE = 0x30
HP2_JBC_INTERLEAVE = 0x8000
RAW_BANK_RECORD_SIZE = 0x34
PSX_END_FLAGS = {0x01, 0x03, 0x07}
PSX_COEFFICIENTS = ((0, 0), (60, 0), (115, -52), (98, -55), (122, -60))


def _safe_name(value: str, fallback: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip(" ._") or fallback


def _jbc_streams(path: Path) -> list[dict[str, object]]:
    with path.open("rb") as handle:
        header = handle.read(0x60)
        if len(header) < 0x60:
            return []
        count = struct.unpack_from("<I", header, 0x20)[0]
        rate = struct.unpack_from("<I", header, 0x08)[0]
        if header[0x24:0x2A] != b"InGame" or not 4000 <= rate <= 192000 or not 1 <= count <= 1024:
            return []
        handle.seek(0)
        header = handle.read(0x60 + count * 0x60)
    if len(header) < 0x60 + count * 0x60:
        return []
    streams: list[dict[str, object]] = []
    file_size = path.stat().st_size
    for index in range(count):
        record = 0x60 + index * 0x60
        offset = struct.unpack_from("<I", header, record)[0]
        name = header[record + 0x0C : record + 0x60].split(b"\0", 1)[0].decode("cp1252", "replace")
        with path.open("rb") as handle:
            handle.seek(offset)
            vag = handle.read(VAG_HEADER_SIZE)
        if len(vag) < VAG_HEADER_SIZE or vag[:4] != VAG_MAGIC or vag[0x24:0x28] != b"VAGx":
            raise ValueError(f"JBC track {index + 1} is not an HP2 VAGx stream")
        data_size = struct.unpack_from(">I", vag, 0x0C)[0]
        sample_rate = struct.unpack_from(">I", vag, 0x10)[0]
        channels = struct.unpack_from(">I", vag, 0x2C)[0]
        if sample_rate != rate:
            raise ValueError(f"JBC track {index + 1} rate {sample_rate} does not match global rate {rate}")
        if offset + VAG_HEADER_SIZE + data_size > file_size:
            raise ValueError(f"JBC track {index + 1} is truncated")
        streams.append({
            "offset": offset, "stream_size": VAG_HEADER_SIZE + data_size,
            "sample_rate": sample_rate, "channels": channels,
            "name": _safe_name(name, f"track_{index + 1:03d}"),
            "interleave": HP2_JBC_INTERLEAVE, "jbc_sample_rate": rate,
        })
    return streams


def _embedded_name(data: mmap.mmap, offset: int, index: int) -> str:
    # HP2's combined SFX bank stores an 8-byte entry descriptor between the
    # padded event name and VAGp. The preceding uint32 gives the padded name
    # block size, which avoids mistaking printable ADPCM bytes for a name.
    descriptor_offset = offset - 8
    for length_offset in range(max(0, descriptor_offset - 68), descriptor_offset - 3):
        padded_size = struct.unpack_from("<I", data, length_offset)[0]
        if not 4 <= padded_size <= 64 or length_offset + 4 + padded_size != descriptor_offset:
            continue
        raw_name = bytes(data[length_offset + 4 : descriptor_offset]).split(b"\0", 1)[0]
        if raw_name and all(0x20 <= value <= 0x7E for value in raw_name):
            return _safe_name(raw_name.decode("ascii"), f"stream_{index:04d}")
    return f"stream_{index:04d}"


def _vag_streams(path: Path) -> list[dict[str, object]]:
    if path.stat().st_size < VAG_HEADER_SIZE:
        return []
    streams: list[dict[str, object]] = []
    with path.open("rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        offset = data.find(VAG_MAGIC)
        while offset >= 0:
            if offset + VAG_HEADER_SIZE <= len(data):
                version = struct.unpack_from(">I", data, offset + 4)[0]
                data_size = struct.unpack_from(">I", data, offset + 0x0C)[0]
                rate = struct.unpack_from(">I", data, offset + 0x10)[0]
                size = VAG_HEADER_SIZE + data_size
                channels = struct.unpack_from(">I", data, offset + 0x2C)[0] if data[offset + 0x24:offset + 0x28] == b"VAGx" else 1
                if version in {2, 3, 32} and 4000 <= rate <= 192000 and 1 <= channels <= 8 and data_size >= 16 and data_size % 16 == 0 and offset + size <= len(data):
                    streams.append({
                        "offset": offset, "stream_size": size, "sample_rate": rate,
                        "channels": channels, "name": _embedded_name(data, offset, len(streams) + 1),
                    })
                    offset = data.find(VAG_MAGIC, offset + size)
                    continue
            offset = data.find(VAG_MAGIC, offset + 4)
    return streams


def _decode_frame(frame: bytes, history_1: int, history_2: int) -> tuple[array, int, int]:
    predictor, shift = frame[0] >> 4, frame[0] & 0x0F
    if predictor >= len(PSX_COEFFICIENTS) or shift > 12:
        raise ValueError(f"invalid PS2 ADPCM frame predictor={predictor} shift={shift}")
    coefficient_1, coefficient_2 = PSX_COEFFICIENTS[predictor]
    samples = array("h")
    for packed in frame[2:16]:
        for nibble in (packed & 0x0F, packed >> 4):
            nibble = nibble - 16 if nibble >= 8 else nibble
            sample = (nibble << 12) >> shift
            sample += (history_1 * coefficient_1 + history_2 * coefficient_2 + 32) >> 6
            sample = max(-32768, min(32767, sample))
            samples.append(sample)
            history_2, history_1 = history_1, sample
    return samples, history_1, history_2


def _detect_interleave(vag: bytes, data_size: int, channels: int) -> int:
    if channels <= 1:
        return data_size
    end = min(len(vag), VAG_HEADER_SIZE + data_size)
    for flags in ({0x01}, {0x01, 0x07}):
        markers = [offset for offset in range(end - 16, VAG_HEADER_SIZE - 1, -16) if vag[offset + 1] in flags][:channels]
        if len(markers) == channels:
            interleave = markers[0] - markers[1]
            if interleave > 0 and interleave % 16 == 0:
                return interleave
    raise ValueError("could not detect channel interleave")


def _write_channel_wav(channel_data: list[bytes], sample_rate: int, output_path: Path) -> int:
    if not channel_data or not 4000 <= sample_rate <= 192000:
        raise ValueError(f"invalid raw bank sample rate: {sample_rate}")
    decoded: list[array] = []
    for payload in channel_data:
        if not payload or len(payload) % 16:
            raise ValueError("raw PS2 ADPCM stream is not frame-aligned")
        history_1 = history_2 = 0
        samples = array("h")
        for offset in range(0, len(payload), 16):
            values, history_1, history_2 = _decode_frame(payload[offset:offset + 16], history_1, history_2)
            samples.extend(values)
        decoded.append(samples)
    frame_count = min(map(len, decoded))
    pcm = array("h", (decoded[channel][frame] for frame in range(frame_count) for channel in range(len(decoded))))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as writer:
        writer.setparams((len(decoded), 2, sample_rate, 0, "NONE", "not compressed"))
        writer.writeframes(pcm.tobytes())
    return frame_count


def _write_vag_wav(vag: bytes, output_path: Path, interleave_override: int | None = None) -> tuple[int, int, int, int]:
    if len(vag) < VAG_HEADER_SIZE or vag[:4] != VAG_MAGIC:
        raise ValueError("not a VAGp stream")
    version = struct.unpack_from(">I", vag, 4)[0]
    data_size = struct.unpack_from(">I", vag, 0x0C)[0]
    rate = struct.unpack_from(">I", vag, 0x10)[0]
    channels = struct.unpack_from(">I", vag, 0x2C)[0] if version == 2 and vag[0x24:0x28] == b"VAGx" else 1
    if not 4000 <= rate <= 192000 or not 1 <= channels <= 8:
        raise ValueError("invalid VAG audio parameters")
    payload = vag[VAG_HEADER_SIZE:VAG_HEADER_SIZE + data_size]
    if len(payload) != data_size:
        raise ValueError("truncated VAG audio data")
    interleave = int(interleave_override) if channels > 1 and interleave_override is not None else _detect_interleave(vag, data_size, channels)
    if interleave <= 0 or interleave % 16 or (channels > 1 and interleave > data_size // channels):
        raise ValueError(f"invalid channel interleave: 0x{interleave:x}")
    histories = [[0, 0] for _ in range(channels)]
    frames_written = 0
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output_path), "wb") as writer:
        writer.setparams((channels, 2, rate, 0, "NONE", "not compressed"))
        group_size = interleave * channels
        for group_offset in range(0, len(payload), group_size):
            remaining = len(payload) - group_offset
            block_size = interleave if remaining >= group_size else remaining // channels
            if block_size <= 0 or block_size % 16:
                raise ValueError("partial interleave block is not frame-aligned")
            decoded: list[array] = []
            for channel in range(channels):
                samples = array("h")
                start = group_offset + channel * block_size
                for offset in range(start, start + block_size, 16):
                    values, histories[channel][0], histories[channel][1] = _decode_frame(payload[offset:offset + 16], *histories[channel])
                    samples.extend(values)
                decoded.append(samples)
            count = min(map(len, decoded))
            writer.writeframes(array("h", (decoded[c][i] for i in range(count) for c in range(channels))).tobytes())
            frames_written += count
    return rate, channels, frames_written, interleave


def _encode_wav_to_mp3(wav_path: Path, mp3_path: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg was not found in PATH; install FFmpeg to export MP3 files")
    mp3_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.run(
        [ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", str(wav_path),
         "-map_metadata", "-1", "-codec:a", "libmp3lame", "-q:a", "2", str(mp3_path)],
        capture_output=True, text=True, check=False,
    )
    if process.returncode:
        mp3_path.unlink(missing_ok=True)
        raise RuntimeError(process.stderr.strip() or f"FFmpeg exited with code {process.returncode}")


def _encode_wav_batch(items: list[tuple[Path, Path]]) -> None:
    """Encode several files in one FFmpeg process to keep large speech banks practical."""
    if not items:
        return
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg was not found in PATH; install FFmpeg to export MP3 files")
    command = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error"]
    for wav_path, mp3_path in items:
        mp3_path.parent.mkdir(parents=True, exist_ok=True)
        command.extend(("-i", str(wav_path)))
    for index, (_, mp3_path) in enumerate(items):
        command.extend(("-map", f"{index}:a:0", "-map_metadata", "-1", "-codec:a", "libmp3lame", "-q:a", "2", str(mp3_path)))
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    if process.returncode:
        for _, mp3_path in items:
            mp3_path.unlink(missing_ok=True)
        raise RuntimeError(process.stderr.strip() or f"FFmpeg exited with code {process.returncode}")


class _Mp3BatchEncoder:
    def __init__(self, summary: dict[str, int], batch_size: int = 24) -> None:
        self.summary = summary
        self.batch_size = batch_size
        self.pending: list[tuple[Path, Path, dict[str, object]]] = []

    def add(self, wav_path: Path, mp3_path: Path, manifest_record: dict[str, object]) -> None:
        manifest_record["status"] = "encoding"
        self.pending.append((wav_path, mp3_path, manifest_record))
        if len(self.pending) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        if not self.pending:
            return
        pending, self.pending = self.pending, []
        try:
            _encode_wav_batch([(wav, mp3) for wav, mp3, _ in pending])
            for _, _, record in pending:
                record["status"] = "written"
                self.summary["written"] += 1
        except Exception:
            # A corrupt stream must not discard the rest of its batch.
            for wav, mp3, record in pending:
                try:
                    _encode_wav_to_mp3(wav, mp3)
                    record["status"] = "written"
                    self.summary["written"] += 1
                except Exception as exc:
                    record["status"] = "failed"
                    record["reason"] = f"{type(exc).__name__}: {exc}"
                    self.summary["failed"] += 1
        finally:
            for wav, _, _ in pending:
                wav.unlink(missing_ok=True)


def _raw_bank_header(path: Path) -> list[dict[str, object]] | None:
    if path.suffix or path.stat().st_size < 64:
        return None
    data = path.read_bytes()
    size, _, count = struct.unpack_from("<III", data, 0)
    if size != len(data) or not 1 <= count <= 4096 or 12 + count * RAW_BANK_RECORD_SIZE > len(data):
        return None
    records: list[dict[str, object]] = []
    for index in range(count):
        offset = 12 + index * RAW_BANK_RECORD_SIZE
        raw_name = data[offset:offset + 32].split(b"\0", 1)[0]
        rate = struct.unpack_from("<H", data, offset + 0x22)[0]
        if not raw_name or any(value < 0x20 or value > 0x7E for value in raw_name) or not 4000 <= rate <= 192000:
            return None
        records.append({"name": raw_name.decode("ascii"), "sample_rate": rate})
    return records


def _split_raw_bank(data: bytes, expected_count: int) -> list[bytes]:
    if not data or len(data) % 16:
        raise ValueError("raw PS2 ADPCM bank is not frame-aligned")
    streams, start = [], 0
    for offset in range(0, len(data), 16):
        if data[offset + 1] in PSX_END_FLAGS:
            streams.append(data[start:offset + 16])
            start = offset + 16
    if start < len(data) and any(data[start:]):
        raise ValueError("raw bank has unterminated trailing data")
    if len(streams) != expected_count:
        raise ValueError(f"raw bank has {len(streams)} streams, index expects {expected_count}")
    return streams


def _engine_header(msb_path: Path, headers: dict[Path, list[dict[str, object]]]) -> tuple[Path, list[dict[str, object]]] | None:
    code = msb_path.stem[4:].upper()
    wanted = {"TESTAROSA": "TST"}.get(code, code)
    matches = []
    for path, records in headers.items():
        if len(records) != 13:
            continue
        tag = re.split(r"C[EX]", str(records[0]["name"]), maxsplit=1, flags=re.IGNORECASE)[0].upper()
        score = 2 if tag == wanted else 1 if wanted.startswith(tag) or tag.startswith(wanted) else 0
        if score:
            matches.append((score, len(tag), path, records))
    if not matches:
        return None
    _, _, path, records = max(matches, key=lambda item: item[:2])
    return path, records


def _stream_groups(records: list[dict[str, object]], streams: list[bytes], stereo: bool) -> list[dict[str, object]]:
    groups, index = [], 0
    while index < len(records):
        record, channels = records[index], [streams[index]]
        if stereo and index + 1 < len(records) and records[index + 1] == record:
            channels.append(streams[index + 1])
            index += 1
        groups.append({**record, "channels": channels})
        index += 1
    return groups


def _manifest_stream(path: Path, rate: int, channels: int, frames: int, **extra: object) -> dict[str, object]:
    return {
        "sample_rate": rate, "channels": channels, "codec": "Sony PS-ADPCM",
        "output_format": "MP3 (libmp3lame VBR q2)", "sample_frames": frames,
        "duration_seconds": round(frames / rate, 6), "file": str(path), "status": "pending", **extra,
    }


def _contains_vag(path: Path) -> bool:
    if path.stat().st_size < VAG_HEADER_SIZE:
        return False
    with path.open("rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        return data.find(VAG_MAGIC) >= 0


def _speech_stream_names(source: Path, streams: list[dict[str, object]]) -> list[str] | None:
    """Create stable event/take names from the matching language BAN index."""
    upper_name = source.name.upper()
    if not upper_name.endswith("DAT.PCK"):
        return None
    ban = source.with_name(source.name[:-7] + "BAN.PCK")
    if not ban.is_file():
        return None
    data = ban.read_bytes()
    if len(data) < 16:
        return None
    count = struct.unpack_from("<I", data, 0)[0]
    if not 1 <= count <= 100_000 or count * 16 > len(data):
        return None
    event_starts = [(struct.unpack_from("<I", data, index * 16 + 12)[0], index + 1) for index in range(count)]
    if any(offset <= 0 for offset, _ in event_starts):
        return None
    event_starts.sort()
    offsets = [offset for offset, _ in event_starts]
    take_counts: dict[int, int] = {}
    names: list[str] = []
    for stream in streams:
        position = bisect_right(offsets, int(stream["offset"])) - 1
        if position < 0:
            names.append(str(stream.get("name", "")))
            continue
        event_index = event_starts[position][1]
        take_counts[event_index] = take_counts.get(event_index, 0) + 1
        names.append(f"event_{event_index:04d}_take_{take_counts[event_index]:03d}")
    return names


def _export_embedded_resource_task(arguments: tuple[str, str, str]) -> tuple[dict[str, object], dict[str, int]]:
    """Process one self-contained audio resource; safe to run in a child process."""
    source = Path(arguments[0])
    zzdata_dir = Path(arguments[1])
    output_dir = Path(arguments[2])
    relative_source = source.relative_to(zzdata_dir)
    stats = {"streams": 0, "written": 0, "skipped": 0, "failed": 0, "duplicates": 0}
    record: dict[str, object] = {"source": str(relative_source), "type": "embedded_vag", "status": "skipped", "streams": []}
    try:
        jbc_streams = _jbc_streams(source)
        streams = jbc_streams or _vag_streams(source)
        if not streams:
            record["reason"] = "no supported embedded VAG streams found"
            stats["skipped"] += 1
            return record, stats
        category = "MUSIC" if jbc_streams else "SPEECH" if source.suffix.upper() == ".PCK" else "SFX_EMBEDDED"
        base = Path(category) / _safe_name(str(relative_source.with_suffix("")), source.stem)
        indexed_names = _speech_stream_names(source, streams)
        output_streams: list[dict[str, object]] = []
        seen_audio: dict[bytes, dict[str, object]] = {}
        encoder = _Mp3BatchEncoder(stats)
        with tempfile.TemporaryDirectory(prefix="map_tools_ps2_resource_") as temp_name, source.open("rb") as handle:
            temp = Path(temp_name)
            for index, stream in enumerate(streams, 1):
                original_name = indexed_names[index - 1] if indexed_names else str(stream.get("name", ""))
                name = _safe_name(original_name, f"stream_{index:04d}")
                relative = base / f"{index:04d}_{name}.mp3"
                handle.seek(int(stream["offset"]))
                vag = handle.read(int(stream["stream_size"]))
                fingerprint = hashlib.sha256(vag).digest()
                canonical = seen_audio.get(fingerprint)
                if canonical is not None:
                    aliases = canonical.setdefault("aliases", [])
                    if name != canonical.get("name") and name not in aliases:
                        aliases.append(name)
                    output_streams.append({
                        "index": index, "name": name, "status": "duplicate",
                        "duplicate_of": canonical["file"], "source_offset": stream["offset"],
                    })
                    stats["duplicates"] += 1
                    continue
                wav = temp / f"stream_{index}.wav"
                try:
                    rate, channels, frames, interleave = _write_vag_wav(
                        vag, wav, int(stream["interleave"]) if stream.get("interleave") is not None else None,
                    )
                    item = _manifest_stream(
                        relative, rate, channels, frames, index=index, name=name,
                        source_offset=stream["offset"], source_size=stream["stream_size"],
                        content_sha256=hashlib.sha256(vag).hexdigest(),
                        container_variant="VAGx" if vag[0x24:0x28] == b"VAGx" else "VAGp",
                        interleave_bytes=interleave if channels > 1 else 0,
                        jbc_sample_rate=stream.get("jbc_sample_rate"),
                    )
                    output_streams.append(item)
                    seen_audio[fingerprint] = item
                    encoder.add(wav, output_dir / relative, item)
                except Exception as exc:
                    output_streams.append({"index": index, "name": name, "status": "failed", "reason": f"{type(exc).__name__}: {exc}"})
                    stats["failed"] += 1
                    wav.unlink(missing_ok=True)
            encoder.flush()
        stats["streams"] = len(output_streams)
        record["streams"] = output_streams
        record["status"] = "written" if any(item["status"] == "written" for item in output_streams) else "failed"
    except Exception as exc:
        record.update(status="failed", reason=f"{type(exc).__name__}: {exc}")
        stats["failed"] += 1
    return record, stats


def _stale_mp3_cleanup(output_dir: Path, resources: list[dict[str, object]]) -> int:
    managed = {"MUSIC", "SPEECH", "SFX_EMBEDDED", "SFX_RAW", "ENGINE"}
    keep = {
        Path(str(stream["file"]))
        for resource in resources
        for stream in resource.get("streams", [])
        if stream.get("status") == "written" and stream.get("file")
    }
    removed = 0
    for category in managed:
        root = output_dir / category
        if not root.is_dir():
            continue
        for path in root.rglob("*.mp3"):
            if path.relative_to(output_dir) not in keep:
                path.unlink()
                removed += 1
    return removed


def export_sound(zzdata_dir: Path, output_dir: Path, workers: int | None = None) -> dict[str, object]:
    zzdata_dir, output_dir = zzdata_dir.resolve(), output_dir.resolve()
    zzdata_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.exists() and not output_dir.is_dir():
        raise NotADirectoryError(f"Output path is not a directory: {output_dir}")
    if output_dir == zzdata_dir or zzdata_dir in output_dir.parents:
        raise ValueError("Output directory must be outside the ZZDATA input directory")
    output_dir.mkdir(parents=True, exist_ok=True)

    files = sorted((path for path in zzdata_dir.rglob("*") if path.is_file()), key=lambda path: str(path).lower())
    unknown = [path for path in files if path.parent.name == "__Unknown" and not path.suffix]
    headers = {path: records for path in unknown if (records := _raw_bank_header(path)) is not None}
    pairs, consumed = [], set()
    for header, index in headers.items():
        try:
            data = header.with_name(f"{int(header.name, 16) - 6:08X}")
        except ValueError:
            continue
        if data.is_file():
            pairs.append((header, data, index))
            consumed.update({header, data})
    msbs = [path for path in files if path.suffix.upper() == ".MSB"]
    embedded = [
        path for path in files
        if path.suffix.upper() == ".JBC"
        or path.suffix.upper() == ".PCK" and not path.name.upper().endswith("BAN.PCK")
        or path in unknown and path not in consumed and path not in headers and _contains_vag(path)
    ]
    total = len(embedded) + len(pairs) + len(msbs)
    resources: list[dict[str, object]] = []
    summary = {
        "files_scanned": len(files), "resources": total, "streams": 0,
        "written": 0, "skipped": 0, "failed": 0, "duplicates": 0,
    }
    encoder = _Mp3BatchEncoder(summary)
    report_progress("Scanning ZZDATA audio resources", 0, total, None)

    def complete(record: dict[str, object]) -> None:
        resources.append(record)
        report_progress("Extracting ZZDATA audio", len(resources), total, str(record["source"]))

    def encode_raw(groups: list[dict[str, object]], base: Path, temp: Path, prefix: str) -> list[dict[str, object]]:
        out = []
        for index, group in enumerate(groups, 1):
            name = _safe_name(str(group["name"]), f"stream_{index:04d}")
            relative = base / f"{index:04d}_{name}.mp3"
            wav = temp / f"{prefix}_{index}.wav"
            try:
                rate, channels = int(group["sample_rate"]), list(group["channels"])
                frames = _write_channel_wav(channels, rate, wav)
                item = _manifest_stream(relative, rate, len(channels), frames, index=index, name=name)
                out.append(item)
                encoder.add(wav, output_dir / relative, item)
            except Exception as exc:
                out.append({"index": index, "name": name, "status": "failed", "reason": f"{type(exc).__name__}: {exc}"})
                summary["failed"] += 1
                wav.unlink(missing_ok=True)
        summary["streams"] += len(out)
        return out

    with tempfile.TemporaryDirectory(prefix="map_tools_ps2_audio_") as temp_name:
        temp = Path(temp_name)
        # Prefer the named JUKEBOXM.JBC over the extensionless duplicate music
        # container. This avoids decoding and encoding the same 23 songs twice.
        canonical_jbc = next((path for path in embedded if path.suffix.upper() == ".JBC"), None)
        canonical_tracks = _jbc_streams(canonical_jbc) if canonical_jbc else []
        tasks: list[Path] = []
        for source in embedded:
            source_tracks = _jbc_streams(source)
            if (
                canonical_jbc is not None and source != canonical_jbc and source_tracks
                and [item["name"] for item in source_tracks] == [item["name"] for item in canonical_tracks]
            ):
                canonical_base = Path("MUSIC") / _safe_name(
                    str(canonical_jbc.relative_to(zzdata_dir).with_suffix("")), canonical_jbc.stem,
                )
                duplicate_streams = [
                    {
                        "index": index, "name": stream["name"], "status": "duplicate",
                        "duplicate_of": str(canonical_base / f"{index:04d}_{stream['name']}.mp3"),
                        "source_offset": stream["offset"],
                    }
                    for index, stream in enumerate(source_tracks, 1)
                ]
                summary["streams"] += len(duplicate_streams)
                summary["duplicates"] += len(duplicate_streams)
                complete({
                    "source": str(source.relative_to(zzdata_dir)), "type": "duplicate_music_container",
                    "status": "duplicate", "duplicate_of": str(canonical_jbc.relative_to(zzdata_dir)),
                    "streams": duplicate_streams,
                })
            else:
                tasks.append(source)

        requested_workers = int(workers or 0)
        auto_workers = min(6, max(1, (os.cpu_count() or 2) - 1))
        worker_count = min(len(tasks), requested_workers if requested_workers > 0 else auto_workers)
        worker_count = max(1, worker_count) if tasks else 0
        task_args = [(str(source), str(zzdata_dir), str(output_dir)) for source in tasks]
        if worker_count <= 1:
            results = [_export_embedded_resource_task(arguments) for arguments in task_args]
            for record, stats in results:
                for key in ("streams", "written", "skipped", "failed", "duplicates"):
                    summary[key] += stats[key]
                complete(record)
        else:
            report_progress("Starting parallel audio workers", 0, len(tasks), f"{worker_count} processes")
            with ProcessPoolExecutor(max_workers=worker_count) as pool:
                pending = {pool.submit(_export_embedded_resource_task, arguments) for arguments in task_args}
                completed = 0
                while pending:
                    done, pending = wait(pending, timeout=0.5, return_when=FIRST_COMPLETED)
                    if not done:
                        report_progress("Parallel audio workers", completed, len(tasks), f"{len(pending)} resources active")
                        continue
                    for future in done:
                        record, stats = future.result()
                        for key in ("streams", "written", "skipped", "failed", "duplicates"):
                            summary[key] += stats[key]
                        complete(record)
                        completed += 1
                    report_progress("Parallel audio workers", completed, len(tasks), f"{len(pending)} resources active")

        for header, data, index_records in pairs:
            record = {"source": str(data.relative_to(zzdata_dir)), "index_source": str(header.relative_to(zzdata_dir)), "type": "raw_sfx_bank", "status": "failed", "streams": []}
            try:
                streams = _split_raw_bank(data.read_bytes(), len(index_records))
                record["streams"] = encode_raw(_stream_groups(index_records, streams, True), Path("SFX_RAW") / header.name, temp, f"raw_{len(resources)}")
                record["status"] = "pending"
            except Exception as exc:
                record["reason"] = f"{type(exc).__name__}: {exc}"
                summary["failed"] += 1
            complete(record)

        for msb in msbs:
            record = {"source": str(msb.relative_to(zzdata_dir)), "type": "engine_msb_bank", "status": "failed", "streams": []}
            try:
                match = _engine_header(msb, headers)
                if match is None:
                    raise ValueError("matching 13-entry engine index was not found in __Unknown")
                header, index_records = match
                record["index_source"] = str(header.relative_to(zzdata_dir))
                streams = _split_raw_bank(msb.read_bytes(), len(index_records))
                record["streams"] = encode_raw(_stream_groups(index_records, streams, False), Path("ENGINE") / msb.stem, temp, f"engine_{len(resources)}")
                record["status"] = "pending"
            except Exception as exc:
                record["reason"] = f"{type(exc).__name__}: {exc}"
                summary["failed"] += 1
            complete(record)

        encoder.flush()

    for resource in resources:
        streams = resource.get("streams", [])
        if streams and resource.get("status") == "pending":
            resource["status"] = "written" if any(item.get("status") == "written" for item in streams) else "failed"

    # Only prune prior generated output after a completely successful run. A
    # failed conversion must not erase a previously usable export.
    summary["stale_mp3_removed"] = _stale_mp3_cleanup(output_dir, resources) if summary["failed"] == 0 else 0
    summary["stale_cleanup_skipped"] = summary["failed"] != 0

    manifest: dict[str, object] = {
        "zzdata_dir": str(zzdata_dir), "output_dir": str(output_dir),
        "output_format": "MP3 (libmp3lame VBR q2)", "worker_processes": worker_count,
        "resources": resources, "summary": summary,
    }
    manifest_path = output_dir / "sound_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(
        f"wrote {summary['written']} MP3 files from {summary['streams']} discovered streams "
        f"({summary['duplicates']} duplicates skipped) to {output_dir}"
    )
    print(f"wrote {manifest_path}")
    return manifest
