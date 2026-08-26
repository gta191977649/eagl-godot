import bpy
import sys
from pathlib import Path


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    if len(args) != 3:
        raise SystemExit("usage: blender --background --python blender_export_fbx.py -- input.glb output.fbx texture_dir")
    glb_path, fbx_path, texture_dir = map(Path, args)
    texture_dir.mkdir(parents=True, exist_ok=True)
    bpy.ops.import_scene.gltf(filepath=str(glb_path), merge_vertices=False)
    for index, image in enumerate(bpy.data.images):
        if image.type == "RENDER_RESULT":
            continue
        name = Path(image.name or f"texture_{index:04d}.png").stem + ".png"
        image.filepath = str(texture_dir / name)
        image.filepath_raw = str(texture_dir / name)
        image.file_format = "PNG"
        try:
            image.save()
        except RuntimeError:
            pass
    # The glTF importer uses an Emission/vertex-color node graph. Blender's
    # FBX exporter does not translate that graph reliably, so normalize each
    # material to the Principled + Image Texture graph understood by 3ds Max.
    for material in bpy.data.materials:
        if not material.use_nodes:
            continue
        image = next((n.image for n in material.node_tree.nodes if n.type == "TEX_IMAGE" and n.image), None)
        material.node_tree.nodes.clear()
        output = material.node_tree.nodes.new("ShaderNodeOutputMaterial")
        shader = material.node_tree.nodes.new("ShaderNodeBsdfPrincipled")
        shader.inputs["Roughness"].default_value = 1.0
        material.node_tree.links.new(shader.outputs["BSDF"], output.inputs["Surface"])
        if image is not None:
            texture = material.node_tree.nodes.new("ShaderNodeTexImage")
            texture.image = image
            material.node_tree.links.new(texture.outputs["Color"], shader.inputs["Base Color"])
            if "Alpha" in texture.outputs and "Alpha" in shader.inputs:
                material.node_tree.links.new(texture.outputs["Alpha"], shader.inputs["Alpha"])
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.fbx(
        filepath=str(fbx_path),
        use_selection=False,
        object_types={"MESH", "EMPTY"},
        use_mesh_modifiers=True,
        mesh_smooth_type="FACE",
        add_leaf_bones=False,
        bake_anim=False,
        path_mode="COPY",
        embed_textures=True,
        axis_forward="-Z",
        axis_up="Y",
        apply_unit_scale=True,
    )
    print(f"BLENDER_FBX_EXPORTED={fbx_path}")
    print(f"BLENDER_OBJECTS={len(bpy.context.scene.objects)}")
    print(f"BLENDER_MESHES={sum(1 for o in bpy.context.scene.objects if o.type == 'MESH')}")


if __name__ == "__main__":
    main()
