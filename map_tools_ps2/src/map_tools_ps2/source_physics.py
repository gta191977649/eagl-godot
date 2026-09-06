"""HP2 PS2 smokeable records, joined by engine identifiers, never by names.

SLUS_203.62: 21f080 loads 34026 (aligned, 224 bytes); 21f198 loads
34027 (8 bytes). 21f294 resolves section/id against 34101 +8 and 34103.
21f8f8 looks up descriptor +70; 2204e4 passes that hash to 219078,
which finds the collision header at aligned 34021 +30.
All offsets below are hexadecimal in the evidence strings.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import math
import struct

from .chunks import Chunk, walk_chunks

PARSER_VERSION = 2


@dataclass(frozen=True)
class SourcePhysicsTemplate:
    key: int
    name: str
    record_offset: int
    raw: bytes
    mass_engine_units: float
    rigid_body_matrix_raw: tuple[float, ...]
    collision_reference_offset: tuple[float, float, float]
    collision_header_offset: int | None
    collision_points: tuple[tuple[float, float, float], ...]
    collision_faces: tuple[tuple[int, int, int], ...] = ()


@dataclass(frozen=True)
class SourcePhysicsBinding:
    record_offset: int
    template_hash: int
    section_id: int
    instance_index: int
    instance_chunk_offset: int | None
    model_hashes: tuple[int, int, int] | None
    error: str | None = None


@dataclass(frozen=True)
class SourcePhysics:
    templates: tuple[SourcePhysicsTemplate, ...] = ()
    bindings: tuple[SourcePhysicsBinding, ...] = ()
    errors: tuple[str, ...] = ()

    def instance_states(self) -> dict[tuple[int, int], tuple[tuple[int, str | None], ...]]:
        """Preserve conflicting/unresolved bindings in deduplication keys too."""
        states: dict[tuple[int, int], list[tuple[int, str | None]]] = {}
        for binding in self.bindings:
            if binding.instance_chunk_offset is not None:
                key = (binding.instance_chunk_offset, binding.instance_index)
                states.setdefault(key, []).append((binding.template_hash, binding.error))
        return {key: tuple(value) for key, value in states.items()}

    def report(self) -> dict:
        templates = []
        for template in self.templates:
            row = asdict(template)
            row['raw'] = template.raw.hex()
            row['attachment_threshold_engine_units'] = struct.unpack_from('<f', template.raw, 0xb4)[0]
            row['damage_budget_engine_units'] = struct.unpack_from('<f', template.raw, 0xb8)[0]
            row['status'] = 'source_linked_gta_unmapped'
            row['limitations'] = ['mass_unit_conversion_unverified', 'inertia_conversion_unverified',
                                 'collision_topology_decoded_runtime_validation_pending', 'game_validation_pending']
            templates.append(row)
        return dict(parser_version=PARSER_VERSION, templates=templates,
                    bindings=[asdict(b) for b in self.bindings], errors=list(self.errors),
                    verified_gta_categories=[])


def _aligned(chunk: Chunk) -> int:
    return (chunk.data_offset + 15) & ~15


def parse_source_physics(chunks: tuple[Chunk, ...], bundle: bytes) -> SourcePhysics:
    flat = tuple(walk_chunks(chunks))
    errors: list[str] = []
    collisions = {}
    for parent in flat:
        if parent.chunk_id != 0x80034020:
            continue
        for index, header in enumerate(parent.children):
            if header.chunk_id != 0x34021:
                continue
            start = _aligned(header)
            if header.end_offset - start < 0x54:
                errors.append(f"truncated_collision_header@{header.offset:x}")
                continue
            key = struct.unpack_from('<I', bundle, start + 0x30)[0]
            points = []
            for child in parent.children[index + 1:]:
                if child.chunk_id == 0x34021:
                    break
                if child.chunk_id == 0x34024:
                    begin = _aligned(child)
                    if (child.end_offset - begin) % 20:
                        errors.append(f"invalid_collision_points@{child.offset:x}")
                        continue
                    points.extend(struct.unpack_from('<3f', bundle, o + 4)
                                  for o in range(begin, child.end_offset, 20))
            if not all(math.isfinite(v) for p in points for v in p):
                errors.append(f"nonfinite_collision_points@{header.offset:x}")
                points = []
            if key in collisions:
                errors.append(f"duplicate_collision_hash:{key:08x}")
            features = {}
            for child in parent.children[index + 1:]:
                if child.chunk_id == 0x34021:
                    break
                stride = {0x34023: 12, 0x34022: 24, 0x34025: 24}.get(child.chunk_id)
                if stride:
                    features[child.chunk_id] = [bundle[o:o + stride] for o in range(_aligned(child), child.end_offset, stride)]
            faces = decode_collision_faces(points, features)
            collisions[key] = (start, tuple(points), faces)

    templates = []
    for chunk in flat:
        if chunk.chunk_id != 0x34026:
            continue
        start = _aligned(chunk)
        if (chunk.end_offset - start) % 0xe0:
            errors.append(f"invalid_template_stride@{chunk.offset:x}")
            continue
        for offset in range(start, chunk.end_offset, 0xe0):
            raw = bundle[offset:offset + 0xe0]
            key = struct.unpack_from('<I', raw, 0x70)[0]
            header_offset, points, faces = collisions.get(key, (None, (), ()))
            templates.append(SourcePhysicsTemplate(
                key=key, name=raw[8:32].split(b'\0')[0].decode('ascii', 'replace'),
                record_offset=offset, raw=raw,
                # 220498 passes descriptor+20 to RigidBody ctor 19c9b0;
                # 19cc6c/78 stores *params as mass, and 1/mass at +11c.
                mass_engine_units=struct.unpack_from('<f', raw, 0x20)[0],
                rigid_body_matrix_raw=struct.unpack_from('<16f', raw, 0x30),
                # Passed to collision constructor at 2204ec. Do not call it
                # COM until the transform/centering contract is established.
                collision_reference_offset=struct.unpack_from('<3f', raw, 0xa0),
                collision_header_offset=header_offset, collision_points=points, collision_faces=faces))

    sections = {}
    for parent in flat:
        if parent.chunk_id != 0x80034100:
            continue
        header = next((c for c in parent.children if c.chunk_id == 0x34101), None)
        if header is None or header.end_offset < _aligned(header) + 12:
            continue
        section_id = struct.unpack_from('<I', bundle, _aligned(header) + 8)[0]
        if section_id in sections:
            errors.append(f"duplicate_section_id:{section_id}")
        sections[section_id] = parent
    template_keys = {t.key for t in templates}
    bindings = []
    for chunk in flat:
        if chunk.chunk_id != 0x34027:
            continue
        if chunk.size % 8:
            errors.append(f"invalid_binding_stride@{chunk.offset:x}")
            continue
        # Unlike 34026 this array is NOT aligned (21f19c).
        for offset in range(chunk.data_offset, chunk.end_offset, 8):
            key, section_id, instance_index = struct.unpack_from('<Ihh', bundle, offset)
            section = sections.get(section_id)
            instance_chunk = next((c for c in section.children if c.chunk_id == 0x34103), None) if section else None
            info_chunk = next((c for c in section.children if c.chunk_id == 0x34102), None) if section else None
            hashes = None
            error = None
            if instance_chunk is None:
                error = 'missing_section_or_instances'
            elif instance_index < 0 or _aligned(instance_chunk) + (instance_index + 1) * 48 > instance_chunk.end_offset:
                error = 'invalid_instance_index'
            else:
                info_index = struct.unpack_from('<h', bundle, _aligned(instance_chunk) + instance_index * 48 + 12)[0]
                if info_chunk is None or info_index < 0 or info_chunk.data_offset + (info_index + 1) * 40 > info_chunk.end_offset:
                    error = 'invalid_info_index'
                else:
                    hashes = struct.unpack_from('<3I', bundle, info_chunk.data_offset + info_index * 40)
            if key not in template_keys:
                error = error or 'missing_physics_template'
            bindings.append(SourcePhysicsBinding(offset, key, section_id, instance_index,
                            instance_chunk.offset if instance_chunk else None, hashes, error))
    return SourcePhysics(tuple(templates), tuple(bindings), tuple(errors))


def decode_collision_faces(points, features):
    """34022 -> 34023 -> 34024 through 34025; SLUS 1d3e68/1d3c60."""
    edges = features.get(0x34023, [])
    links = features.get(0x34025, [])
    def refs(record, offset, kind):
        start = struct.unpack_from('<I', record, offset)[0]
        if start + record[1] > len(links):
            raise ValueError('source collision adjacency out of range')
        values = [struct.unpack_from('<I', link, 20)[0] for link in links[start:start + record[1]]]
        return [v >> 4 for v in values if v != 0xffffffff and v & 15 == kind]
    result = []
    for face in features.get(0x34022, []):
        endpoints = [refs(edges[i], 8, 0) for i in refs(face, 20, 1)]
        if not endpoints or any(len(pair) != 2 for pair in endpoints):
            raise ValueError('source collision face has invalid edges')
        vertices = set(v for pair in endpoints for v in pair)
        if any(v >= len(points) or sum(v in pair for pair in endpoints) != 2 for v in vertices):
            raise ValueError('source collision face is not a closed cycle')
        cycle = [min(vertices)]
        while len(cycle) < len(vertices):
            candidates = [v for pair in endpoints if cycle[-1] in pair for v in pair if v not in cycle]
            if not candidates:
                raise ValueError('source collision disconnected face')
            cycle.append(candidates[0])
        normal = struct.unpack_from('<3f', face, 4)
        a,b,c = (points[v] for v in cycle[:3])
        u = tuple(b[i]-a[i] for i in range(3)); v = tuple(c[i]-a[i] for i in range(3))
        cross = (u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0])
        if sum(cross[i]*normal[i] for i in range(3)) < 0:
            cycle.reverse()
        result.extend((cycle[0],cycle[i],cycle[i+1]) for i in range(1,len(cycle)-1))
    return tuple(result)
