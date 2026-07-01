from __future__ import annotations

from pathlib import Path

from .glb_writer import _indices_for_block
from .model import MeshObject, Scene, instantiated_mesh_object, transformed_block_vertices
from .progress import progress_iter


def write_obj(scene: Scene, out_path: Path, progress: bool = False, expand_instances: bool = False) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    vertex_index = 1
    export_objects = _objects_for_obj_export(scene, expand_instances=expand_instances)
    with out_path.open("w", encoding="utf-8") as fh:
        fh.write("# Experimental NFS HP2 PS2 OBJ export\n")
        fh.write("# Topology is reconstructed from strip-entry metadata and VIF vertex runs.\n")
        for obj_index, obj in enumerate(
            progress_iter(
                export_objects,
                total=len(export_objects),
                desc="Exporting OBJ objects",
                enabled=progress,
            )
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


def _objects_for_obj_export(scene: Scene, expand_instances: bool = False) -> tuple[MeshObject, ...]:
    if not expand_instances or not scene.scenery_instances:
        return tuple(scene.objects)

    first_object_by_name: dict[str, MeshObject] = {}
    for obj in scene.objects:
        first_object_by_name.setdefault(obj.name, obj)

    instanced_names: set[str] = set()
    instances: list[MeshObject] = []
    for instance in scene.scenery_instances:
        base_obj = first_object_by_name.get(instance.object_name)
        if base_obj is None:
            continue
        instanced_names.add(base_obj.name)
        instances.append(instantiated_mesh_object(base_obj, instance))

    static_objects = [
        obj
        for obj in scene.objects
        if obj.name not in instanced_names and obj.chunk_offset not in scene.scenery_template_offsets
    ]
    return tuple(static_objects + instances)
