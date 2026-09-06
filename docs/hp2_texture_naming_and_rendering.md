# HP2 texture naming and MTA rendering contract

## Authority

The single source of truth for every exported texture prefix is
`map_tools_ps2/src/map_tools_ps2/special_textures.py`.

It defines the namespace registry, descriptions, shader ownership, manifest
contract version, digest length and MTA name-length limit. The scene builder,
managed exporter and validator import this registry. Prefix strings must not be
duplicated in those modules.

## Complete prefix registry

| Namespace | Prefix | In `specialTextures` | Meaning | MTA renderer |
|---|---|---:|---|---|
| `default` | `hp2_` | No | Ordinary texture without a classified surface/effect role | GTA/MTA standard material |
| `road` | `road_` | No | Native ROAD, PUDDLE-base road family, rough road and related driveable surfaces | `eagl/shaders/road.fx` |
| `dirt` | `dirt_` | No | Native dirt and dirt-road family | GTA/MTA standard material |
| `grass` | `grass_` | No | Native grass and grass-shoulder family | GTA/MTA standard material |
| `reflection` | `refl_` | Yes | Puddle/wet-surface reflection layer proven by native face material | `eagl/shaders/reflection.fx` |
| `uv_scroll` | `uvscroll_` | Yes | TPK-authored U/V translation | `eagl/shaders/uv_scroll.fx` |
| `uv_rotate` | `uvrotate_` | Yes | TPK-authored UV rotation interface | `eagl/shaders/uv_rotate.fx` |
| `texture_animation` | `texanim_` | Yes | TextureAnimPack frame animation | `eagl/shaders/texture_animation.fx` |
| `model_animation` | `modelanim_` | Yes | Dominant texture on a model/vertex-animated part | `eagl/shaders/model_animation.fx` |

`uvrotate_` is currently reserved: the 30-track audit found no source-confirmed
HP2 texture using rotation. It remains in the public contract for future data.

Normal alpha, vegetation cutout, additive-only materials and skyboxes do not
receive special prefixes merely because of their appearance.

## Canonical name format and limits

Managed names use:

```text
<registered-prefix><first 20 hex characters of identity SHA-256>
```

RenderWare/MTA provides a 32-byte texture-name field. The exporter permits at
most 31 visible ASCII characters, reserving one byte for the null terminator.
The current longest form is `modelanim_` plus 20 hex characters: 30 characters.

Examples:

```text
road_1110e1156abfa55d5717
refl_4893a53645aa66045640
uvscroll_858bb7562aa7794816c7
texanim_f8c9190bd559a42f1763
modelanim_f84848d268447364f479
```

The original source name is diagnostic metadata only. It is never the managed
canonical identity.

## Identity and collision protection

The identity digest includes all data that can change rendering semantics:

- decoded pixel SHA-256, width and height;
- exported alpha mode and cutoff;
- surface namespace;
- special effect role;
- UV descriptor flags and U/V or rotation parameters;
- texture-animation phase, FPS and ordered frame digests.

Consequently identical pixels used as an ordinary road, reflection layer or UV
animation generate independent variants. Identical pixels with different UV
speeds also remain independent.

The exporter rejects:

- canonical names longer than 31 visible characters;
- one canonical name mapping to two full identities;
- one internal synthetic hash mapping to two full identities;
- duplicate IMG entries;
- missing DFF texture references or a TXD texture set different from the staged mapping.

## Source-backed classification

Classification never searches for words such as `PUDDLE`, `RIVER` or
`WINDMILL` in source names.

### Reflection

A triangle becomes `refl_*` only when it spatially binds to an original HP2
`PUDDLE` (material 4) or `MUD_PUDDLE` (material 20) collision face and its
source material has BLEND semantics. Multi-use source textures are split so
ordinary faces keep their normal namespace.

The exported reflection material is opaque and does not set `draw_last`,
`additive` or `no_zbuffer_write`. Its original alpha pixels remain in the TXD
as the shader reflection mask.

Reflection records also carry a `reflectionLayer` of `surface` or `mask`.
This distinction is derived from decoded raster channel statistics: a black
control raster, or a near-grayscale raster whose luminance is strongly
anti-correlated with alpha, is a mask. Texture names are not consulted. HP2's
mask polarity is inverse alpha: high alpha excludes dry road, while low alpha
selects reflective puddle coverage.

### UV animation

TPK entry offset `0x78`, bit `0x100`, enables the source UV descriptor. Floats
at `0x7c` and `0x80` provide U and V translation rates. For example:

```text
RIVER_BOTTOM / 0x04c80a1b
uvscroll_858bb7562aa7794816c7
U = 0, V = -0.390625
```

### Texture animation

`TextureAnimPack` metadata and frame chunks provide ordered frame hashes, FPS
and phase. The barrier-arrow sequence is four frames at 4 FPS; each phase has
its own `texanim_*` canonical identity.

### Model animation

The eModel header flag `0x10` is the source controller evidence. Only the
motion object's dominant texture is marked, selected by cumulative triangle
area with texture-slot order as the tie-breaker. A `0x3401d` chunk alone is not
an animation criterion.

## Manifest interface

Every family `track_manifest.json` keeps its existing fields and adds:

```json
{
  "specialTextures": {
    "version": 1,
    "file": "special_textures.json",
    "prefixes": {
      "reflection": "refl_",
      "uv_scroll": "uvscroll_",
      "uv_rotate": "uvrotate_",
      "texture_animation": "texanim_",
      "model_animation": "modelanim_"
    }
  }
}
```

Each `special_textures.json` record contains its canonical name, kind, prefix,
source name/hash, family/tracks, object/material/submesh/slot bindings, source
evidence, source/export alpha state and effect parameters or animation frames.

The 30-track aggregate is written to:

```text
map_tools_ps2/out/special_textures.json
map_tools_ps2/out/special_textures.md
```

## Standalone MTA renderer

The client resource is:

```text
D:\dev\mta_hp2\mods\deathmatch\resources\[render]\eagl
```

It has no `roadshine` or `sslr` resource dependency. Starting `eagl` applies:

- road specular to `road_*`;
- a visible water-surface pass to `refl_*`, plus MRT depth/mask capture only
  for generated canonical `reflectionMask` identities;
- exact manifest U/V rates to all current `uvscroll_*` names;
- the reserved rotation shader to `uvrotate_*`;
- manifest FPS/phase/frame textures to `texanim_*`, including barrier arrows;
- shader-side vertex motion to `modelanim_*`.

`eagl/special_textures.lua` is the deployed runtime registry generated from the
five family JSON manifests. It keys only on canonical names. Animation images
remain declared files of the active family pack and are read using MTA's
cross-resource `:resource/path` syntax; `eagl` does not start or depend on the
legacy render resources.

### Modular pipeline

`eagl/main.lua` contains only the four MTA lifecycle adapters: pipeline start,
per-frame update, HUD-stage render and shutdown. `pipeline/core.lua` owns the
module registry and deterministic priority ordering.

The built-in modules live only in `eagl/render/` and mirror the parent
`[render]` responsibilities. The obsolete `eagl/modules/` implementation was
removed:

| Module | Priority | Responsibility |
|---|---:|---|
| `skybox` | 5 | Registration slot for the track-loader-owned sky implementation |
| `roadshine` | 10 | `road_*` lighting |
| `uv_animation` | 20 | `uvscroll_*` and `uvrotate_*` transforms |
| `model_animation` | 20 | `modelanim_*` vertex motion |
| `reflection` | 30 | `refl_*` MRT depth/mask capture and SSLR composite |
| `barrier_fx` | 40 | `texanim_*` frame playback, including barrier arrows |

A module registers a table containing a unique `id` and any of `start`,
`update`, `render` and `stop`. Registration while the pipeline is running
starts the module immediately. Unregistration stops it and destroys every MTA
element it owns. Shader/texture allocation goes through the pipeline helpers,
so a plug-in cannot leak elements during normal shutdown.

```lua
EAGLPipeline.register({
    id = "example",
    priority = 50,
    start = function(self, context) return true end,
    update = function(self, context) end,
    render = function(self, context) end,
    stop = function(self, context) end,
})
```

`EAGLPipeline.unregister("example")` hot-removes it. New modules are loaded by
adding their client script before `main.lua` in `eagl/meta.xml`; `main.lua`
never needs modification.

### Render-state guarantees

Every world shader binds MTA texture stage 0 using the `textureState`
annotation and requests generated normals for models that omit them. A failed
primary shader technique is rejected and cleaned up, leaving the original
material visible. `road_*` keeps its diffuse colour and receives only the
legacy greyness-weighted specular term. `uvscroll_*` and `uvrotate_*` preserve
the sampled diffuse texture while changing UV coordinates. `refl_*` uses an
MRT depth/mask capture and a view/world-correct SSLR composite at the high HUD
render stage. `texanim_*` uses source-alpha blending rather than additive
`ONE + ONE`, preventing barrier arrows from becoming over-bright.

The reflection DFF material state and TXD raster format are intentionally
independent. The DFF/IDE side stays `OPAQUE` with no transparent definition
flags, while the `refl_*` raster keeps its authored source alpha in DXT5.
Decoded raster statistics classify surface and mask roles during export and
the generated canonical mask set is consumed by EAGL. At runtime only those
mask identities write depth/coverage MRTs; their black RGB is suppressed from
the scene colour. Their alpha is inverted and contrast-expanded to recover the
authored puddle coverage. Coloured-water identities only render the base water
surface and therefore cannot turn the complete coincident road polygon into a
mirror.

Reflection-bearing road geometry can contain coincident coloured-water and
black-mask material layers. EAGL keeps the coloured layer at useful opacity,
suppresses black mask RGB, and uses the latter only for coverage/roughness.
SSLR is a low-energy secondary lobe (`0.18` capture strength), with source-alpha
gradient distortion and a five-tap blur; it is not the base surface colour.

When a coloured surface and control layer have coincident triangles and
identical UVs, the generated runtime registry pairs their canonical identities.
EAGL bundles the decoded mask raster and `reflection_surface.fx` samples it to
clip the coloured layer before the SSLR composite. Thus the colour raster
cannot cover the dry part of the road even though the original DFF material is
opaque. A mask with no spatial alpha variation uses its authored puddle
geometry directly rather than inventing coverage from a constant channel.

The DX9/MTA composite keeps the source SSLR implementation's fixed,
branch-free 20-iteration ray march. Adding `break` together with `[loop]`
causes effect-compiler errors X3526 and X3531 because depth sampling requires
implicit gradients; both constructs are forbidden in this shader contract.

HP2 UV-scroll values describe texture-transform translation. EAGL therefore
subtracts the authored velocity during texture sampling; directly adding it
would visually move the texture in the opposite direction.

## Adding a namespace or shader effect

1. Add the namespace once to `TEXTURE_NAMESPACES` in `special_textures.py`.
2. Add source-backed parsing/classification evidence; never add a name regex.
3. Include every rendering parameter in `texture_key` identity.
4. Add manifest fields and regenerate `eagl/special_textures.lua` if the effect
   needs per-canonical runtime parameters.
5. Add the matching shader/application rule to `eagl`.
6. Run the Python suite, five-family managed validator, name/collision audit and
   staging-versus-deployment SHA-256 comparison before deployment.

## Current verified inventory

The deployed 30-track build contains 53 per-family special records:

| Effect | Records |
|---|---:|
| Reflection | 8 |
| UV scroll | 20 |
| UV rotation | 0 |
| Texture animation | 24 |
| Model animation | 1 |

Four texture-animation canonical names intentionally repeat across all five
family packs because those packs embed the same global animation frames and
identical effect identity. Within every family, canonical names are unique.
