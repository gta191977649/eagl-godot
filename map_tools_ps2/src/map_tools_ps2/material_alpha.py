from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Iterable, Mapping

from .model import Scene
from .textures import Texture, TextureLibrary


AlphaMode = str


@dataclass(frozen=True)
class MaterialAlphaDecision:
    mode: AlphaMode
    cutoff: float | None
    reason: str
    render_flag: int | None
    is_any_semitransparency: int | None
    alpha_bits: int | None
    alpha_fix: int | None
    texture_fx: int | None


def is_opaque_surface_state(render_flag: int | None) -> bool:
    if render_flag is None:
        return False
    return (render_flag & 0x4040) == 0x4040 and (render_flag & 0x0080) == 0


def scene_texture_render_flags(scene: Scene) -> dict[int, frozenset[int | None]]:
    usage: dict[int, set[int | None]] = defaultdict(set)
    for obj in scene.objects:
        for block_index, block in enumerate(obj.blocks):
            if not obj.texture_hashes:
                continue
            texture_index = block.texture_index
            if texture_index is None or not 0 <= texture_index < len(obj.texture_hashes):
                texture_index = min(block_index, len(obj.texture_hashes) - 1)
            usage[obj.texture_hashes[texture_index]].add(block.render_flag)
    return {texture_hash: frozenset(flags) for texture_hash, flags in usage.items()}


def _pixel_candidate(texture: Texture) -> tuple[AlphaMode, float | None, str]:
    zero_count = getattr(texture, "alpha_zero_count", None)
    opaque_count = getattr(texture, "alpha_opaque_count", None)
    if zero_count is not None and opaque_count is not None:
        if zero_count > 0 and opaque_count > 0:
            return "MASK", getattr(texture, "alpha_cutoff", None) or 0.5, "pixel_cutout_endpoints"
        if getattr(texture, "alpha_intermediate_count", None):
            return "OPAQUE", None, "intermediate_alpha_without_tpk_semitransparency"
        return "OPAQUE", None, "opaque_pixels"
    if getattr(texture, "alpha_mode", None) == "MASK":
        return "MASK", getattr(texture, "alpha_cutoff", None) or 0.5, "pixel_cutout_endpoints"
    if getattr(texture, "alpha_mode", None) == "BLEND":
        return "OPAQUE", None, "intermediate_alpha_without_tpk_semitransparency"
    if getattr(texture, "alpha_mode", None) is None:
        return "OPAQUE", None, "opaque_pixels"
    return "MASK", texture.alpha_cutoff or 0.5, "unknown_alpha_preserved_as_mask"


def decide_material_alpha(
    texture: Texture | None,
    render_flag: int | None,
    usage_flags: Iterable[int | None] = (),
) -> MaterialAlphaDecision:
    if texture is None:
        return MaterialAlphaDecision("OPAQUE", None, "missing_texture", render_flag, None, None, None, None)
    semitransparency = getattr(texture, "is_any_semitransparency", None)
    alpha_bits = getattr(texture, "alpha_bits", None)
    alpha_fix = getattr(texture, "alpha_fix", None)
    texture_fx = getattr(texture, "texture_fx", None)
    if semitransparency or alpha_bits == 0x44:
        return MaterialAlphaDecision(
            "BLEND", None, "tpk_semitransparency", render_flag,
            semitransparency, alpha_bits, alpha_fix, texture_fx,
        )
    if is_opaque_surface_state(render_flag):
        return MaterialAlphaDecision(
            "OPAQUE", None, "opaque_surface_state", render_flag,
            semitransparency, alpha_bits, alpha_fix, texture_fx,
        )
    flags = frozenset(usage_flags)
    explicit = {flag for flag in flags if flag is not None}
    if render_flag is None and explicit and all(is_opaque_surface_state(flag) for flag in explicit):
        return MaterialAlphaDecision(
            "OPAQUE", None, "inherited_opaque_surface_state", render_flag,
            semitransparency, alpha_bits, alpha_fix, texture_fx,
        )
    mode, cutoff, reason = _pixel_candidate(texture)
    return MaterialAlphaDecision(
        mode, cutoff, reason, render_flag,
        semitransparency, alpha_bits, alpha_fix, texture_fx,
    )


def alpha_decisions_for_scene(
    scene: Scene,
    textures: TextureLibrary,
) -> tuple[dict[tuple[int, int | None], MaterialAlphaDecision], dict[int, frozenset[int | None]]]:
    usage = scene_texture_render_flags(scene)
    decisions = {
        (texture_hash, render_flag): decide_material_alpha(textures.get(texture_hash), render_flag, flags)
        for texture_hash, flags in usage.items()
        for render_flag in flags
    }
    return decisions, usage


def alpha_diagnostics(
    decisions: Mapping[tuple[int, int | None], MaterialAlphaDecision],
    textures: TextureLibrary,
) -> dict[str, object]:
    reason_counts = Counter(decision.reason for decision in decisions.values())
    mode_counts = Counter(decision.mode for decision in decisions.values())
    by_texture: dict[int, set[str]] = defaultdict(set)
    for (texture_hash, _render_flag), decision in decisions.items():
        by_texture[texture_hash].add(decision.mode)
    conflicts = []
    corrected = []
    tpk_conflicts = []
    for texture_hash, modes in sorted(by_texture.items()):
        texture = textures.get(texture_hash)
        name = texture.name if texture is not None else f"0x{texture_hash:08x}"
        if len(modes) > 1:
            conflicts.append({"hash": f"0x{texture_hash:08x}", "name": name, "modes": sorted(modes)})
        source_mode = getattr(texture, "alpha_mode", None) if texture is not None else None
        if texture is not None and source_mode in {"MASK", "BLEND"} and "OPAQUE" in modes:
            corrected.append({"hash": f"0x{texture_hash:08x}", "name": name, "source_mode": source_mode})
        semitransparency = getattr(texture, "is_any_semitransparency", None) if texture is not None else None
        alpha_bits = getattr(texture, "alpha_bits", None) if texture is not None else None
        if texture is not None and alpha_bits is not None and bool(semitransparency) != (alpha_bits == 0x44):
            tpk_conflicts.append(
                {
                    "hash": f"0x{texture_hash:08x}",
                    "name": name,
                    "is_any_semitransparency": semitransparency,
                    "alpha_bits": alpha_bits,
                }
            )
    return {
        "surface_modes": dict(sorted(mode_counts.items())),
        "decision_reasons": dict(sorted(reason_counts.items())),
        "multi_mode_textures": conflicts,
        "draw_state_corrected_opaque": corrected,
        "tpk_flag_conflicts": tpk_conflicts,
        "missing_render_flag_states": sum(render_flag is None for _texture_hash, render_flag in decisions),
        "render_flag_states": dict(
            sorted(
                Counter("none" if render_flag is None else f"0x{render_flag:04x}" for _texture_hash, render_flag in decisions).items()
            )
        ),
    }
