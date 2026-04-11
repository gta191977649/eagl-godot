from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional


@dataclass
class Symbol:
    name: str
    value: int
    size: int
    info: int
    shndx: int


@dataclass
class ShaderField:
    decl_type: str
    usage: str


@dataclass
class AccessorSpec:
    component_type: int
    count: int
    gltf_type: str
    byte_offset: int
    normalized: bool = False
    min_values: Optional[List[float]] = None
    max_values: Optional[List[float]] = None


@dataclass
class TextureAsset:
    name: str
    png_bytes: bytes
    source: str


@dataclass
class ComponentInput:
    path: Path
    texture_assets: Dict[str, TextureAsset]
    include_models: Optional[set[str]] = None


@dataclass
class PlayableTrack:
    section: str
    track_id: int
    name: str
    display_name: str
    loop: Optional[int]
    length: Optional[float]
    name_variant_index: int


@dataclass
class ExportRequest:
    output_path: Path
    fmt: str
    fidelity: str


@dataclass
class DrvPath:
    compartment_ids: List[int]
    start_nodes: List[int]


@dataclass
class LevelPlacementRecord:
    rot_x: float
    rot_y: float
    rot_z: float
    rot_w: float
    pos_x: float
    pos_y: float
    pos_z: float
    flags: int
    object_id: int


@dataclass
class LevelLinkRecord:
    parent_index: int
    child_index: int
    unk_08: int
    unk_0C: int
    unk_10: int


@dataclass
class LevelNamedObjectRecord:
    primary_name: str
    secondary_name: str
    raw: bytes


@dataclass
class LevelFtRecord:
    model_id: str
    raw: bytes


@dataclass
class LevelGroupRecord:
    unk_00: int
    unk_04: int
    unk_08: int
    type: int
    unk_10: int
    point_count: int
    unk_18: int
    unk_1C: int
    runtime_points: int


@dataclass
class Vec3:
    x: float
    y: float
    z: float


@dataclass
class LevelDat:
    placement_records: List[LevelPlacementRecord]
    link_records: List[LevelLinkRecord]
    named_object_records: List[LevelNamedObjectRecord]
    levelft_records: List[LevelFtRecord]
    table4_records: List[bytes]
    table5_records: List[bytes]
    table6_records: List[bytes]
    group_records: List[LevelGroupRecord]
    point_records: List[Vec3]


class LayerClass(str, Enum):
    OPAQUE = "opaque"
    ALPHA1 = "alpha1"
    ALPHA2 = "alpha2"
    ALPHA3 = "alpha3"
    ALPHA4 = "alpha4"
    ALPHA5 = "alpha5"
    OPAQUE_LOD = "opaqueLOD"
    ALPHA1_LOD = "alpha1LOD"
    ALPHA2_LOD = "alpha2LOD"
    ALPHA3_LOD = "alpha3LOD"
    ALPHA4_LOD = "alpha4LOD"
    ALPHA5_LOD = "alpha5LOD"
    UNKNOWN = "unknown"


@dataclass
class RouteContext:
    playable_track: Optional[PlayableTrack]
    name_dir: Path
    level_dir: Path
    level_index: int
    compartment_ids: List[int]
    levelft_ids: List[str]
    shared_textures: Dict[str, TextureAsset] = field(default_factory=dict)
    route_textures: Dict[str, TextureAsset] = field(default_factory=dict)
