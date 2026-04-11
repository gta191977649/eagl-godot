# PS2 BUN / LZC Track Bundle Notes

This document describes the observed binary structure of Need for Speed: Hot Pursuit 2 PS2 track bundles from:

```text
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS
```

It is written for follow-up reverse engineering work. Treat the `COMP` wrapper and EA chunk container as confirmed. Treat the object-pack and VIF mesh notes as working hypotheses that currently produce usable experimental OBJ output, but still need validation against the PS2 render path.

## Files

Observed track payload files:

```text
TRACKB##.LZC       compressed COMP / ea_comp bundle
TRACKB##.BUN       decompressed bundle for some routes only
TRACKA##.BUN       present but 0 bytes in the inspected data set
TEX##TRACK.BIN     texture bundle data
TEX##LOCATION.BIN  larger location texture bundle data
```

The converter currently focuses on `TRACKB##.LZC` / `TRACKB##.BUN`.

Validation performed:

- All 30 `TRACKB*.LZC` files decompressed successfully.
- The 8 non-empty decompressed fixtures matched byte-for-byte:
  - `TRACKB24.LZC -> TRACKB24.BUN`
  - `TRACKB25.LZC -> TRACKB25.BUN`
  - `TRACKB26.LZC -> TRACKB26.BUN`
  - `TRACKB44.LZC -> TRACKB44.BUN`
  - `TRACKB45.LZC -> TRACKB45.BUN`
  - `TRACKB46.LZC -> TRACKB46.BUN`
  - `TRACKB65.LZC -> TRACKB65.BUN`
  - `TRACKB66.LZC -> TRACKB66.BUN`

## COMP / LZC Wrapper

`TRACKB##.LZC` starts with a 16-byte `COMP` header followed by an `ea_comp` payload. All integer fields are little-endian.

```c
typedef struct Hp2CompHeader {
    char     magic[4];             /* "COMP" */
    uint32_t flags;                /* observed 0x00001001 */
    uint32_t decompressed_size;    /* output BUN size */
    uint32_t compressed_size;      /* full LZC file size, includes this header */
    uint8_t  payload[];            /* ea_comp stream starts at file offset 0x10 */
} Hp2CompHeader;
```

Example from `TRACKB24.LZC`:

```text
00000000: 43 4f 4d 50 01 10 00 00 bc 81 96 00 66 33 5b 00
          "COMP"    flags=0x1001 size=0x009681bc csize=0x005b3366
```

`compressed_size` was observed to include the 16-byte header. The payload length passed to `ea_comp` is therefore:

```c
payload_size = header.compressed_size - 0x10;
```

## ea_comp Payload

The `COMP` body uses EA's `ea_comp` LZ variant, not RefPack. This is equivalent to QuickBMS `comtype ea_comp` with a 0x10-byte wrapper skip.

Confirmed decoder behavior:

```c
int hp2_ea_comp_decode(const uint8_t *in, int insz, uint8_t *out, int outsz) {
    const uint8_t *in_end = in + insz;
    uint8_t *o = out;
    uint8_t *out_end = out + outsz;
    uint32_t flags = 1;

    while (in < in_end && o < out_end) {
        if (flags == 1) {
            flags = (uint32_t)in[0] | ((uint32_t)in[1] << 8) | 0x10000u;
            in += 2;
        }

        int cycles = ((in_end - 32) < in) ? 1 : 16;
        while (cycles-- && in < in_end && o < out_end) {
            if (flags & 1) {
                uint8_t control = in[0];
                uint32_t distance = (uint32_t)in[1] | ((uint32_t)(control & 0xf0) << 4);
                uint32_t length = (control & 0x0f) + 3;
                const uint8_t *copy = o - distance;
                in += 2;

                while (length-- && o < out_end) {
                    *o++ = *copy++;
                }
            } else {
                *o++ = *in++;
            }
            flags >>= 1;
        }
    }

    return (int)(o - out);
}
```

Important details:

- The 16-bit flag word is little-endian.
- The decoder ORs the flag word with `0x10000`; this makes `flags == 1` a refill sentinel after 16 shifts.
- A set flag bit means back-reference. A clear bit means literal.
- Back-reference distance is `in[1] | ((control & 0xf0) << 4)`. There is no `+1` distance adjustment in this codec.
- Back-reference length is `(control & 0x0f) + 3`.

## Decompressed BUN Chunk Container

After decompression, `.BUN` is an EA chunk stream. All chunk headers are little-endian:

```c
typedef struct EaChunkHeader {
    uint32_t id;
    uint32_t size;       /* payload size only, does not include this 8-byte header */
    uint8_t  payload[];
} EaChunkHeader;
```

Chunk walking:

```c
uint32_t end = chunk_offset + 8 + header.size;
bool is_parent = (header.id & 0x80000000u) != 0;

if (is_parent) {
    /* payload is another EaChunkHeader stream ending at `end` */
} else {
    /* payload is raw data */
}
```

There is no observed alignment padding outside `size`; the next chunk starts at `offset + 8 + size`.

## Observed Top-Level Chunk Families

The following chunk ids appear in `TRACKB24.BUN` and/or match the `NFS-ModTools` chunk names:

```c
enum Hp2ChunkId {
    BCHUNK_SPEED_EMTRIGGER_PACK        = 0x80036000,
    BCHUNK_SPEED_WEATHERMAN            = 0x00034250,
    BCHUNK_SPEED_ESOLID_LIST_CHUNKS    = 0x80034000, /* PS2 uses 0x80034000 here */
    BCHUNK_SPEED_SCENERY_SECTION       = 0x80034100,
    BCHUNK_TRACKPATHMANAGER            = 0x80034147,
    BCHUNK_SPEED_SMOKEABLE_SPAWNER     = 0x00034027,
    BCHUNK_SPEED_TRACKROUTE_MANAGER    = 0x00034121,
    BCHUNK_SPEED_TRACKROUTE_SIGNPOSTS  = 0x00034122,
    BCHUNK_SPEED_TOPOLOGYTREE_A        = 0x00034130,
    BCHUNK_SPEED_TOPOLOGYTREE_B        = 0x00034131,
    BCHUNK_SPEED_TOPOLOGYTREE_C        = 0x00034132,
    BCHUNK_SPEED_TOPOLOGYTREE_D        = 0x00034133,
    BCHUNK_SPEED_CAMERA_PACK           = 0x80034405,
    BCHUNK_SPEED_CAMERA_LIST           = 0x80034425,
    BCHUNK_SPEED_ELIGHT_CHUNKS         = 0x80034500,
};
```

Example start of `TRACKB24.BUN`:

```text
0x00000000 0x80036000 size=0x00011718
  0x00000008 0x00036001 size=0x00000018
  0x00000028 0x00036002 size=0x0000b680
  0x0000b6b0 0x00036003 size=0x00006068
...
0x0005dfc0 0x80034000 size=0x001f3748
  0x0005dfc8 0x00034001 size=0x00000034
  0x0005e004 0x80034002 size=0x00016214
    0x0005e00c 0x00034003 size=0x000000cc
    0x0005e0e0 0x00034006 size=0x00000030
    0x0005e118 0x0003401d size=0x00000008
    0x0005e128 0x00034004 size=0x00002180
    0x000602b0 0x00034005 size=0x00013f68
```

Note: later Black Box PC-era `NFS-ModTools` code expects some object-list chunks at `0x80134000` / platform parent `0x80134100`. The PS2 HP2 track bundles inspected here use `0x80034000` list containers and `0x80034002` object containers, with PS2 VIF data in `0x00034005`.

## Object Pack Chunks

Working object-pack interpretation:

```c
enum Hp2ObjectChunkId {
    HP2_OBJ_LIST             = 0x80034000,
    HP2_OBJ_LIST_NAME        = 0x00034001,
    HP2_OBJ                 = 0x80034002,
    HP2_OBJ_HEADER           = 0x00034003,
    HP2_OBJ_VERTEX_META      = 0x00034004, /* inferred */
    HP2_OBJ_VIF_STREAM       = 0x00034005,
    HP2_OBJ_HASHES_OR_TEX    = 0x00034006, /* inferred */
    HP2_OBJ_EXTRA_HASH       = 0x0003401d, /* inferred, optional */
};
```

### `0x00034001` Object List Name

Payload is a null-terminated path-like ASCII string padded to the chunk size.

Example:

```text
TRACK24\Pipeline\Scenery\eLabScenery0.bin
```

Approximate structure:

```c
typedef struct Hp2ObjectListName {
    char path[]; /* null-terminated, chunk-size bounded */
} Hp2ObjectListName;
```

### `0x80034002` Object Container

This parent chunk usually contains:

```text
0x00034003  object header / name / bounds / matrix
0x00034006  small u32 pairs, likely hashes or texture ids
0x0003401d  optional small data, observed size 8 or 16
0x00034004  vertex metadata or command metadata
0x00034005  VIF packet stream containing vertex data
```

Not every object has `0x0003401d`.

### `0x00034006` Texture Hash List

This chunk is now confirmed to contain texture hashes that match `TEX##LOCATION.BIN` and `TEX##TRACK.BIN` entries. The observed payload is a sequence of 8-byte records:

```c
typedef struct Hp2ObjectTextureRef {
    uint32_t tex_hash;
    uint32_t zero_or_flags; /* observed 0 in the simple hash-list cases */
} Hp2ObjectTextureRef;
```

Example matches from `TRACKB24.BUN` against `TEX24LOCATION.BIN`:

```text
0xfea6e3f6 -> HELI_ROTOR
0xbcd243b8 -> HELI_WINDOW
0xb9dda923 -> HELICOPTERSKIN
```

The current GLB exporter uses these hashes to choose embedded materials. When a `0x00034004` table is present, each VIF run uses the metadata `texture_index` into this hash list. Objects without metadata still fall back to hash-list order clamped to the last available hash.

### `0x00034003` Object Header

This chunk is partly decoded. The ASCII name starts at either `0x10` or `0x1c` in inspected samples. Once the name start is known, the current converter reads a 4x4 transform matrix at:

```c
matrix_offset = name_start + 0x50;
```

Working layout:

```c
typedef struct Hp2ObjectHeaderPrefix {
    uint32_t unk00;
    uint32_t unk04;
    uint32_t unk08;     /* often 0x11111111 in first object of list */
    uint32_t unk0c;
    uint32_t unk10;     /* may be name bytes if name starts at 0x10 */
    /* variable fields and null-terminated object name */
} Hp2ObjectHeaderPrefix;

typedef struct Hp2ObjectHeaderTail {
    float bounds_min_or_center[4]; /* inferred, visible near name_start + 0x24 */
    float bounds_max_or_extent[4]; /* inferred */
    float matrix[4][4];            /* confirmed useful transform at name_start + 0x50 */
} Hp2ObjectHeaderTail;
```

Examples:

```text
Object at 0x0005e004:
  0x34003 name = "TRACK_HELICOPTER"
  name_start  = 0x1c
  matrix      = identity at payload offset 0x6c

Object at 0x00074220:
  0x34003 name = "TRN20_MINE_BRACE06"
  name_start  = 0x10
  matrix      = non-identity at payload offset 0x60
```

The matrix is applied row-vector style by the current converter:

```c
out.x = x * m[0][0] + y * m[1][0] + z * m[2][0] + m[3][0];
out.y = x * m[0][1] + y * m[1][1] + z * m[2][1] + m[3][1];
out.z = x * m[0][2] + y * m[1][2] + z * m[2][2] + m[3][2];
```

### `0x00034004` Vertex Metadata

This chunk is a per-run draw metadata table for objects that also carry a `0x00034005` VIF stream.

Observed characteristics:

- Some payloads begin with two `0x11111111` words.
- After the 8-byte prefix, inspected `TRACKB24` payloads use one 0x40-byte record per decoded VIF run.
- The `0x11111111` prefix is optional. Many `0x00034004` chunks start directly with the first 0x40-byte record.
- Across all 30 `TRACKB*.LZC` files, the record count matched the decoded VIF run count for 27,926 object containers / 308,589 records.
- Record `uint32_t word00` is a zero-based index into the object's `0x00034006` texture hash list.
- Record `uint32_t word02` matches the byte offset of the matching run in the `0x00034005` VIF stream, after skipping the optional `0x11111111` prefix.
- Record `uint32_t word03` low 16 bits are the VIF run size in 16-byte qwords. This matched every decoded VIF run across the 30-track scan. The high 16 bits are render/format flags; common values are `0x0000`, `0x4041`, `0x1000`, `0x4080`, `0x4180`, `0xc180`, and `0x4100`.
- Record `uint32_t word07` packs a material/render byte in byte 0, the VIF vertex count in byte 1, an unknown count-like byte in byte 2, and either `0xff` or `0x00` in byte 3. Byte 0 is not always the same as `word00` texture index; for example, some vehicle runs store `word00 == 1` and packed byte 0 as `2`. Byte 2 is often lower than `vertex_count - 2`, but it is not a simple "emit the first N strip triangles" count; using it that way creates visible holes in terrain and sky-dome meshes.

Working structure:

```c
typedef struct Hp2Ps2RunMetadata {
    uint32_t texture_index;    /* index into 0x00034006 hash list */
    uint32_t unknown04;        /* often 0x80008000 */
    uint32_t vif_run_offset;   /* offset into 0x00034005 stream, after prefix */
    uint16_t vif_qwords;       /* low half of word03: run byte size / 16 */
    uint16_t render_flags;     /* high half of word03 */
    float    bounds_min[3];    /* inferred from inspected terrain/scenery samples */
    uint8_t  packed_material_or_render_index; /* not always texture_index */
    uint8_t  vertex_count;
    uint8_t  unknown_count;    /* not a simple strip triangle count */
    uint8_t  packed_ff_or_zero; /* usually 0xff; 0x00 on some objects */
    float    bounds_max[3];    /* inferred */
    uint32_t zero2c;
    uint8_t  unknown30[0x10];  /* extra flags/render metadata; not fully mapped */
} Hp2Ps2RunMetadata;
```

Example from `TRACKB24`, object `RDDRT_SECTION40_CHOP4`:

```text
0x00034006 hashes:
  0 DIRT02
  1 DIRT_GRASS_CORNER
  2 DIRT_GRASS_HORIZONTAL
  3 DIRT_GRASS_VERTICAL
  4 DIRT_ROCKY
  5 DIRTROAD-SHOULDER_256
  6 DIRTROAD01

0x00034004 texture_index sequence:
  runs 0..48   -> 0
  run 49       -> 1
  run 50       -> 2
  run 51       -> 3
  run 52       -> 4
  runs 53..67  -> 5
  runs 68..73  -> 6
```

The GLB exporter uses this mapping when present. The OBJ exporter is still position/topology-only.

### `0x00034005` VIF Stream

This chunk contains PS2 VIF packet data. The current converter decodes enough of it to extract positions.

Observed pattern:

```text
11 11 11 11 11 11 11 11   optional stream prefix
00 80 01 6e               UNPACK V4_8? header/control row
...
02 c0 NN 6c               UNPACK V4_32 position rows to VU memory around 0xc002
...
20 c0 NN 6c               UNPACK V4_32 UV/color/other rows to VU memory around 0xc020
...
34 c0 NN 6f               UNPACK V4_5 packed color/normal-style data to VU memory around 0xc034
...
14 00 00 00               MSCAL or run terminator in this stream
```

VIF command word is little-endian:

```c
typedef struct Ps2VifCommand {
    uint16_t imm;
    uint8_t  num;
    uint8_t  cmd;
} Ps2VifCommand;
```

Useful VIF `UNPACK` command sizes for this data:

```c
static uint32_t hp2_vif_unpack_payload_size(uint8_t cmd, uint8_t num) {
    switch (cmd) {
        case 0x60: return num * 4;               /* S_32 */
        case 0x61: return (num * 2 + 3) & ~3;    /* S_16 */
        case 0x62: return (num + 3) & ~3;        /* S_8 */
        case 0x64: return num * 8;               /* V2_32 */
        case 0x65: return num * 4;               /* V2_16 */
        case 0x66: return (num * 2 + 3) & ~3;    /* V2_8 */
        case 0x68: return num * 12;              /* V3_32 */
        case 0x69: return (num * 6 + 3) & ~3;    /* V3_16 */
        case 0x6a: return (num * 3 + 3) & ~3;    /* V3_8 */
        case 0x6c: return num * 16;              /* V4_32 */
        case 0x6d: return num * 8;               /* V4_16 */
        case 0x6e: return num * 4;               /* V4_8 */
        case 0x6f: return (num * 2 + 3) & ~3;    /* V4_5 */
        default:   return 0;                     /* not an UNPACK command */
    }
}
```

Working position extraction rule:

```c
if (imm >= 0xc002 && imm < 0xc020 &&
    (cmd == 0x60 || cmd == 0x64 || cmd == 0x68 || cmd == 0x6c)) {
    /* Interpret payload as float rows. */
}
```

Rows are assembled into vertices in groups of three:

```c
/* Example for V4_32 rows:
   row0 = x lane values
   row1 = y lane values
   row2 = z lane values

   vertices:
     (row0[0], row1[0], row2[0])
     (row0[1], row1[1], row2[1])
     (row0[2], row1[2], row2[2])
     (row0[3], row1[3], row2[3])
 */
```

`UNPACK 0x6e` with `imm == 0x8000` and `num == 1` is treated as the start of a new vertex run:

```c
typedef struct Hp2VifRunHeader {
    uint8_t vertex_count_or_limiter; /* used by converter to trim decoded vertices when non-zero */
    uint8_t unk1;
    uint8_t unk2;
    uint8_t unk3;
} Hp2VifRunHeader;
```

This header interpretation is inferred. It gives plausible run lengths on inspected objects, but needs PS2 render-code validation.

`cmd == 0x14` is treated by the converter as a run terminator. On PS2 VIF this is an MSCAL-family command; exact semantics in this stream still need mapping.

## Experimental OBJ Topology

The current OBJ/GLB exporters turn each decoded VIF vertex run into a full triangle strip:

```c
for (int i = 0; i < vertex_count - 2; i++) {
    int a = base + i;
    int b = base + i + 1;
    int c = base + i + 2;

    if (i & 1) emit_face(a, c, b);
    else       emit_face(a, b, c);
}
```

Limitations:

- Degenerate strip breaks are only filtered when all three indices are not unique.
- VIF `V4_5` data at `imm 0xc034` is not interpreted yet. In inspected terrain runs it behaves like packed color/normal-style data rather than an obvious strip-break table.
- The `0x00034004` packed count-like byte is not a simple global strip cap, but it is still useful as a topology hint on some runs. The current GLB exporter now promotes exact `vertex_count / 3` matches to triangle lists and exact `vertex_count / 2` matches on 4-vertex batches to quad-style two-triangle groups when those layouts score better than a strip on the decoded geometry, and it now splits obviously stitched strip runs at inferred restart boundaries when keeping them as one strip creates large bridge triangles.
- OBJ output is still position/topology-only. GLB output emits materials, texture ids, and UVs, but normals and packed colors are not emitted yet.
- Remaining `0x00034004` fields may contain topology/render metadata that should further refine the simple strip rule.

## PS2 TPK Texture Bins

The inspected `TEX##TRACK.BIN` and `TEX##LOCATION.BIN` files are PS2 texture packs with a `0xb0300001` parent chunk:

```text
0xb0300001
  0x30300002  pack info / path
  0x30300003  texture entry table
  0x30300004  palette and image data
0xb0300100    animation table, usually small/empty in inspected files
```

The `0x30300003` table uses 0xa4-byte entries in the inspected HP2 PS2 data:

```c
typedef struct Hp2Ps2TextureEntry {
    uint32_t zero00;
    uint32_t zero04;
    char     name[24];
    uint32_t tex_hash;
    uint16_t width;
    uint16_t height;
    uint8_t  format_info[8];   /* partially decoded; first byte often 4 or 8 */
    uint32_t data_offset;      /* relative to aligned 0x30300004 data base */
    uint32_t palette_offset;   /* relative to aligned 0x30300004 data base */
    uint32_t data_size;
    uint32_t palette_size;     /* observed 0x40, 0x80, or 0x400 */
    uint8_t  unknown40[0x64];
} Hp2Ps2TextureEntry;
```

The `0x30300004` payload is aligned before offsets are applied:

```c
uint32_t data_base = align_up(chunk_30300004_payload_file_offset, 0x80);
uint8_t *image   = file + data_base + entry.data_offset;
uint8_t *palette = file + data_base + entry.palette_offset;
```

Decoded texture cases:

- `palette_size == 0x40`: 4-bit indexed texture, 16 RGBA palette entries. Full-page-or-larger images use PS2 PSMT4 index unswizzle. Sub-page images (`width < 128` or `height < 128`) are stored as linear low-nibble-first 4-bit indices in inspected files.
- `palette_size == 0x80`: 8-bit indexed texture with a 32-entry RGBA palette block. The inspected `TEX24LOCATION.BIN` billboard entries decode correctly by treating the top mip level as PSMT8 indices and using the 32 palette entries without palette-block swizzle.
- `palette_size == 0x400`: 8-bit indexed texture, 256 RGBA palette entries, with the common 8-bit palette block unswizzle. Full-page-or-larger images use PS2 PSMT8 index unswizzle. Sub-page images (`width < 128` or `height < 64`) are stored as linear 8-bit indices in inspected files.

Palette alpha is converted with:

```c
alpha8 = ps2_alpha >= 0x7f ? 255 : min(ps2_alpha * 2, 255);
```

The GLB exporter embeds decoded textures as PNG buffer views. Near-opaque alpha (`>= 250`) is treated as opaque for GLB material state. Textures with only fully transparent cutout pixels use `alphaMode = MASK`; textures with intermediate alpha use `alphaMode = BLEND`.

## Minimal Decode Pipeline

For another agent continuing the work, the current pipeline is:

```text
1. Read TRACKB##.LZC.
2. Verify COMP header.
3. Decompress payload at offset 0x10 with ea_comp.
4. Parse decompressed bytes as recursive EA chunks.
5. Walk 0x80034000 object lists.
6. For each 0x80034002 object:
   a. Read 0x00034003 name and transform.
   b. Read 0x00034005 VIF stream.
   c. Decode position rows from VIF UNPACK commands around imm 0xc002..0xc01f.
   d. Decode UV float rows from VIF UNPACK commands around imm 0xc020..0xc033.
   e. Read texture hashes from 0x00034006.
   f. Read per-run texture indices from 0x00034004 when present.
   g. Apply 0x34003 matrix.
   h. Export each run as a triangle strip.
7. For GLB:
   a. Load TEX##LOCATION.BIN and TEX##TRACK.BIN.
   b. Unswizzle and decode indexed PS2 textures to PNG.
   c. Bind materials with 0x00034004 run texture indices into the 0x00034006 texture hash list.
```

Current implementation files:

```text
src/map_tools_ps2/comp.py       COMP / ea_comp decoder
src/map_tools_ps2/chunks.py     EA chunk parser
src/map_tools_ps2/vif.py        experimental VIF vertex-run extraction
src/map_tools_ps2/model.py      object chunk mapping and transform application
src/map_tools_ps2/obj_writer.py experimental OBJ output
src/map_tools_ps2/textures.py   experimental PS2 TPK texture decoder
src/map_tools_ps2/glb_writer.py experimental GLB output with embedded PNGs
```

## Open Questions

- Exact `0x00034003` header structure before and after the object name.
- Remaining fields inside each `0x00034004` per-run metadata record.
- Exact role of `0x0003401d`.
- Per-run material selection for objects that do not carry a `0x00034004` table.
- Exact meaning of the `V4_5` data at `imm 0xc034`; current evidence points away from it being the primary strip-break table.
- Exact meaning of the `0x00034004` packed byte at record offset `0x1e`; it is count-like but not a simple triangle-count cap.
- Whether `0x14` is always the correct run terminator for this data.
- Whether the current `0xc020..0xc033` UV extraction needs V flipping, scale/bias, or extra wrap-state handling.
- How normals and colors map to the mesh.
- Whether all `0x80034002` object containers should be exported, or whether route/visibility chunks filter them at runtime.
