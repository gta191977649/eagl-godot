from __future__ import annotations

import math
import re
import struct
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from ..models import AccessorSpec, ComponentInput, ShaderField
from ..parsers.elf_object import ElfObject
from ..render.layer_policy import LayerPolicy
from ..render.materials import (
    choose_material_texture,
    png_has_alpha,
    prepare_material_texture,
    sample_alpha_at_uvs,
    shader_texture_mode,
)
from ..shader_library import ShaderLibrary
from ..utils import safe_name


class SceneBuilder:
    TYPE_TO_FORMAT = {
        "Float2": ("<2f", 8, "VEC2", 5126, False),
        "Float3": ("<3f", 12, "VEC3", 5126, False),
        "Float4": ("<4f", 16, "VEC4", 5126, False),
        "D3DColor": ("<4B", 4, "VEC4", 5121, True),
        "UByte4": ("<4B", 4, "VEC4", 5121, False),
    }

    USAGE_TO_ATTR = {
        "Position": "POSITION",
        "Normal": "NORMAL",
        "Texcoord0": "TEXCOORD_0",
        "Texcoord1": "TEXCOORD_1",
        "Texcoord2": "TEXCOORD_2",
        "Texcoord3": "TEXCOORD_3",
        "Color0": "COLOR_0",
        "BlendIndices": "JOINTS_0",
        "BlendWeight": "WEIGHTS_0",
    }

    def __init__(self, shader_library: ShaderLibrary, layer_policy: LayerPolicy) -> None:
        self.shader_library = shader_library
        self.layer_policy = layer_policy

    def build_scene(
        self,
        components: List[ComponentInput],
        out_path: Path,
        binary: bool,
        scene_name: str,
        metadata: Optional[dict],
        fidelity: str,
    ) -> tuple[dict, List[bytes]]:
        raw_chunks: List[bytes] = []
        state = {
            "asset": {"generator": "map_otools", "version": "2.0"},
            "scene": 0,
            "scenes": [{"name": scene_name, "nodes": []}],
            "nodes": [],
            "meshes": [],
            "materials": [],
            "buffers": [],
            "bufferViews": [],
            "accessors": [],
            "images": [],
            "textures": [],
            "samplers": [],
            "_triangle_registry": set(),
        }
        if metadata:
            state["asset"]["extras"] = metadata
            state["scenes"][0]["extras"] = metadata

        texture_map: Dict[Tuple[str, str], int] = {}
        material_map: Dict[Tuple[object, ...], int] = {}
        for component in components:
            self._append_component(
                component.path,
                state,
                raw_chunks,
                component.texture_assets,
                texture_map,
                material_map,
                out_path,
                binary,
                component.include_models,
                fidelity,
            )

        if not state["meshes"]:
            raise ValueError("No meshes extracted")

        state.pop("_triangle_registry", None)
        return state, raw_chunks

    def _append_component(
        self,
        comp_path: Path,
        state: dict,
        raw_chunks: List[bytes],
        texture_assets: Dict[str, object],
        texture_map: Dict[Tuple[str, str], int],
        material_map: Dict[Tuple[object, ...], int],
        out_path: Path,
        binary: bool,
        include_models: Optional[set[str]],
        fidelity: str,
    ) -> None:
        elf = ElfObject(comp_path)
        model_syms = elf.data_symbol("__Model:::")
        if not model_syms:
            return

        model_syms.sort(key=lambda s: elf.u32(s.value + 0xC0) if s.value + 0xC4 <= len(elf.data) else 0)
        for model in model_syms:
            model_label = model.name[10:] if model.name.startswith("__Model:::") else comp_path.stem
            if include_models is not None and model_label not in include_models:
                continue
            num_layers = elf.u32(model.value + 0x9C)
            layer_names_ptr = elf.u32(model.value + 0xA0)
            layers_ptr = elf.u32(model.value + 0xCC)
            if layers_ptr == 0:
                continue

            if num_layers == 0 and elf.u32(layers_ptr) == 0xA0000000:
                self._append_segmented_old_format_model(
                    elf,
                    comp_path,
                    model_label,
                    layers_ptr,
                    state,
                    raw_chunks,
                    texture_assets,
                    texture_map,
                    material_map,
                    out_path,
                    binary,
                )
                continue

            if num_layers == 0:
                continue

            layer_records = self._collect_layer_records(elf, model_label, num_layers, layer_names_ptr, layers_ptr)
            selected_indices = self.layer_policy.select_indices([item[0] for item in layer_records], fidelity)

            for layer_index in selected_indices:
                layer_name, entries_base, num_primitives, old_format = layer_records[layer_index]
                if old_format:
                    for prim_index in range(num_primitives):
                        render_desc_ptr_off = entries_base + prim_index * 8 + 4
                        render_descriptor = elf.u32(render_desc_ptr_off)
                        prim = self._extract_primitive(
                            elf,
                            render_descriptor,
                            texture_assets,
                            texture_map,
                            state,
                            raw_chunks,
                            material_map,
                            out_path,
                            binary,
                        )
                        if prim is not None:
                            mesh_name = f"{comp_path.stem}:{layer_name}_prim_{prim_index:03d}"
                            self._append_mesh_node(state, mesh_name, [prim])
                    continue

                primitives = []
                for prim_index in range(num_primitives):
                    render_desc_ptr_off = entries_base + (prim_index * (8 if old_format else 4)) + (4 if old_format else 0)
                    render_descriptor = elf.u32(render_desc_ptr_off)
                    prim = self._extract_primitive(
                        elf,
                        render_descriptor,
                        texture_assets,
                        texture_map,
                        state,
                        raw_chunks,
                        material_map,
                        out_path,
                        binary,
                    )
                    if prim is not None:
                        primitives.append(prim)

                if primitives:
                    mesh_name = f"{comp_path.stem}:{layer_name}"
                    self._append_mesh_node(state, mesh_name, primitives)

    def _append_mesh_node(self, state: dict, mesh_name: str, primitives: List[dict]) -> None:
        mesh_index = len(state["meshes"])
        state["meshes"].append({"name": mesh_name, "primitives": primitives})
        node_index = len(state["nodes"])
        state["nodes"].append({"name": mesh_name, "mesh": mesh_index})
        state["scenes"][0]["nodes"].append(node_index)

    def _collect_layer_records(
        self,
        elf: ElfObject,
        model_label: str,
        num_layers: int,
        layer_names_ptr: int,
        layers_ptr: int,
    ) -> List[Tuple[str, int, int, bool]]:
        cursor = layers_ptr
        header = elf.u32(cursor)
        old_format = header == 0xA0000000
        cursor += 4
        if old_format:
            cursor += 8

        records = []
        for layer_index in range(num_layers):
            layer_name = f"{model_label}_layer_{layer_index}"
            if layer_names_ptr:
                try:
                    layer_name_off = elf.u32(layer_names_ptr + layer_index * 4)
                    if layer_name_off:
                        layer_name = elf.cstring(layer_name_off)
                except struct.error:
                    pass

            local_cursor = cursor
            if old_format:
                local_cursor += 8
            num_primitives = elf.u32(local_cursor)
            if old_format:
                num_primitives //= 2
            entries_base = local_cursor + 4
            records.append((layer_name, entries_base, num_primitives, old_format))
            cursor = entries_base + num_primitives * (8 if old_format else 4)
        return records

    def _append_segmented_old_format_model(
        self,
        elf: ElfObject,
        comp_path: Path,
        model_label: str,
        layers_ptr: int,
        state: dict,
        raw_chunks: List[bytes],
        texture_assets: Dict[str, object],
        texture_map: Dict[Tuple[str, str], int],
        material_map: Dict[Tuple[object, ...], int],
        out_path: Path,
        binary: bool,
    ) -> None:
        if layers_ptr + 12 > len(elf.data) or elf.u32(layers_ptr) != 0xA0000000:
            return

        raw_count = elf.u32(layers_ptr + 8)
        if raw_count == 0 or raw_count > 0x1000:
            return

        num_primitives = raw_count // 2
        entries_base = layers_ptr + 12
        primitives = []
        for prim_index in range(num_primitives):
            render_descriptor = elf.u32(entries_base + prim_index * 8 + 4)
            prim = self._extract_primitive(
                elf,
                render_descriptor,
                texture_assets,
                texture_map,
                state,
                raw_chunks,
                material_map,
                out_path,
                binary,
            )
            if prim is not None:
                primitives.append(prim)

        if primitives:
            mesh_name = f"{comp_path.stem}:{model_label}"
            self._append_mesh_node(state, mesh_name, primitives)

    def _extract_primitive(
        self,
        elf: ElfObject,
        render_descriptor: int,
        texture_assets: Dict[str, object],
        texture_map: Dict[Tuple[str, str], int],
        state: dict,
        raw_chunks: List[bytes],
        material_map: Dict[Tuple[object, ...], int],
        out_path: Path,
        binary: bool,
    ) -> Optional[dict]:
        if render_descriptor == 0:
            return None

        render_method = elf.u32(render_descriptor)
        global_parameters = render_descriptor + 4
        if render_method == 0:
            return None

        rm_code_offset = render_method + 8
        shader_symbol = elf.relocations.get(rm_code_offset)
        shader_name = None
        if shader_symbol and shader_symbol.name.endswith("__EAGLMicroCode"):
            shader_name = shader_symbol.name[:-15]

        declaration = self.shader_library.get(shader_name or "")
        if not declaration:
            return None

        render_code = elf.u32(render_method + 0)
        command_offset = 0
        num_commands = 0
        vertex_buffer = 0
        vertex_stride = 0
        vertex_count = 0
        index_buffer = 0
        index_size = 0
        index_count = 0
        primitive_mode = 5
        sampler_textures: Dict[int, str] = {}

        while True:
            size = elf.u16(render_code + command_offset)
            cmd_id = elf.u16(render_code + command_offset + 2)
            if cmd_id == 0 or size == 0:
                break

            if cmd_id in (4, 75) and vertex_buffer == 0:
                vertex_count = elf.u32(global_parameters)
                vertex_buffer = elf.u32(global_parameters + 4)
                vertex_stride = elf.u32(render_code + command_offset + 8)
            elif cmd_id == 7 and index_buffer == 0:
                index_count = elf.u32(global_parameters)
                index_buffer = elf.u32(global_parameters + 4)
                index_size = elf.u32(render_code + command_offset + 4)
            elif cmd_id == 33:
                gp_state = elf.u32(global_parameters + 4)
                if gp_state:
                    primitive_mode = {1: 0, 2: 1, 3: 3, 4: 4, 5: 5, 6: 6}.get(elf.u32(gp_state), primitive_mode)
                else:
                    rel = elf.relocations.get(elf.u32(global_parameters + 4))
                    if rel and "SetPrimitiveType=" in rel.name:
                        primitive_mode = self._primitive_mode_from_string(rel.name)
            elif cmd_id in (9, 32):
                sampler_index = elf.u32(render_code + command_offset + 4)
                texture_name = self._resolve_texture_name(elf, global_parameters)
                if texture_name and sampler_index < 8 and sampler_index not in sampler_textures:
                    sampler_textures[sampler_index] = texture_name

            if num_commands != 0:
                global_parameters += 8
            num_commands += 1
            command_offset += size * 4
            if command_offset >= len(elf.data):
                break

        if not vertex_buffer or not index_buffer or vertex_count == 0 or index_count < 3:
            return None

        indices = self._read_indices(elf, index_buffer, index_count, index_size, primitive_mode)
        if len(indices) < 3:
            return None

        positions = self._read_field_values(elf, vertex_buffer, vertex_count, vertex_stride, declaration, "Position")
        texcoords0 = self._read_field_values(elf, vertex_buffer, vertex_count, vertex_stride, declaration, "Texcoord0")
        overlay_vertex_alpha = self._overlay_vertex_alpha(
            shader_name or "Unknown",
            sampler_textures,
            texture_assets,
            elf,
            vertex_buffer,
            vertex_count,
            vertex_stride,
            declaration,
        )
        attributes: Dict[str, int] = {}
        attr_offset = 0
        for field in declaration:
            if field.usage == "Color1":
                attr_offset += 4
                continue
            if field.usage in ("BlendIndices", "BlendWeight"):
                break
            attr_name = self.USAGE_TO_ATTR.get(field.usage)
            fmt_info = self.TYPE_TO_FORMAT.get(field.decl_type)
            if attr_name is None or fmt_info is None:
                continue
            if field.usage == "Color0" and overlay_vertex_alpha is not None:
                values_list = self._read_field_values_from_offset(
                    elf,
                    vertex_buffer,
                    vertex_count,
                    vertex_stride,
                    attr_offset,
                    field,
                )
                if values_list is not None:
                    values_list = [
                        (values[0], values[1], values[2], int(round(values[3] * alpha / 255.0)))
                        for values, alpha in zip(values_list, overlay_vertex_alpha)
                    ]
                    accessor_index = self._append_accessor_for_values(values_list, field, raw_chunks, state)
                else:
                    accessor_index = None
            else:
                accessor_index = self._append_accessor_for_field(
                    elf,
                    raw_chunks,
                    state,
                    vertex_buffer,
                    vertex_count,
                    vertex_stride,
                    attr_offset,
                    field,
                )
            if accessor_index is not None:
                attributes[attr_name] = accessor_index
            attr_offset += fmt_info[1]

        if "POSITION" not in attributes:
            return None

        texture_name = choose_material_texture(shader_name or "Unknown", sampler_textures)
        indices = self._dedupe_triangles(
            state,
            shader_name or "Unknown",
            texture_name,
            indices,
            positions,
            texcoords0,
        )
        if len(indices) < 3:
            return None
        index_accessor = self._append_index_accessor(indices, raw_chunks, state)
        material_index = self._material_for(
            shader_name or "Unknown",
            texture_name,
            sampler_textures,
            state,
            texture_assets,
            texture_map,
            material_map,
            raw_chunks,
            out_path,
            binary,
        )
        return {"attributes": attributes, "indices": index_accessor, "mode": 4, "material": material_index}

    def _overlay_vertex_alpha(
        self,
        shader_name: str,
        sampler_textures: Dict[int, str],
        texture_assets: Dict[str, object],
        elf: ElfObject,
        vertex_buffer: int,
        vertex_count: int,
        vertex_stride: int,
        declaration: List[ShaderField],
    ) -> Optional[List[int]]:
        if shader_name != "BlendedOverlay":
            return None
        if choose_material_texture(shader_name, sampler_textures) != sampler_textures.get(0):
            return None
        mask_name = sampler_textures.get(2)
        if not mask_name:
            return None
        mask_asset = texture_assets.get(mask_name.lower())
        if mask_asset is None:
            return None
        uvs = self._read_field_values(elf, vertex_buffer, vertex_count, vertex_stride, declaration, "Texcoord2")
        if uvs is None:
            return None
        return sample_alpha_at_uvs(mask_asset.png_bytes, uvs)

    def _append_accessor_for_field(
        self,
        elf: ElfObject,
        raw_chunks: List[bytes],
        state: dict,
        vertex_buffer: int,
        vertex_count: int,
        vertex_stride: int,
        attr_offset: int,
        field: ShaderField,
    ) -> Optional[int]:
        values_list = self._read_field_values_from_offset(
            elf,
            vertex_buffer,
            vertex_count,
            vertex_stride,
            attr_offset,
            field,
        )
        if values_list is None:
            return None
        return self._append_accessor_for_values(values_list, field, raw_chunks, state)

    def _append_accessor_for_values(
        self,
        values_list: List[Tuple[float, ...]],
        field: ShaderField,
        raw_chunks: List[bytes],
        state: dict,
    ) -> Optional[int]:
        fmt_info = self.TYPE_TO_FORMAT.get(field.decl_type)
        if fmt_info is None:
            return None
        _fmt, _size, gltf_type, component_type, normalized = fmt_info
        chunks = []
        min_values = None
        max_values = None

        for values in values_list:
            if component_type == 5126:
                chunks.append(struct.pack("<" + "f" * len(values), *values))
            else:
                chunks.append(struct.pack("<" + "B" * len(values), *values))

            if field.usage == "Position":
                xyz = list(values[:3])
                if min_values is None:
                    min_values = xyz[:]
                    max_values = xyz[:]
                else:
                    for axis in range(3):
                        min_values[axis] = min(min_values[axis], xyz[axis])
                        max_values[axis] = max(max_values[axis], xyz[axis])

        blob = b"".join(chunks)
        accessor = AccessorSpec(
            component_type=component_type,
            count=len(values_list),
            gltf_type=gltf_type,
            byte_offset=0,
            normalized=normalized,
            min_values=min_values,
            max_values=max_values,
        )
        return self._push_buffer_and_accessor(blob, 34962, accessor, raw_chunks, state)

    def _read_field_values(
        self,
        elf: ElfObject,
        vertex_buffer: int,
        vertex_count: int,
        vertex_stride: int,
        declaration: List[ShaderField],
        usage: str,
    ) -> Optional[List[Tuple[float, ...]]]:
        attr_offset = 0
        for field in declaration:
            fmt_info = self.TYPE_TO_FORMAT.get(field.decl_type)
            if fmt_info is None:
                continue
            if field.usage == usage:
                return self._read_field_values_from_offset(
                    elf,
                    vertex_buffer,
                    vertex_count,
                    vertex_stride,
                    attr_offset,
                    field,
                )
            attr_offset += fmt_info[1]
        return None

    def _read_field_values_from_offset(
        self,
        elf: ElfObject,
        vertex_buffer: int,
        vertex_count: int,
        vertex_stride: int,
        attr_offset: int,
        field: ShaderField,
    ) -> Optional[List[Tuple[float, ...]]]:
        fmt_info = self.TYPE_TO_FORMAT.get(field.decl_type)
        if fmt_info is None:
            return None
        fmt, size, _gltf_type, _component_type, _normalized = fmt_info
        values_list: List[Tuple[float, ...]] = []
        for i in range(vertex_count):
            off = vertex_buffer + attr_offset + i * vertex_stride
            if off + size > len(elf.data):
                return None
            values = struct.unpack_from(fmt, elf.data, off)
            if field.usage == "Color0":
                values = (values[2], values[1], values[0], values[3])
            if field.usage == "Normal":
                vec = values[:3]
                length = math.sqrt(sum(v * v for v in vec))
                if length > 0.0:
                    values = tuple(v / length for v in vec)
            values_list.append(tuple(values))
        return values_list

    def _dedupe_triangles(
        self,
        state: dict,
        shader_name: str,
        texture_name: Optional[str],
        indices: List[int],
        positions: Optional[List[Tuple[float, ...]]],
        texcoords0: Optional[List[Tuple[float, ...]]],
    ) -> List[int]:
        registry = state.get("_triangle_registry")
        if registry is None or positions is None:
            return indices

        deduped: List[int] = []
        for i in range(0, len(indices) - 2, 3):
            tri = indices[i : i + 3]
            signature = self._triangle_signature(shader_name, texture_name, tri, positions, texcoords0)
            if signature in registry:
                continue
            registry.add(signature)
            deduped.extend(tri)
        return deduped

    def _triangle_signature(
        self,
        shader_name: str,
        texture_name: Optional[str],
        tri: List[int],
        positions: List[Tuple[float, ...]],
        texcoords0: Optional[List[Tuple[float, ...]]],
    ) -> Tuple[object, ...]:
        if shader_name in {"ShadowTexture", "BlendedWithShadow", "BlendedOverlay"}:
            vertices: List[Tuple[float, ...]] = []
            for index in tri:
                pos = positions[index]
                vertices.append((round(pos[0], 4), round(pos[1], 4), round(pos[2], 4)))
            vertices.sort()
            return ("overlay_geo", tuple(vertices))

        vertices: List[Tuple[float, ...]] = []
        for index in tri:
            pos = positions[index]
            vertex_key = [round(pos[0], 5), round(pos[1], 5), round(pos[2], 5)]
            if texcoords0 is not None and index < len(texcoords0):
                uv = texcoords0[index]
                vertex_key.extend([round(uv[0], 5), round(uv[1], 5)])
            vertices.append(tuple(vertex_key))
        vertices.sort()
        return ("exact", texture_name or "", tuple(vertices))

    def _append_index_accessor(self, indices: List[int], raw_chunks: List[bytes], state: dict) -> int:
        max_index = max(indices)
        if max_index < 65536:
            component_type = 5123
            blob = struct.pack("<" + "H" * len(indices), *indices)
        else:
            component_type = 5125
            blob = struct.pack("<" + "I" * len(indices), *indices)
        accessor = AccessorSpec(component_type=component_type, count=len(indices), gltf_type="SCALAR", byte_offset=0)
        return self._push_buffer_and_accessor(blob, 34963, accessor, raw_chunks, state)

    def _push_blob(self, blob: bytes, target: Optional[int], raw_chunks: List[bytes], state: dict) -> int:
        buffer_view_index = len(state["bufferViews"])
        buffer_index = len(state["buffers"])
        raw_chunks.append(blob)
        buffer_view = {"buffer": buffer_index, "byteLength": len(blob)}
        if target is not None:
            buffer_view["target"] = target
        state["bufferViews"].append(buffer_view)
        state["buffers"].append({"byteLength": len(blob)})
        return buffer_view_index

    def _push_buffer_and_accessor(
        self,
        blob: bytes,
        target: Optional[int],
        accessor: AccessorSpec,
        raw_chunks: List[bytes],
        state: dict,
    ) -> int:
        buffer_view_index = self._push_blob(blob, target, raw_chunks, state)
        accessor_index = len(state["accessors"])
        access = {
            "bufferView": buffer_view_index,
            "componentType": accessor.component_type,
            "count": accessor.count,
            "type": accessor.gltf_type,
            "byteOffset": accessor.byte_offset,
        }
        if accessor.normalized:
            access["normalized"] = True
        if accessor.min_values is not None:
            access["min"] = accessor.min_values
        if accessor.max_values is not None:
            access["max"] = accessor.max_values
        state["accessors"].append(access)
        return accessor_index

    def _material_for(
        self,
        shader_name: str,
        texture_name: Optional[str],
        sampler_textures: Dict[int, str],
        state: dict,
        texture_assets: Dict[str, object],
        texture_map: Dict[Tuple[str, str], int],
        material_map: Dict[Tuple[object, ...], int],
        raw_chunks: List[bytes],
        out_path: Path,
        binary: bool,
    ) -> int:
        key = self._material_cache_key(shader_name, texture_name, sampler_textures)
        if key in material_map:
            return material_map[key]

        mat = {
            "name": shader_name if not texture_name else f"{shader_name} [{texture_name}]",
            "doubleSided": True,
            "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 1.0},
            "extensions": {"KHR_materials_specular": {"specularFactor": 0.0}},
        }
        state.setdefault("extensionsUsed", [])
        if "KHR_materials_specular" not in state["extensionsUsed"]:
            state["extensionsUsed"].append("KHR_materials_specular")

        mode = shader_texture_mode(shader_name)
        if mode == "shadow":
            mat["alphaMode"] = "BLEND"
            mat["pbrMetallicRoughness"]["baseColorFactor"] = [0.0, 0.0, 0.0, 1.0]
        elif (
            shader_name == "BlendedOverlay"
            and choose_material_texture(shader_name, sampler_textures) == sampler_textures.get(0)
            and sampler_textures.get(2)
        ):
            mat["alphaMode"] = "BLEND"

        if texture_name:
            texture_key = texture_name.lower()
            cache_key = self._material_texture_cache_key(texture_key, mode)
            tex_index = texture_map.get(cache_key)
            if tex_index is None:
                asset = texture_assets.get(texture_key)
                if asset is not None:
                    image_bytes, image_name = self._prepare_material_image(asset, mode)
                    if png_has_alpha(image_bytes):
                        mat["alphaMode"] = "BLEND"
                    sampler_index = len(state["samplers"])
                    state["samplers"].append(
                        {
                            "name": texture_name,
                            "magFilter": 9729,
                            "minFilter": 9729,
                            "wrapS": 10497,
                            "wrapT": 10497,
                        }
                    )
                    image_index = len(state["images"])
                    if binary:
                        buffer_view = self._push_blob(image_bytes, None, raw_chunks, state)
                        state["images"].append(
                            {
                                "name": image_name,
                                "mimeType": "image/png",
                                "bufferView": buffer_view,
                            }
                        )
                    else:
                        tex_dir = out_path.parent / f"{out_path.stem}_textures"
                        tex_dir.mkdir(parents=True, exist_ok=True)
                        tex_filename = f"{safe_name(image_name)}.png"
                        tex_path = tex_dir / tex_filename
                        if not tex_path.exists():
                            tex_path.write_bytes(image_bytes)
                        state["images"].append(
                            {
                                "name": image_name,
                                "mimeType": "image/png",
                                "uri": f"{tex_dir.name}/{tex_filename}",
                            }
                        )
                    tex_index = len(state["textures"])
                    state["textures"].append({"name": texture_name, "sampler": sampler_index, "source": image_index})
                    texture_map[cache_key] = tex_index
            if tex_index is not None:
                mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": tex_index}

        material_index = len(state["materials"])
        state["materials"].append(mat)
        material_map[key] = material_index
        return material_index

    def _material_cache_key(
        self,
        shader_name: str,
        texture_name: Optional[str],
        sampler_textures: Dict[int, str],
    ) -> Tuple[object, ...]:
        if shader_name == "BlendedOverlay":
            return (shader_name, texture_name, sampler_textures.get(1), sampler_textures.get(2))
        return (shader_name, texture_name)

    def _material_texture_cache_key(
        self,
        texture_key: str,
        mode: str,
    ) -> Tuple[str, str]:
        return (texture_key, mode)

    def _prepare_material_image(
        self,
        asset: object,
        mode: str,
    ) -> Tuple[bytes, str]:
        image_bytes, image_name = prepare_material_texture(asset, mode)
        return image_bytes, image_name

    def _resolve_texture_name(self, elf: ElfObject, global_parameters: int) -> Optional[str]:
        tar_ptr = elf.u32(global_parameters + 4)
        if tar_ptr == 0:
            return None

        if tar_ptr + 12 <= len(elf.data):
            tag = elf.bytes_at(tar_ptr + 4, 4)
            if tag and all(32 <= b < 127 for b in tag):
                return tag.decode("latin1", errors="ignore").strip("\x00")

        rel = elf.relocations.get(tar_ptr)
        if rel and rel.name.startswith("__EAGL::TAR:::"):
            attrs = rel.name[14:]
            if not attrs.startswith("RUNTIME_ALLOC"):
                return attrs
            match = re.search(r"SHAPENAME=([^,;]+)", attrs)
            if match:
                return match.group(1)
        return None

    def _primitive_mode_from_string(self, value: str) -> int:
        if "PT_POINTLIST" in value:
            return 0
        if "PT_LINELIST" in value:
            return 1
        if "PT_LINESTRIP" in value:
            return 3
        if "PT_TRIANGLELIST" in value:
            return 4
        if "PT_TRIANGLESTRIP" in value:
            return 5
        if "PT_TRIANGLEFAN" in value:
            return 6
        return 5

    def _read_indices(self, elf: ElfObject, offset: int, count: int, index_size: int, mode: int) -> List[int]:
        if index_size not in (1, 2, 4):
            return []
        values = []
        for i in range(count):
            off = offset + i * index_size
            if off + index_size > len(elf.data):
                break
            if index_size == 1:
                values.append(elf.u8(off))
            elif index_size == 2:
                values.append(elf.u16(off))
            else:
                values.append(elf.u32(off))

        if mode == 4:
            out: List[int] = []
            for f in range(0, len(values) // 3):
                a, b, c = values[f * 3 : f * 3 + 3]
                if a != b and a != c and b != c:
                    out.extend([a, c, b])
            return out
        if mode == 5:
            out = []
            for i in range(len(values) - 2):
                if i % 2 == 0:
                    a, b, c = values[i], values[i + 1], values[i + 2]
                else:
                    a, b, c = values[i], values[i + 2], values[i + 1]
                if a != b and a != c and b != c:
                    out.extend([a, c, b])
            return out
        if mode == 6:
            out = []
            for i in range(len(values) - 2):
                a, b, c = values[0], values[i + 1], values[i + 2]
                if a != b and a != c and b != c:
                    out.extend([a, c, b])
            return out
        return []
