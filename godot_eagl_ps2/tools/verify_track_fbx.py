import bpy
import os
import sys

src = r"D:\ps2_game\hp2_model\track\TRACK31_optimized_binary.fbx"

with open(src, 'rb') as f:
    header = f.read(27)
print(f"HEADER={header!r}")
print(f"IS_BINARY={header != b'; FBX 7.4.0 project file' and not header.startswith(b'; FBX')}")
print(f"BYTES={os.path.getsize(src)}")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=src, use_anim=False, automatic_bone_orientation=False)

objs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
mesh_data = {o.data for o in objs}
verts = sum(len(m.vertices) for m in mesh_data)
tris = sum(sum(max(0, len(p.vertices) - 2) for p in m.polygons) for m in mesh_data)
mats = {m.name for m in bpy.data.materials}
used_mats = {m.name for o in objs for m in o.data.materials if m}
print(f"IMPORTED_OBJECTS={len(bpy.context.scene.objects)}")
print(f"IMPORTED_MESH_OBJECTS={len(objs)}")
print(f"IMPORTED_MESH_DATABLOCKS={len(mesh_data)}")
print(f"IMPORTED_VERTICES={verts}")
print(f"IMPORTED_TRIANGLES={tris}")
print(f"IMPORTED_MATERIALS={len(mats)}")
print(f"IMPORTED_USED_MATERIALS={len(used_mats)}")

errors = []
if header.startswith(b'; FBX'):
    errors.append('ASCII FBX header detected')
if not objs:
    errors.append('no mesh objects imported')
if tris != 499059:
    errors.append(f'triangle count mismatch: {tris}')
if len(used_mats) != 322:
    errors.append(f'material count mismatch: {len(used_mats)}')
print('VERDICT=' + ('PASS' if not errors else 'FAIL'))
for e in errors:
    print('ERROR=' + e)
