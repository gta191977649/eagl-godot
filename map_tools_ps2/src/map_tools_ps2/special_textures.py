"""Public naming contract for every exported HP2 texture namespace.

This is the single source of truth for every available special-texture role.
Add or change a role here; scene export, managed packs, manifests, reports and
validation all consume these definitions.
"""
from __future__ import annotations

from dataclasses import dataclass


SPECIAL_TEXTURE_CONTRACT_VERSION = 1
SPECIAL_TEXTURE_DIGEST_LENGTH = 20
# RenderWare/MTA exposes a 32-byte texture-name field. Keep one byte for the C
# string terminator, so exported names use at most 31 visible ASCII characters.
SPECIAL_TEXTURE_NAME_MAX_VISIBLE = 31


@dataclass(frozen=True)
class TextureNamespace:
    prefix: str
    description: str
    in_special_manifest: bool


TEXTURE_NAMESPACES: dict[str, TextureNamespace] = {
    "default": TextureNamespace("hp2_", "Ordinary texture without a surface or effect role", False),
    "road": TextureNamespace("road_", "Native road-family surface", False),
    "dirt": TextureNamespace("dirt_", "Native dirt-family surface", False),
    "grass": TextureNamespace("grass_", "Native grass-family surface", False),
    "reflection": TextureNamespace("refl_", "Water, puddle and wet-surface reflection layer", True),
    "uv_scroll": TextureNamespace("uvscroll_", "Source-authored UV translation animation", True),
    "uv_rotate": TextureNamespace("uvrotate_", "Source-authored UV rotation animation (reserved)", True),
    "texture_animation": TextureNamespace("texanim_", "Source-authored frame texture animation", True),
    "model_animation": TextureNamespace("modelanim_", "Primary texture of a model/vertex animated part", True),
}

TEXTURE_PREFIXES: dict[str, str] = {
    kind: definition.prefix for kind, definition in TEXTURE_NAMESPACES.items()
}
SURFACE_TEXTURE_PREFIXES: dict[str, str] = {
    kind: TEXTURE_PREFIXES[kind] for kind in ("default", "road", "dirt", "grass")
}
SPECIAL_TEXTURE_KINDS: dict[str, TextureNamespace] = {
    kind: definition for kind, definition in TEXTURE_NAMESPACES.items() if definition.in_special_manifest
}
SPECIAL_TEXTURE_PREFIXES: dict[str, str] = {
    kind: definition.prefix for kind, definition in SPECIAL_TEXTURE_KINDS.items()
}


def canonical_special_texture_name(kind: str, identity_digest: str) -> str:
    """Build and validate the stable public texture name for an effect role."""
    try:
        prefix = SPECIAL_TEXTURE_PREFIXES[kind]
    except KeyError as exc:
        raise ValueError(f"unknown special texture kind: {kind}") from exc
    name = prefix + identity_digest[:SPECIAL_TEXTURE_DIGEST_LENGTH]
    if not name.isascii() or len(name) > SPECIAL_TEXTURE_NAME_MAX_VISIBLE:
        raise ValueError(
            f"special texture name exceeds the MTA limit of "
            f"{SPECIAL_TEXTURE_NAME_MAX_VISIBLE} visible ASCII characters: {name}"
        )
    return name


def canonical_texture_name(identity_digest: str, *, surface: str | None = None, special: str | None = None) -> str:
    """Build an ordinary or shader-managed canonical name from one registry."""
    if special is not None:
        return canonical_special_texture_name(special, identity_digest)
    namespace = surface or "default"
    try:
        prefix = SURFACE_TEXTURE_PREFIXES[namespace]
    except KeyError as exc:
        raise ValueError(f"unknown surface texture namespace: {namespace}") from exc
    name = prefix + identity_digest[:SPECIAL_TEXTURE_DIGEST_LENGTH]
    if not name.isascii() or len(name) > SPECIAL_TEXTURE_NAME_MAX_VISIBLE:
        raise ValueError(f"texture name exceeds the MTA limit: {name}")
    return name


def reflection_layer_for_texture(texture: object) -> str:
    """Separate a coverage mask from coloured water without using its name."""
    luminance_max = getattr(texture, "luminance_max", None)
    grayscale_fraction = getattr(texture, "grayscale_fraction", None)
    correlation = getattr(texture, "alpha_luminance_correlation", None)
    if luminance_max is not None and luminance_max <= 2.0:
        return "mask"
    if (
        grayscale_fraction is not None
        and grayscale_fraction >= 0.98
        and correlation is not None
        and correlation <= -0.8
    ):
        return "mask"
    return "surface"
