from __future__ import annotations

from io import BytesIO
from typing import Dict, List, Optional, Tuple

from PIL import Image

from ..models import TextureAsset


def choose_material_texture(shader_name: str, sampler_textures: Dict[int, str]) -> Optional[str]:
    if not sampler_textures:
        return None
    if shader_name in {"ShadowTexture", "BlendedWithShadow", "BlendedOverlay"} and 1 in sampler_textures:
        return sampler_textures[1]
    return sampler_textures.get(0) or next(iter(sampler_textures.values()))


def shader_texture_mode(shader_name: str) -> str:
    return "base"


def build_shadow_mask(png_bytes: bytes) -> bytes:
    src = Image.open(BytesIO(png_bytes)).convert("RGBA")
    out = Image.new("RGBA", src.size, (0, 0, 0, 0))
    src_px = src.load()
    out_px = out.load()
    width, height = src.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = src_px[x, y]
            luminance = (r + g + b) / 3.0
            alpha = int(max(0.0, min(255.0, (255.0 - luminance) * (a / 255.0))))
            out_px[x, y] = (0, 0, 0, alpha)
    buf = BytesIO()
    out.save(buf, format="PNG")
    return buf.getvalue()


def prepare_material_texture(asset: TextureAsset, mode: str) -> Tuple[bytes, str]:
    if mode != "shadow":
        return asset.png_bytes, asset.name
    return build_shadow_mask(asset.png_bytes), f"{asset.name}_shadow"


def png_has_alpha(png_bytes: bytes) -> bool:
    image = Image.open(BytesIO(png_bytes)).convert("RGBA")
    alpha_min, _alpha_max = image.getchannel("A").getextrema()
    return alpha_min < 255


def sample_alpha_at_uvs(png_bytes: bytes, uvs: List[Tuple[float, ...]]) -> List[int]:
    image = Image.open(BytesIO(png_bytes)).convert("RGBA")
    width, height = image.size
    alpha = image.getchannel("A")
    values: List[int] = []
    for uv in uvs:
        u = uv[0] % 1.0
        v = uv[1] % 1.0
        x = int(u * (width - 1) + 0.5)
        y = int(v * (height - 1) + 0.5)
        values.append(alpha.getpixel((x, y)))
    return values
