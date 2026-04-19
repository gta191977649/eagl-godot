from __future__ import annotations

from pathlib import Path

from .glb_writer import _indices_for_block
from .model import Scene, transformed_block_vertices
from .progress import progress_iter


def write_obj(scene: Scene, out_path: Path, progress: bool = False) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    vertex_index = 1
    with out_path.open("w", encoding="utf-8") as fh:
        fh.write("# Experimental NFS HP2 PS2 OBJ export\n")
        fh.write("# Topology is reconstructed from strip-entry metadata and VIF vertex runs.\n")
        for obj_index, obj in enumerate(
            progress_iter(scene.objects, total=len(scene.objects), desc="Exporting OBJ objects", enabled=progress)
        ):
            safe_name = obj.name.replace(" ", "_").replace("/", "_").replace("\\", "_")
            for block_index, block in enumerate(obj.blocks):
                vertices = transformed_block_vertices(obj, block)
                if len(vertices) < 3:
                    continue
                local_indices = _indices_for_block(vertices, obj.name, block)
                if not local_indices:
                    continue

                fh.write(f"o {safe_name}_{obj_index:04d}_{block_index:03d}\n")
                for vertex in vertices:
                    fh.write(f"v {vertex.x:.8g} {vertex.y:.8g} {vertex.z:.8g}\n")
                for face_offset in range(0, len(local_indices), 3):
                    a, b, c = local_indices[face_offset : face_offset + 3]
                    fh.write(f"f {vertex_index + a} {vertex_index + b} {vertex_index + c}\n")
                vertex_index += len(vertices)
