"""Spatial COL carriers for native polygons outside the visual model bounds."""
from __future__ import annotations

import math


def bounded_triangles(points, faces, limit=500.0):
    """Bisect oversized triangles without changing their surface or winding."""
    pending = [tuple(points[i] for i in face) for face in faces]
    while pending:
        tri = pending.pop()
        if any(not math.isfinite(v) for p in tri for v in p):
            raise ValueError("non-finite native collision vertex")
        if max(max(p[a] for p in tri) - min(p[a] for p in tri) for a in range(3)) <= limit:
            yield tri
            continue
        i = max(range(3), key=lambda i: sum((tri[i][a] - tri[(i+1)%3][a])**2 for a in range(3)))
        a, b, c = tri[i], tri[(i+1)%3], tri[(i+2)%3]
        mid = tuple((a[k]+b[k])/2 for k in range(3))
        pending.extend(((a, mid, c), (mid, b, c)))


def add_carrier_faces(models, points, faces, surface):
    from .mta_scene import MtaMaterial, MtaModel
    for triangle in bounded_triangles(points, faces):
        model = next((m for m in reversed(models) if len(m.collision_vertices) < 59000
                      and all(abs(p[a]-m.origin[a]) <= 250 for p in triangle for a in range(3))), None)
        if model is None:
            origin = tuple((min(p[a] for p in triangle)+max(p[a] for p in triangle))/2 for a in range(3))
            model = MtaModel(f"native_col_{len(models)}", "native_collision_carrier", "native_collision", "shared", origin,
                             materials=[MtaMaterial(None, None, alpha=True, alpha_mode="BLEND")], collision_kind="mesh")
            models.append(model)
        local = [tuple(p[a]-model.origin[a] for a in range(3)) for p in triangle]
        start = len(model.collision_vertices)
        model.collision_vertices.extend(local)
        model.collision_faces.append((start,start+1,start+2))
        model.collision_materials.append(surface)
        # An invisible RenderWare mesh supplies bounds for Eagle streaming.
        bounds_points = model.vertices + local
        low = tuple(min(p[a] for p in bounds_points) for a in range(3))
        high = tuple(max(p[a] for p in bounds_points) for a in range(3))
        axis = max(range(3), key=lambda a: high[a]-low[a])
        corner = tuple(high[a] if a == axis else low[a] for a in range(3))
        model.vertices = [low, high, corner]
        model.faces = [(0,1,2)]
        model.colors = [(255,255,255,0)]*3
        model.uvs = [(0,0)]*3
        model.face_materials = [0]
