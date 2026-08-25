import bpy, math
from collections import Counter

bpy.ops.wm.open_mainfile(filepath=r"D:\ps2_game\hp2_model\track\track_31.blend")
groups = Counter()
for o in bpy.context.scene.objects:
    if o.type != 'MESH':
        continue
    corners = [o.matrix_world @ __import__('mathutils').Vector(c) for c in o.bound_box]
    c = sum(corners, __import__('mathutils').Vector()) / 8.0
    cell = (math.floor(c.x/300), math.floor(c.y/300), math.floor(c.z/300))
    sig = tuple(sorted(m.name for m in o.data.materials if m))
    groups[(cell, sig)] += 1
print(f"GROUPS={len(groups)}")
print(f"MULTI_OBJECT_GROUPS={sum(1 for n in groups.values() if n > 1)}")
print(f"MAX_GROUP={max(groups.values())}")
