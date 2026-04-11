# Model / Texture Binary Analysis

This is a focused re-analysis of the `TRACKB*.BUN` object model chunks and texture binding mechanism for the PS2 Need for Speed: Hot Pursuit 2 track bundles.

Source data:

```text
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB*.LZC
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TEX*TRACK.BIN
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TEX*LOCATION.BIN
```

Repro script:

```sh
cd /Users/nurupo/Desktop/dev/eagl-dot/map_tools_ps2
PYTHONPATH=src python3 tools/analyze_bun_models.py /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB24.LZC --object TRN_SECTION60_CHOP3
PYTHONPATH=src python3 tools/analyze_bun_models.py /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB24.LZC --limit 0
```

## Summary

The model and texture binding mechanism is now much clearer:

```text
0x80034002 object
  0x00034003 object header, name, transform
  0x00034006 per-object texture hash list
  0x0003401d optional effect/light/material hash-like data
  0x00034004 per-run material/draw metadata table
  0x00034005 VIF vertex stream
  0x00034012 optional embedded actor/extra object data
```

Confirmed across all 30 `TRACKB*.LZC` files:

- 27,926 `0x80034002` object containers were found.
- 308,589 `0x34004` metadata records were correlated.
- Every `0x34004.word02` VIF offset matched a decoded `0x34005` VIF run start.
- Every `0x34004.word03 & 0xffff` matched the matching VIF run size in qwords.
- Every `0x34004.word00` texture index was valid for that object's `0x34006` texture hash list.
- Every decoded VIF run had equal position vertex count, UV count, and `0xc034` packed-value count.

This means the primary texture mapping mechanism is:

```c
tex_hash = object_34006_texture_hashes[run_metadata_34004.word00];
```

Do not use the run number or the packed byte at `0x34004 + 0x1c` as the texture index.

## `0x34006` Texture Hash List

`0x34006` is a per-object array of 8-byte records:

```c
typedef struct Hp2Ps2TextureRef {
    uint32_t tex_hash;
    uint32_t zero_or_flags;
} Hp2Ps2TextureRef;
```

The first word is a texture hash. It resolves against `TEX##LOCATION.BIN` and `TEX##TRACK.BIN` when the texture is track-local. Some common/global object hashes remain unresolved by the current texture library, for example some helicopter hashes.

Example, `TRACKB24` / `TRN_SECTION60_CHOP3`:

```text
0 0xbed9a1e8 CANYON_02
1 0x56fbed94 DIRT02
2 0xa4c048fa MOUNTAINTOP01_256
3 0x90d6af37 MOUNTSIDE_01
4 0x90d6af38 MOUNTSIDE_02
5 0x90d6af3c MOUNTSIDE_06
```

## `0x34004` Run Metadata

`0x34004` is a per-run table. Some payloads begin with:

```text
11 11 11 11 11 11 11 11
```

After that optional prefix, entries are 0x40 bytes each.

Current structure:

```c
typedef struct Hp2Ps2RunMetadata {
    uint32_t texture_index;      /* word00: index into object 0x34006 list */
    uint32_t unknown04;          /* word01: observed 0x80008000 for all scanned records */
    uint32_t vif_run_offset;     /* word02: offset into 0x34005 after optional VIF prefix */
    uint16_t vif_qwords;         /* word03 low half: bytes to next VIF run / 16 */
    uint16_t render_flags;       /* word03 high half */
    float    bounds_min[3];      /* word04..06, inferred */
    uint8_t  packed_material;    /* word07 byte0: not always texture_index */
    uint8_t  vertex_count;       /* word07 byte1: matches decoded VIF run vertex count */
    uint8_t  unknown_count;      /* word07 byte2: count-like, not a strip-triangle cap */
    uint8_t  ff_or_zero;         /* word07 byte3: observed 0xff or 0x00 */
    float    bounds_max[3];      /* word08..0a, inferred */
    uint32_t zero2c;             /* word0b */
    uint32_t unknown30;
    uint32_t unknown34;
    uint32_t unknown38;
    uint32_t zero3c;
} Hp2Ps2RunMetadata;
```

Important correction: the packed byte at record offset `0x1c` is not always a duplicate texture index. On `TRACKB11` / `FIRETRUCK_00`, records with `texture_index == 1` commonly have packed byte0 `2`. The GLB exporter should keep using `word00` for texture binding.

The `unknown_count` byte is also not a simple triangle count. Capping strips to this value caused visible holes. It may still be related to strip batches, clipped primitive counts, or a VU/GIF draw count, but it is not enough by itself to reconstruct topology.

Common `render_flags` values from the all-track scan:

```text
0x0000: 259,802 records; mostly terrain/scenery/sky
0x4041:  37,880 records; mostly RD road objects
0x1000:   7,457 records; mostly small scenery/signage objects
0x4080:   1,260 records; TRACK_* objects
0x4180:   1,200 records; TRACK_* objects
0xc180:     720 records; TRACK_* objects
0x4100:     270 records; FIRETRUCK / XB objects
```

## VIF Stream Correlation

`0x34005` has an optional 8-byte `0x11111111` prefix. After that, every run begins with:

```text
00 80 01 6e  [4-byte run header]
```

Every decoded run has:

- position rows at `imm 0xc002..0xc01f`
- UV rows at `imm 0xc020..0xc033`
- packed `V4_5` rows at `imm 0xc034..0xc03f`
- terminator `cmd 0x14`

Across all 308,589 runs:

```text
uv_count - vertex_count = 0
c034_count - vertex_count = 0
```

So `0xc020..0xc033` is very likely the primary UV stream, and `0xc034..0xc03f` is per-vertex packed data with one value per vertex. The `V4_5` values look more like packed color/normal-style data than a direct index list or strip-break list.

Example `TRN_SECTION60_CHOP3` record:

```text
rec 000:
  texture_index = 0 -> CANYON_02
  vif_offset    = 0x00000
  qwords        = 45
  render_flags  = 0x0000
  packed        = (0, 30, 18, 255)
  VIF header    = (30, 7, 90, 252)
  vertices/uv/c034 = 30 / 30 / 30

rec 002:
  texture_index = 1 -> DIRT02
  vif_offset    = 0x00440
  qwords        = 45
  render_flags  = 0x0000
  packed        = (1, 30, 18, 255)
  VIF header    = (30, 7, 90, 252)
  vertices/uv/c034 = 30 / 30 / 30
```

## Texture Mapping Mechanism

The evidence supports this draw loop:

```c
for each object 0x80034002:
    texture_hashes = read_0x34006();
    runs = read_0x34004_records();
    vif = read_0x34005_stream();

    for each run i:
        record = runs[i];
        assert(record.vif_run_offset == vif.run[i].offset);
        assert((record.word03 & 0xffff) * 16 == vif.run[i].byte_stride_to_next_run);

        texture_hash = texture_hashes[record.texture_index];
        vertices = decode_position_rows(vif.run[i]);
        uvs = decode_uv_rows(vif.run[i]);
        packed = decode_v4_5_rows(vif.run[i]); /* not yet consumed by exporter */
        draw_triangle_strip(vertices, uvs, texture_hash, record.render_flags);
```

Current exporter status:

- Correctly uses `0x34004.word00 -> 0x34006[]` for texture binding.
- Correctly decodes one UV pair per vertex from `0xc020..0xc033`.
- Still uses strip topology as the default, but now splits severely stitched runs at inferred restart boundaries and upgrades exact metadata-matched runs to triangle lists or 4-vertex quad batches when those layouts are cleaner than a strip on the decoded geometry.
- Does not yet interpret `render_flags`, packed `V4_5`, vertex color/normal, or the exact PS2 strip-entry table semantics behind those restart boundaries.

## Remaining Unknowns

- What `render_flags` bits in `0x34004.word03 >> 16` do. The `0x4041` flag is strongly road-associated.
- What `0x34004.word07.byte2` means. It is count-like, but it is not a simple strip cap.
- Whether the exact PS2 draw path uses `V4_5` packed data for color only, normal only, color plus alpha, or draw control.
- Whether some remaining visual stretching is caused by missing strip-entry state beyond the inferred restart boundaries, missing per-run render flags, UV wrapping state, or a second material/UV mode.
- The stripped PS2 executable `SLUS_203.62` contains strings such as `TRISTRIP`, `eStripEntry`, `DuplicatedStripEntryData`, `DuplicatedStripEntryTable`, and `CulledStrips*`. That strongly suggests the world-solid path is still strip-based, but some PS2 terrain runs likely depend on strip-entry tables or segment metadata that the current exporter does not yet consume.
- What `0x3401d` means. It is common on road chunks and often stores `0x001c3745, 0`, with an optional `0x11111111` prefix.
- What `0x34012` means. It appears on a small set of animated/extra objects such as water wheels and props, and contains embedded name/transform-style data rather than normal VIF draw metadata.
