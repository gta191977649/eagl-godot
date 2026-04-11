from __future__ import annotations

import base64
import json
import struct
from pathlib import Path
from typing import List


class GlTFWriter:
    def write(self, state: dict, raw_chunks: List[bytes], out_path: Path, binary: bool) -> None:
        if binary:
            self._write_glb(state, raw_chunks, out_path)
        else:
            self._write_gltf(state, raw_chunks, out_path)

    def _write_gltf(self, state: dict, raw_chunks: List[bytes], out_path: Path) -> None:
        for i, blob in enumerate(raw_chunks):
            state["buffers"][i]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(blob).decode("ascii")
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(state, indent=2), encoding="utf-8")

    def _write_glb(self, state: dict, raw_chunks: List[bytes], out_path: Path) -> None:
        merged = bytearray()
        new_buffer_views = []
        for i, blob in enumerate(raw_chunks):
            start = len(merged)
            merged.extend(blob)
            while len(merged) % 4 != 0:
                merged.append(0)
            old_view = state["bufferViews"][i]
            new_view = dict(old_view)
            new_view["buffer"] = 0
            new_view["byteOffset"] = start
            new_buffer_views.append(new_view)

        state["bufferViews"] = new_buffer_views
        state["buffers"] = [{"byteLength": len(merged)}]

        json_bytes = json.dumps(state, separators=(",", ":")).encode("utf-8")
        while len(json_bytes) % 4 != 0:
            json_bytes += b" "

        bin_bytes = bytes(merged)
        while len(bin_bytes) % 4 != 0:
            bin_bytes += b"\x00"

        total_length = 12 + 8 + len(json_bytes) + 8 + len(bin_bytes)
        header = struct.pack("<4sII", b"glTF", 2, total_length)
        json_chunk = struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
        bin_chunk = struct.pack("<I4s", len(bin_bytes), b"BIN\x00") + bin_bytes

        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(header + json_chunk + bin_chunk)
