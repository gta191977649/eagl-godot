from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .export.gltf_writer import GlTFWriter
from .models import ComponentInput, PlayableTrack, TextureAsset
from .parsers.bigf import BigfArchive
from .parsers.fsh import FshArchive, decode_fsh_image
from .render.layer_policy import LayerPolicy
from .render.scene_builder import SceneBuilder
from .route_resolver import RouteResolver
from .shader_library import ShaderLibrary
from .track_catalog import TrackCatalog
from .utils import safe_name


class TrackManager:
    def __init__(self, shader_source: Path) -> None:
        self.shader_library = ShaderLibrary(shader_source)
        self.layer_policy = LayerPolicy()
        self.scene_builder = SceneBuilder(self.shader_library, self.layer_policy)
        self.writer = GlTFWriter()

    def export_playable_track(
        self,
        tracks_root: Path,
        out_path: Path,
        track_id: Optional[int] = None,
        track_name: Optional[str] = None,
        level: Optional[int] = None,
        fidelity: str = "faithful",
    ) -> Path:
        catalog = TrackCatalog(tracks_root)
        if track_id is not None:
            playable_track = catalog.get_by_id(track_id)
        elif track_name is not None:
            playable_track = catalog.get_by_name(track_name)
        else:
            raise ValueError("export_playable_track requires track_id or track_name")

        resolver = RouteResolver(tracks_root)
        route_context, _level_dat = resolver.resolve(playable_track, level)
        default_level = playable_track.name_variant_index - 1
        scene_name = f"track{playable_track.track_id:02d}_{safe_name(playable_track.display_name)}"
        if level is not None and level != default_level:
            scene_name = f"{scene_name}_level{level:02d}"
        metadata = {
            "trackId": playable_track.track_id,
            "variantSection": playable_track.section,
            "displayName": playable_track.display_name,
            "nameFolder": playable_track.name,
            "levelDir": route_context.level_dir.name,
            "levelIndex": route_context.level_index,
            "loop": playable_track.loop,
            "length": playable_track.length,
            "nameVariantIndex": playable_track.name_variant_index,
        }
        return self._export_route_context(route_context, out_path, scene_name, metadata, fidelity)

    def export_name_world(
        self,
        tracks_root: Path,
        name: str,
        out_path: Path,
        fidelity: str = "raw",
        variant: Optional[int] = None,
        level: Optional[int] = None,
    ) -> Path:
        if variant is not None and level is not None:
            raise ValueError("Use --variant or --level, not both")

        if level is not None:
            return self.export_name_level(
                tracks_root=tracks_root,
                name=name,
                level=level,
                out_path=out_path,
                fidelity=fidelity,
            )

        if variant is not None:
            catalog = TrackCatalog(tracks_root)
            playable_track = catalog.resolve_name_variant(name, variant)
            return self.export_playable_track(
                tracks_root,
                out_path,
                track_id=playable_track.track_id,
                fidelity="faithful",
            )

        name_dir = tracks_root / name
        if not name_dir.exists():
            raise ValueError(f"Name folder not found: {name_dir}")
        base_textures = self._collect_base_textures(name_dir)
        components = [ComponentInput(path=comp_path, texture_assets=base_textures) for comp_path in sorted(name_dir.glob("comp*.o"))]
        metadata = {"nameFolder": name, "mode": "name_world"}
        return self._build_and_write(components, out_path, name, metadata, fidelity)

    def export_name_level(
        self,
        tracks_root: Path,
        name: str,
        level: int,
        out_path: Path,
        fidelity: str = "faithful",
    ) -> Path:
        resolver = RouteResolver(tracks_root)
        route_context, _level_dat = resolver.resolve_name_level(name, level)
        scene_name = f"{safe_name(name)}_level{level:02d}"
        metadata = {
            "nameFolder": name,
            "levelDir": route_context.level_dir.name,
            "levelIndex": route_context.level_index,
            "mode": "name_level",
        }
        return self._export_route_context(route_context, out_path, scene_name, metadata, fidelity)

    def export_all_tracks(self, tracks_root: Path, out_dir: Path, fmt: str, fidelity: str = "faithful") -> List[Path]:
        catalog = TrackCatalog(tracks_root)
        out_dir.mkdir(parents=True, exist_ok=True)
        outputs = []
        for playable_track in catalog.tracks:
            ext = ".glb" if fmt == "glb" else ".gltf"
            out_path = out_dir / f"track{playable_track.track_id:02d}_{safe_name(playable_track.display_name)}{ext}"
            outputs.append(
                self.export_playable_track(
                    tracks_root,
                    out_path,
                    track_id=playable_track.track_id,
                    fidelity=fidelity,
                )
            )
        return outputs

    def _build_route_components(self, route_context) -> List[ComponentInput]:
        shared_textures = route_context.shared_textures
        seen = set()
        ordered_ids = []
        for comp_id in route_context.compartment_ids:
            if comp_id in seen:
                continue
            seen.add(comp_id)
            ordered_ids.append(comp_id)

        components: List[ComponentInput] = []
        for comp_id in ordered_ids:
            comp_path = route_context.name_dir / f"comp{comp_id:02d}.o"
            if comp_path.exists():
                components.append(ComponentInput(path=comp_path, texture_assets=shared_textures))

        level_g = route_context.level_dir / "levelG.o"
        if level_g.exists():
            merged = dict(shared_textures)
            merged.update(route_context.route_textures)
            components.append(
                ComponentInput(
                    path=level_g,
                    texture_assets=merged,
                    include_models={f"levelft.{value}" for value in route_context.levelft_ids},
                )
            )
        return components

    def _build_and_write(
        self,
        components: List[ComponentInput],
        out_path: Path,
        scene_name: str,
        metadata: dict,
        fidelity: str,
    ) -> Path:
        binary = out_path.suffix.lower() == ".glb"
        state, raw_chunks = self.scene_builder.build_scene(
            components=components,
            out_path=out_path,
            binary=binary,
            scene_name=scene_name,
            metadata=metadata,
            fidelity=fidelity,
        )
        self.writer.write(state, raw_chunks, out_path, binary)
        return out_path

    def _export_route_context(
        self,
        route_context,
        out_path: Path,
        scene_name: str,
        metadata: dict,
        fidelity: str,
    ) -> Path:
        route_context.shared_textures = self._collect_base_textures(route_context.name_dir)
        route_context.route_textures = self._collect_fsh_file(route_context.level_dir / "level.fsh")
        components = self._build_route_components(route_context)
        return self._build_and_write(components, out_path, scene_name, metadata, fidelity)

    def _collect_base_textures(self, track_dir: Path) -> Dict[str, TextureAsset]:
        ordered_banks: List[Tuple[str, bytes]] = []
        persist_path = track_dir / "persist.viv"
        if persist_path.exists():
            persist = BigfArchive(persist_path)
            preferred = ["track.fsh", "sky.fsh", "flares.fsh", "sun.fsh", "lightglows.fsh", "particle.fsh"]
            for name in preferred:
                if name in persist.entries:
                    ordered_banks.append((f"{persist_path.name}:{name}", persist.entries[name]))
            for name, blob in sorted(persist.entries.items()):
                if name.endswith(".fsh") and name not in preferred:
                    ordered_banks.append((f"{persist_path.name}:{name}", blob))

        for fsh_path in sorted(track_dir.glob("*.fsh")):
            ordered_banks.append((fsh_path.name, fsh_path.read_bytes()))

        for viv_path in sorted(track_dir.glob("comp*.viv")):
            archive = BigfArchive(viv_path)
            for name, blob in sorted(archive.entries.items()):
                if name.endswith(".fsh"):
                    ordered_banks.append((f"{viv_path.name}:{name}", blob))

        return self._decode_texture_banks(ordered_banks)

    def _collect_fsh_file(self, fsh_path: Path) -> Dict[str, TextureAsset]:
        if not fsh_path.exists():
            return {}
        return self._decode_texture_banks([(fsh_path.name, fsh_path.read_bytes())])

    def _decode_texture_banks(self, ordered_banks: List[Tuple[str, bytes]]) -> Dict[str, TextureAsset]:
        textures: Dict[str, TextureAsset] = {}
        for source, blob in ordered_banks:
            fsh = FshArchive(blob, source)
            for image in fsh.images:
                key = image.tag.lower()
                if key in textures:
                    continue
                png_bytes = decode_fsh_image(image)
                if png_bytes is None:
                    continue
                textures[key] = TextureAsset(name=image.tag, png_bytes=png_bytes, source=source)
        return textures
