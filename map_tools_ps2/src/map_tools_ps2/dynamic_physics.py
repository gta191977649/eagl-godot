"""Source-bound dynamic props with explicit, approximate GTA native profiles.

The donor IDs are exact object.dat/IDE joins, not HP2 name classifications.
They select non-explosive, non-breaking, default-response physical groups.
No donor mass is presented as an HP2 unit conversion.
"""
import hashlib
import json
import struct

VERSION = 4
DONORS = {
    # Source +b4 means an attachment that detaches after collision impulse.
    # GTA's sign group has the lamppost collision response required to uproot;
    # bollardlight (1215) is non-special and leaves custom objects inert.
    'attached': {
        'id': 1233, 'name': 'noparkingsign1',
        'ide': 'data/maps/generic/dynamic.ide:28', 'uproot': 100,
        'mass': 30, 'turnMass': 50, 'airResistance': 0.99,
        'buoyancy': 50,
    },
    'free': {
        'id': 1218, 'name': 'barrel1',
        'ide': 'data/maps/generic/dynamic.ide:13', 'uproot': 0,
        'mass': 50, 'turnMass': 50, 'airResistance': 0.99,
        'buoyancy': 50,
    },
}


def source_signature(template):
    raw = bytearray(template.raw)
    for start,end in ((0,32),(0x70,0x74),(0x80,0x90),(0xc0,0xc4),(0xd0,0xe0)):
        raw[start:end] = bytes(end-start)
    return hashlib.sha256(bytes(raw) + repr((template.collision_points,template.collision_faces)).encode()).hexdigest()


def instance_templates(physics):
    by_hash = {}
    for t in physics.templates:
        if t.key in by_hash and source_signature(by_hash[t.key]) != source_signature(t):
            raise ValueError(f'ambiguous dynamic template hash {t.key:08x}')
        by_hash[t.key] = t
    result = {}
    for b in physics.bindings:
        if b.error:
            raise ValueError(f'unresolved dynamic binding at {b.record_offset:x}: {b.error}')
        key = (b.instance_chunk_offset,b.instance_index)
        t = by_hash[b.template_hash]
        if key in result and source_signature(result[key]) != source_signature(t):
            raise ValueError('conflicting dynamic instance profiles')
        result[key] = t
    return result


def configure(model, template, scale, visual_hash):
    if not template.collision_faces:
        raise ValueError(f'{template.name}: dynamic object has no source collision faces')
    attached = struct.unpack_from('<f',template.raw,0xb4)[0] > 0
    donor = DONORS['attached' if attached else 'free']
    model.collision_vertices = [tuple(p[i]*scale[i]-model.origin[i] for i in range(3)) for p in template.collision_points]
    model.collision_faces = [tuple(reversed(f)) if scale[0]*scale[1]*scale[2]<0 else f for f in template.collision_faces]
    model.collision_materials = [0]*len(model.collision_faces)
    model.collision_kind = 'mesh'
    com = tuple(template.collision_reference_offset[i]*scale[i]-model.origin[i] for i in range(3))
    model.physics = {
        'version': VERSION, 'source_signature': source_signature(template),
        'source_hash': f'{template.key:08x}', 'source_name': template.name,
        'status': 'native_gta_approximation_pending_game_validation',
        'donor': donor, 'visual_behavior': 'quadratic_drag_unimplemented' if visual_hash in (0x98c6023c,0x8ac70e76) else 'generic',
        'limitations': ['HP2 mass/inertia units unmapped; donor defaults used',
                       'source friction and damping not reproduced',
                       'native uproot differs from HP2 impulse/lever test',
                       'COL surface defaults to 0; source material mapping unverified',
                       'single-body rendering cannot preserve independent additive render companions',
                       'runtime spawning, source effects and destruction transitions are not implemented'],
        # These are definition defaults. Placement-only ``dynamic`` is kept
        # separate so the emitted XML follows EagleLoader's inheritance
        # contract and can override one field without losing the rest.
        'definition_attributes': {
            'physicsRoot': str(donor['id']), 'simulated': 'true',
            'frozen': 'false', 'breakable': 'true', 'respawn': 'false',
            'mass': str(donor['mass']), 'turnMass': str(donor['turnMass']),
            'airResistance': str(donor['airResistance']),
            'elasticity': str(struct.unpack_from('<f',template.raw,0xbc)[0]),
            'buoyancy': str(donor['buoyancy']),
            'centerOfMass': ','.join(map(str,com)),
        },
        'placement_attributes': {'dynamic': 'true'},
    }


def collision_primitive(model):
    """Derive a GTA movable collision primitive from the exact HP2 COL."""
    if not model.physics or not model.collision_vertices:
        return None
    low = [min(point[axis] for point in model.collision_vertices) for axis in range(3)]
    high = [max(point[axis] for point in model.collision_vertices) for axis in range(3)]
    center = [(low[axis] + high[axis]) * 0.5 for axis in range(3)]
    # GTA's moving-object path needs a volume. Thin triangle-only sign meshes
    # can be hit by a vehicle and still tunnel through a triangle road mesh.
    half = [max((high[axis] - low[axis]) * 0.5, 0.05) for axis in range(3)]
    aspect = max(half) / min(half)
    if aspect <= 1.5:
        return {'type': 'sphere', 'center': center, 'radius': max(half), 'surface': 0}
    return {'type': 'box', 'center': center, 'half_extents': half, 'surface': 0}


def definition_attributes(model):
    return dict(model.physics.get('definition_attributes', {}))


def placement_attributes(model):
    # Keep packed/custom placement paths self-contained. Standard map loading
    # still merges these field-by-field with the identical definition defaults,
    # while callers that instantiate a row directly do not silently lose the
    # simulation contract.
    return {
        **model.physics.get('definition_attributes', {}),
        **model.physics.get('placement_attributes', {}),
    }


def definition_physics_key(model):
    return json.dumps({k:model.physics[k] for k in ('version','source_signature','definition_attributes','placement_attributes','visual_behavior') if k in model.physics},sort_keys=True,separators=(',',':'))
