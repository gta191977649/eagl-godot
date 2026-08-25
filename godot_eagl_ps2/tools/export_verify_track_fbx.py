import bpy
import os
import sys

src = r"D:\ps2_game\hp2_model\track\track_31.blend"
dst = r"D:\ps2_game\hp2_model\track\TRACK31_optimized_binary.fbx"

bpy.ops.wm.open_mainfile(filepath=src)

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
triangles = 0
materials = set()
vertices = 0
for obj in meshes:
    me = obj.data
    vertices += len(me.vertices)
    triangles += sum(max(0, len(p.vertices) - 2) for p in me.polygons)
    materials.update(m.name for m in me.materials if m)

print(f"SOURCE_OBJECTS={len(bpy.context.scene.objects)}")
print(f"SOURCE_MESH_OBJECTS={len(meshes)}")
print(f"SOURCE_MESH_DATABLOCKS={len(bpy.data.meshes)}")
print(f"SOURCE_VERTICES={vertices}")
print(f"SOURCE_TRIANGLES={triangles}")
print(f"SOURCE_MATERIALS_USED={len(materials)}")

for obj in bpy.context.view_layer.objects:
    obj.select_set(False)

bpy.ops.export_scene.fbx(
    filepath=dst,
    use_selection=False,
    object_types={'MESH'},
    use_mesh_modifiers=True,
    mesh_smooth_type='FACE',
    use_custom_props=True,
    add_leaf_bones=False,
    bake_anim=False,
    path_mode='AUTO',
    embed_textures=False,
    axis_forward='-Z',
    axis_up='Y',
    apply_unit_scale=True,
)

print(f"EXPORTED={dst}")
print(f"EXPORTED_BYTES={os.path.getsize(dst)}")
