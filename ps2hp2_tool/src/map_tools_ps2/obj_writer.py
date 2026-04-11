from __future__ import annotations

from pathlib import Path

from .model import Scene, transformed_vertices


def _strip_faces(start_index: int, count: int) -> list[tuple[int, int, int]]:
    faces: list[tuple[int, int, int]] = []
    for i in range(count - 2):
        a = start_index + i
        b = start_index + i + 1
        c = start_index + i + 2
        face = (a, c, b) if i % 2 else (a, b, c)
        if len({face[0], face[1], face[2]}) == 3:
            faces.append(face)
    return faces


def write_obj(scene: Scene, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    vertex_index = 1
    with out_path.open("w", encoding="utf-8") as fh:
        fh.write("# Experimental NFS HP2 PS2 OBJ export\n")
        fh.write("# Topology is reconstructed as triangle strips from VIF vertex runs.\n")
        for obj_index, obj in enumerate(scene.objects):
            safe_name = obj.name.replace(" ", "_").replace("/", "_").replace("\\", "_")
            for run_index, run in enumerate(obj.vertex_runs):
                vertices = transformed_vertices(obj, run)
                if len(vertices) < 3:
                    continue
                fh.write(f"o {safe_name}_{obj_index:04d}_{run_index:03d}\n")
                for vertex in vertices:
                    fh.write(f"v {vertex.x:.8g} {vertex.y:.8g} {vertex.z:.8g}\n")
                for face in _strip_faces(vertex_index, len(vertices)):
                    fh.write(f"f {face[0]} {face[1]} {face[2]}\n")
                vertex_index += len(vertices)
