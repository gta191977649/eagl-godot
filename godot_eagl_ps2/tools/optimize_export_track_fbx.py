import bpy, math, os
from collections import defaultdict
from mathutils import Vector

src = r"D:\ps2_game\hp2_model\track\track_31.blend"
blend_out = r"D:\ps2_game\hp2_model\track\TRACK31_optimized_merged.blend"
fbx_out = r"D:\ps2_game\hp2_model\track\TRACK31_optimized_merged_binary.fbx"
CELL = 300.0

bpy.ops.wm.open_mainfile(filepath=src)
groups = defaultdict(list)
for o in bpy.context.scene.objects:
    if o.type != 'MESH':
        continue
    corners = [o.matrix_world @ Vector(c) for c in o.bound_box]
    center = sum(corners, Vector()) / 8.0
    cell = (math.floor(center.x / CELL), math.floor(center.y / CELL), math.floor(center.z / CELL))
    sig = tuple(sorted(m.name for m in o.data.materials if m))
    groups[(cell, sig)].append(o)

for index, (key, members) in enumerate(groups.items()):
    if len(members) < 2:
        continue
    bpy.ops.object.select_all(action='DESELECT')
    for o in members:
        o.select_set(True)
    bpy.context.view_layer.objects.active = members[0]
    bpy.ops.object.join()
    members[0].name = f"chunk_{index:04d}"

bpy.ops.wm.save_as_mainfile(filepath=blend_out)

bpy.ops.object.select_all(action='DESELECT')
bpy.ops.export_scene.fbx(
    filepath=fbx_out,
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

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
triangles = sum(sum(max(0, len(p.vertices) - 2) for p in o.data.polygons) for o in meshes)
materials = {m.name for o in meshes for m in o.data.materials if m}
vertices = sum(len(o.data.vertices) for o in meshes)
print(f"OPTIMIZED_MESH_OBJECTS={len(meshes)}")
print(f"OPTIMIZED_VERTICES={vertices}")
print(f"OPTIMIZED_TRIANGLES={triangles}")
print(f"OPTIMIZED_MATERIALS={len(materials)}")
print(f"EXPORTED={fbx_out}")
print(f"EXPORTED_BYTES={os.path.getsize(fbx_out)}")
