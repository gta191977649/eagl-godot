#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from map_tools_ps2.binary import f32le, u32le
from map_tools_ps2.chunks import Chunk, parse_chunks, walk_chunks
from map_tools_ps2.comp import load_bundle_bytes
from map_tools_ps2.glb_writer import (
    _indices_for_block,
    _quad_batch_indices,
    _strip_indices_for_vertices,
    _strip_restart_boundaries,
    _topology_score,
    _triangle_list_indices,
)
from map_tools_ps2.model import _find_ascii_name, _read_texture_hashes, parse_mesh_object, parse_scene, transformed_vertices
from map_tools_ps2.textures import TextureLibrary, load_texture_library_for_track
from map_tools_ps2.vif import _unpack_data_size


@dataclass(frozen=True)
class VifRunDump:
    start: int
    end: int
    header: tuple[int, int, int, int] | None
    vertex_count: int
    uv_count: int
    c034_count: int
    pos_commands: tuple[str, ...]
    uv_commands: tuple[str, ...]
    c034_values: tuple[int, ...]


def main() -> int:
    parser = argparse.ArgumentParser(description="Dump PS2 HP2 BUN object/model metadata")
    parser.add_argument("input", nargs="+", help="TRACKB##.LZC or TRACKB##.BUN")
    parser.add_argument("--object", dest="object_filter", help="substring filter for object detail dumps")
    parser.add_argument("--limit", type=int, default=12, help="max detailed objects per input")
    parser.add_argument("--texture-dir", help="directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN")
    args = parser.parse_args()

    for source in map(Path, args.input):
        analyze_source(source, Path(args.texture_dir) if args.texture_dir else None, args.object_filter, args.limit)
    return 0


def analyze_source(source: Path, texture_dir: Path | None, object_filter: str | None, limit: int) -> None:
    data = load_bundle_bytes(source)
    chunks = parse_chunks(data)
    texture_library = load_texture_library_for_track(source, texture_dir)
    scene = parse_scene(chunks, data)
    object_chunks = [chunk for chunk in walk_chunks(chunks) if chunk.chunk_id == 0x80034002]

    print(f"# {source.name}")
    print(f"bundle_bytes={len(data)} object_chunks={len(object_chunks)} decoded_objects={len(scene.objects)}")
    print_chunk_summary(chunks)
    print_object_summary(data, object_chunks, texture_library)

    detailed = 0
    for object_chunk in object_chunks:
        info = object_info(data, object_chunk, texture_library)
        if info is None:
            continue
        name = info["name"]
        if object_filter and object_filter.lower() not in name.lower():
            continue
        if not object_filter and detailed >= limit:
            continue
        print_object_detail(info)
        detailed += 1


def print_chunk_summary(chunks: tuple[Chunk, ...]) -> None:
    counts = Counter(chunk.chunk_id for chunk in walk_chunks(chunks))
    print("chunk_counts_top:")
    for chunk_id, count in counts.most_common(16):
        print(f"  0x{chunk_id:08x}: {count}")


def print_object_summary(data: bytes, object_chunks: list[Chunk], texture_library: TextureLibrary) -> None:
    child_shapes: Counter[tuple[int, ...]] = Counter()
    metadata_sizes: Counter[int] = Counter()
    texture_ref_counts: Counter[int] = Counter()
    matched_records = 0
    total_records = 0
    texture_indices: Counter[int] = Counter()
    packed_byte2: Counter[int] = Counter()
    unknown04: Counter[int] = Counter()
    qword_mismatches = 0
    offset_mismatches = 0
    texture_name_counts: Counter[str] = Counter()

    for object_chunk in object_chunks:
        info = object_info(data, object_chunk, texture_library)
        if info is None:
            continue
        child_shapes[tuple(chunk.chunk_id for chunk in object_chunk.children)] += 1
        metadata = info["metadata"]
        records = metadata["records"]
        metadata_sizes[metadata["payload_size"]] += 1
        texture_ref_counts[len(info["texture_hashes"])] += 1
        matched_records += sum(1 for record in records if record["offset_matches"])
        total_records += len(records)
        qword_mismatches += sum(1 for record in records if not record["qword_matches"])
        offset_mismatches += sum(1 for record in records if not record["offset_matches"])
        for record in records:
            texture_indices[record["texture_index"]] += 1
            packed_byte2[record["packed"][2]] += 1
            unknown04[record["unknown04"]] += 1
            texture_name_counts[record["texture_name"]] += 1

    print("object_child_shapes:")
    for shape, count in child_shapes.most_common(8):
        print("  " + " ".join(f"0x{chunk_id:08x}" for chunk_id in shape) + f": {count}")
    print("metadata_payload_sizes:", dict(metadata_sizes.most_common(12)))
    print("texture_ref_counts:", dict(texture_ref_counts.most_common(12)))
    print(f"metadata_records={total_records} offset_matches={matched_records} offset_mismatches={offset_mismatches}")
    print(f"qword_mismatches={qword_mismatches}")
    print("unknown04_top:", {f"0x{k:08x}": v for k, v in unknown04.most_common(8)})
    print("packed_byte2_top:", dict(packed_byte2.most_common(16)))
    print("texture_index_top:", dict(texture_indices.most_common(16)))
    print("texture_name_top:", dict(texture_name_counts.most_common(24)))


def object_info(data: bytes, object_chunk: Chunk, texture_library: TextureLibrary) -> dict | None:
    children = list(object_chunk.children)
    header = next((chunk for chunk in children if chunk.chunk_id == 0x00034003), None)
    metadata = next((chunk for chunk in children if chunk.chunk_id == 0x00034004), None)
    vif = next((chunk for chunk in children if chunk.chunk_id == 0x00034005), None)
    texture_refs = next((chunk for chunk in children if chunk.chunk_id == 0x00034006), None)
    extra_hash = next((chunk for chunk in children if chunk.chunk_id == 0x0003401D), None)
    if header is None or vif is None:
        return None

    name_info = _find_ascii_name(header.payload(data))
    if name_info is None:
        return None

    mesh_object = parse_mesh_object(object_chunk, data)
    texture_hashes = _read_texture_hashes(texture_refs.payload(data)) if texture_refs else ()
    texture_names = tuple(texture_library.get(tex_hash).name if texture_library.get(tex_hash) else f"0x{tex_hash:08x}" for tex_hash in texture_hashes)
    vif_payload = strip_prefix(vif.payload(data))
    vif_runs = parse_vif_runs(vif_payload)
    metadata_info = parse_metadata(
        metadata.payload(data) if metadata else b"",
        texture_hashes,
        texture_names,
        vif_runs,
        len(vif_payload),
    )
    extra_payload = extra_hash.payload(data) if extra_hash else b""

    return {
        "name": name_info[0],
        "name_start": name_info[1],
        "chunk_offset": object_chunk.offset,
        "header_size": header.size,
        "mesh_object": mesh_object,
        "metadata": metadata_info,
        "vif_size": vif.size,
        "texture_hashes": texture_hashes,
        "texture_names": texture_names,
        "extra_hash_words": tuple(u32le(extra_payload, offset) for offset in range(0, len(extra_payload) - 3, 4)),
        "vif_runs": vif_runs,
    }


def parse_metadata(
    payload: bytes,
    texture_hashes: tuple[int, ...],
    texture_names: tuple[str, ...],
    vif_runs: tuple[VifRunDump, ...],
    vif_size: int,
) -> dict:
    prefixed = payload[:8] == b"\x11" * 8
    records_payload = strip_prefix(payload)
    records = []
    record_count = len(records_payload) // 64
    for index in range(record_count):
        offset = index * 64
        record = records_payload[offset : offset + 64]
        words = tuple(u32le(record, word * 4) for word in range(16))
        packed = tuple(record[0x1C : 0x20])
        texture_index = words[0]
        texture_name = texture_names[texture_index] if texture_index < len(texture_names) else f"<bad:{texture_index}>"
        run = vif_runs[index] if index < len(vif_runs) else None
        next_offset = vif_runs[index + 1].start if index + 1 < len(vif_runs) else vif_size
        qwords = words[3] & 0xFFFF
        qword_size = qwords * 16
        expected_qword_size = (next_offset - run.start) if run else None
        records.append(
            {
                "index": index,
                "texture_index": texture_index,
                "texture_name": texture_name,
                "unknown04": words[1],
                "vif_offset": words[2],
                "qwords": qwords,
                "qword_flags": words[3] >> 16,
                "packed": packed,
                "bounds_min": tuple(f32le(record, 0x10 + axis * 4) for axis in range(3)),
                "bounds_max": tuple(f32le(record, 0x20 + axis * 4) for axis in range(3)),
                "words": words,
                "offset_matches": bool(run and words[2] == run.start),
                "qword_matches": bool(run and expected_qword_size == qword_size),
                "expected_qword_size": expected_qword_size,
                "run": run,
            }
        )
    return {"prefixed": prefixed, "payload_size": len(payload), "record_count": record_count, "records": tuple(records)}

def parse_vif_runs(payload: bytes) -> tuple[VifRunDump, ...]:
    runs: list[VifRunDump] = []
    current_start: int | None = None
    current_header: tuple[int, int, int, int] | None = None
    vertex_count = 0
    uv_count = 0
    c034_values: list[int] = []
    pos_commands: list[str] = []
    uv_commands: list[str] = []
    pos = 0

    def flush(end: int) -> None:
        nonlocal current_start, current_header, vertex_count, uv_count, c034_values, pos_commands, uv_commands
        if current_start is None:
            return
        runs.append(
            VifRunDump(
                start=current_start,
                end=end,
                header=current_header,
                vertex_count=vertex_count,
                uv_count=uv_count,
                c034_count=len(c034_values),
                pos_commands=tuple(pos_commands),
                uv_commands=tuple(uv_commands),
                c034_values=tuple(c034_values),
            )
        )
        current_start = None
        current_header = None
        vertex_count = 0
        uv_count = 0
        c034_values = []
        pos_commands = []
        uv_commands = []

    while pos + 4 <= len(payload):
        command_offset = pos
        imm, count, command = struct.unpack_from("<HBB", payload, pos)
        pos += 4
        size = _unpack_data_size(command, count)
        if size is None:
            if command == 0x14:
                flush(pos)
            elif command != 0x00:
                flush(command_offset)
            continue
        if pos + size > len(payload):
            break

        if command == 0x6E and imm == 0x8000 and count == 1:
            flush(command_offset)
            current_start = command_offset
            current_header = tuple(payload[pos : pos + 4])  # type: ignore[assignment]
            vertex_count = current_header[0] if current_header else 0
        elif current_start is not None and 0xC002 <= imm < 0xC020 and command in (0x60, 0x64, 0x68, 0x6C):
            width = unpack_width(command)
            pos_commands.append(f"{imm:04x}:{count:02x}:{command:02x}")
            if current_header is None or not current_header[0]:
                vertex_count += count * width // 3
        elif current_start is not None and 0xC020 <= imm < 0xC034 and command in (0x60, 0x64, 0x68, 0x6C):
            width = unpack_width(command)
            uv_commands.append(f"{imm:04x}:{count:02x}:{command:02x}")
            uv_count += count * width // 2
        elif current_start is not None and 0xC034 <= imm < 0xC040 and command == 0x6F:
            c034_values.extend(struct.unpack_from("<" + "H" * count, payload, pos))

        pos += size

    flush(pos)
    return tuple(runs)


def unpack_width(command: int) -> int:
    if command in (0x60, 0x61, 0x62):
        return 1
    if command in (0x64, 0x65, 0x66):
        return 2
    if command in (0x68, 0x69, 0x6A):
        return 3
    return 4


def print_object_detail(info: dict) -> None:
    print(f"\n## object 0x{info['chunk_offset']:08x} {info['name']}")
    print(f"header_size=0x{info['header_size']:x} name_start=0x{info['name_start']:x} vif_size=0x{info['vif_size']:x}")
    print("textures:")
    for index, (tex_hash, name) in enumerate(zip(info["texture_hashes"], info["texture_names"])):
        print(f"  {index:02d} 0x{tex_hash:08x} {name}")
    if info["extra_hash_words"]:
        print("0x3401d:", " ".join(f"0x{word:08x}" for word in info["extra_hash_words"]))
    metadata = info["metadata"]
    mesh_object = info["mesh_object"]
    print(f"metadata_prefixed={metadata['prefixed']} metadata_size=0x{metadata['payload_size']:x} records={metadata['record_count']} vif_runs={len(info['vif_runs'])}")
    for record in metadata["records"][:24]:
        run = record["run"]
        run_desc = ""
        if run:
            run_desc = (
                f" run=[0x{run.start:05x},0x{run.end:05x}) hdr={run.header} "
                f"v={run.vertex_count} uv={run.uv_count} c034={run.c034_count}"
            )
        topo_desc = ""
        if mesh_object is not None and record["index"] < len(mesh_object.vertex_runs):
            topo_desc = " " + _topology_debug_for_run(mesh_object, record["index"])
        print(
            f"  rec {record['index']:03d} tex={record['texture_index']:02d}:{record['texture_name']} "
            f"off=0x{record['vif_offset']:05x} qwc={record['qwords']:03d} flags=0x{record['qword_flags']:04x} packed={record['packed']} "
            f"off_ok={record['offset_matches']} qwc_ok={record['qword_matches']} "
            f"tail=({record['words'][12]:08x},{record['words'][13]:08x},{record['words'][14]:08x}){run_desc}{topo_desc}"
        )


def strip_prefix(payload: bytes) -> bytes:
    if len(payload) >= 8 and payload[:8] == b"\x11" * 8:
        return payload[8:]
    return payload


def _topology_debug_for_run(mesh_object, run_index: int) -> str:
    block = mesh_object.blocks[run_index]
    run = block.run
    vertices = transformed_vertices(mesh_object, run)
    unknown_count = mesh_object.run_unknown_counts[run_index] if run_index < len(mesh_object.run_unknown_counts) else None

    strip_indices = _strip_indices_for_vertices(vertices, mesh_object.name)
    candidates: list[tuple[str, list[int], tuple[int, float, int]]] = [
        ("strip", strip_indices, _topology_score(vertices, strip_indices)),
    ]

    if len(vertices) % 3 == 0:
        tri_indices = _triangle_list_indices(len(vertices))
        candidates.append(("tri", tri_indices, _topology_score(vertices, tri_indices)))
    if len(vertices) % 4 == 0:
        quad_indices = _quad_batch_indices(len(vertices))
        candidates.append(("quad", quad_indices, _topology_score(vertices, quad_indices)))

    chosen_indices = _indices_for_block(vertices, mesh_object.name, block)
    chosen_name = next((name for name, indices, _score in candidates if indices == chosen_indices), "mixed")
    candidate_text = ",".join(f"{name}:{score[0]}/{score[2]}@{score[1]:.2f}" for name, _indices, score in candidates)
    restart_boundaries = ",".join(str(boundary) for boundary in sorted(_strip_restart_boundaries(vertices))[:8])
    restart_suffix = f" restarts=[{restart_boundaries}]" if restart_boundaries else ""
    return f"topo={chosen_name} cand={candidate_text}{restart_suffix}"


if __name__ == "__main__":
    raise SystemExit(main())
