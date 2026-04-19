# map-tools-ps2

Experimental tools for inspecting and exporting Need for Speed: Hot Pursuit 2 PS2 track bundles.

The tool reads HP2 PS2 `TRACKB##.BUN` and compressed `TRACKB##.LZC` files, decodes bChunk mesh objects, reconstructs PS2 VIF strip geometry, optionally applies scenery placement records, and can compare decoded output against PCSX2 GS dumps.

## Requirements

- Python 3.10 or newer.
- Local HP2 PS2 extracted game files, usually under a directory like:

```text
/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS
```

The package depends on `tqdm` for command-line progress bars.

## Running

From the project root:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 --help
```

If installed as a package, the script entry point is:

```bash
map-tools-ps2 --help
```

Most commands accept either a direct `input` path or a `--game-dir` plus `--track` pair.

Direct path:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC \
  -o out/TRACKB64.glb
```

Game directory and track number:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 64 \
  -o out/TRACKB64.glb
```

## Commands

```text
export              Export OBJ or GLB.
export-dual         Export native-primitive GLB plus ps2mesh debug JSON/BIN.
export-placement    Export scenery prop placement coordinates to text.
decompress          Decompress a COMP/LZC bundle.
chunks              Print the decompressed bChunk tree.
validate-gsdump     Compare decoded track blocks to GS dump draw packets.
benchmark-transform Fit source vertices against GS dump screen vertices.
benchmark-bounds    Compare decoded vertices to 0x34004 metadata bounds.
benchmark-topology  Compare raw strip face counts to GLB-emitted face counts.
probe-primitive     Compare one source block to one GS draw.
oracle-gsdump       Compare reconstructed primitive streams against a GS dump.
```

## export

Exports a track to OBJ or GLB. The output format is selected from the `-o` suffix.

```text
usage: map-tools-ps2 export [-h] [-o OUTPUT] [--game-dir GAME_DIR]
                            [--track TRACK] [--texture-dir TEXTURE_DIR]
                            [--with-placement]
                            [--vertex-colors {auto,always,off}]
                            [--primitive-assembly {triangles,native}]
                            [input]
```

Arguments:

```text
input                         TRACKB##.BUN or TRACKB##.LZC path.
-o, --output OUTPUT           Output path. Defaults to INPUT stem with .obj.
--game-dir GAME_DIR           Directory containing ZZDATA/TRACKS.
--track TRACK                 Track number, for example 64 for TRACKB64.
--texture-dir TEXTURE_DIR     Directory containing TEX##TRACK.BIN and TEX##LOCATION.BIN.
--with-placement              Place scenery props using 0x00034103 instance records.
--vertex-colors always        Always export decoded VIF vertex colors. This is the default.
--vertex-colors auto          Export VIF colors only on road-like/render-flagged blocks.
--vertex-colors off           Disable VIF color export.
--primitive-assembly triangles Reconstruct triangle indices for GLB.
--primitive-assembly native   Preserve native strip/fan-style primitive groups where possible.
```

Export a textured GLB:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC \
  -o out/TRACKB64.glb \
  --texture-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS
```

Export a GLB with placed scenery props:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC \
  -o out/TRACKB64.with-placement.glb \
  --texture-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS \
  --with-placement
```

Export an OBJ:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  -o out/TRACKB61.obj
```

Notes:

- Without `--with-placement`, GLB/OBJ export writes base mesh objects. Some prop templates are centered near the map origin by design.
- With `--with-placement`, scenery instances are expanded using the recorded instance transforms and the mesh name hashes from each scenery section's `0x00034102` table. This duplicates geometry instead of using compact glTF instancing.
- With `--with-placement`, the source scenery-template palette is not emitted as unplaced geometry, so props appear only at their instance coordinates.
- `--expand-instances` is still accepted as a hidden compatibility alias for `--with-placement`.
- CLI export commands show `tqdm` progress bars while objects, placements, and final GLB bytes are being written.

## export-dual

Exports a native-primitive GLB plus debug JSON and binary sidecar files.

```text
usage: map-tools-ps2 export-dual [-h] [-o OUTPUT]
                                 [--debug-output DEBUG_OUTPUT]
                                 [--game-dir GAME_DIR] [--track TRACK]
                                 [--texture-dir TEXTURE_DIR]
                                 [--with-placement]
                                 [--vertex-colors {auto,always,off}]
                                 [input]
```

Arguments:

```text
input                         TRACKB##.BUN or TRACKB##.LZC path.
-o, --output OUTPUT           GLB output path. Defaults to INPUT stem with .native.glb.
--debug-output DEBUG_OUTPUT   Debug JSON path. BIN is written next to it.
--game-dir GAME_DIR           Directory containing ZZDATA/TRACKS.
--track TRACK                 Track number. Defaults to 61.
--texture-dir TEXTURE_DIR     Directory containing track texture BIN files.
--with-placement              Place scenery props using instance coordinate records.
--vertex-colors always|auto|off
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export-dual \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --texture-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS \
  -o out/TRACKB61.native.glb
```

## export-placement

Exports every scenery prop placement record as CSV-style text.

```text
usage: map-tools-ps2 export-placement [-h] [-o OUTPUT] [--game-dir GAME_DIR]
                                      [--track TRACK]
                                      [input]
```

Arguments:

```text
input                TRACKB##.BUN or TRACKB##.LZC path.
-o, --output OUTPUT  Output text path. Defaults to INPUT with .txt suffix.
--game-dir GAME_DIR  Directory containing ZZDATA/TRACKS.
--track TRACK        Track number, for example 64 for TRACKB64.
```

Default output for `TRACKB64.LZC`:

```text
TRACKB64.txt
```

Output format:

```text
NAME,x,y,z,sacle_x,scale_y,scale_z
```

The `sacle_x` spelling is intentional in the current output header.

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export-placement \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC
```

Example with explicit output:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 export-placement \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 64 \
  -o out/TRACKB64-placement.txt
```

Sample rows:

```text
NAME,x,y,z,sacle_x,scale_y,scale_z
ANTENNA_00,0,0,0,1,1,1
TRACK_HELICOPTER,0,0,0,1,1,1
XB_HOUSEA_A1_00,0,0,0,1,1,1
```

## decompress

Decompresses a `COMP`/`.LZC` bundle.

```text
usage: map-tools-ps2 decompress [-h] [-o OUTPUT] input
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 decompress \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC \
  -o out/TRACKB64.BUN
```

If `-o` is omitted, the output path is the input path with a `.BUN` suffix.

## chunks

Prints the decompressed bChunk tree.

```text
usage: map-tools-ps2 chunks [-h] input
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 chunks \
  /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB64.LZC
```

## validate-gsdump

Compares decoded track blocks to PCSX2 GS dump draw packets.

```text
usage: map-tools-ps2 validate-gsdump [-h] [--game-dir GAME_DIR]
                                     [--track TRACK]
                                     [--texture-dir TEXTURE_DIR]
                                     [--object OBJECT]
                                     [--draw-start DRAW_START]
                                     [--draw-stop DRAW_STOP]
                                     [--st-precision ST_PRECISION]
                                     [--limit LIMIT]
                                     gsdump [input]
```

Arguments:

```text
gsdump                    PCSX2 .gs or .gs.zst dump.
input                     Optional track path.
--game-dir GAME_DIR       Directory containing ZZDATA/TRACKS.
--track TRACK             Track number. Defaults to 61.
--texture-dir TEXTURE_DIR Directory containing track texture BIN files.
--object OBJECT           Object-name substring to validate.
--draw-start DRAW_START   First GS draw packet to include.
--draw-stop DRAW_STOP     Exclusive GS draw packet stop index.
--st-precision N          Decimal precision used for ST matching.
--limit LIMIT             Maximum source block rows to print.
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 validate-gsdump \
  "/Users/nurupo/Library/Application Support/PCSX2/snaps/capture.gs.zst" \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object TRN_SECTION60_UNDERROAD
```

## benchmark-transform

Fits source vertices against GS dump screen vertices to compare transform paths.

```text
usage: map-tools-ps2 benchmark-transform [-h] [--game-dir GAME_DIR]
                                         [--track TRACK] [--object OBJECT]
                                         [--st-precision ST_PRECISION]
                                         [--min-vertices MIN_VERTICES]
                                         [--max-samples MAX_SAMPLES]
                                         [--limit LIMIT]
                                         gsdump [input]
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 benchmark-transform \
  "/Users/nurupo/Library/Application Support/PCSX2/snaps/capture.gs.zst" \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object XS_LIGHTPOST \
  --limit 24
```

## benchmark-bounds

Compares decoded local/transformed vertices to `0x00034004` block metadata bounds.

```text
usage: map-tools-ps2 benchmark-bounds [-h] [--game-dir GAME_DIR]
                                      [--track TRACK] [--object OBJECT]
                                      [--limit LIMIT]
                                      [input]
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 benchmark-bounds \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 64 \
  --object XH_TIKI
```

## benchmark-topology

Compares raw strip face counts to GLB-emitted face counts.

```text
usage: map-tools-ps2 benchmark-topology [-h] [--game-dir GAME_DIR]
                                        [--track TRACK] [--object OBJECT]
                                        [--limit LIMIT]
                                        [input]
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 benchmark-topology \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object TRN_SECTION60_UNDERROAD
```

## probe-primitive

Compares one source block against one GS draw under primitive assembly hypotheses.

```text
usage: map-tools-ps2 probe-primitive [-h] [--game-dir GAME_DIR]
                                     [--track TRACK] [--object OBJECT]
                                     [--object-index OBJECT_INDEX]
                                     [--block BLOCK] [--draw DRAW]
                                     gsdump [input]
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 probe-primitive \
  "/Users/nurupo/Library/Application Support/PCSX2/snaps/capture.gs.zst" \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object XS_LIGHTPOSTA_1_00 \
  --block 6 \
  --draw 1234
```

## oracle-gsdump

Compares reconstructed primitive streams against GS dump draw packets.

```text
usage: map-tools-ps2 oracle-gsdump [-h] [--game-dir GAME_DIR] [--track TRACK]
                                   [--object OBJECT]
                                   [--st-precision ST_PRECISION]
                                   [--max-key-sources MAX_KEY_SOURCES]
                                   [--max-key-draws MAX_KEY_DRAWS]
                                   [--limit LIMIT]
                                   gsdump [input]
```

Example:

```bash
PYTHONPATH=src python3 -m map_tools_ps2 oracle-gsdump \
  "/Users/nurupo/Library/Application Support/PCSX2/snaps/capture.gs.zst" \
  --game-dir /Users/nurupo/Desktop/ps2/hp2_ps2/GameFile \
  --track 61 \
  --object XS_LIGHTPOST \
  --limit 40
```

## Track Texture Files

Texture lookup uses the track texture files in `ZZDATA/TRACKS`:

```text
TEX##TRACK.BIN
TEX##LOCATION.BIN
```

Pass that directory with `--texture-dir` when exporting textured GLB files.

For texture BIN layout, PS2 swizzle decode, palette decode, and material alpha rules, see [docs/hp2_ps2_texture_decoding.md](/Users/nurupo/Desktop/dev/eagl-godot/map_tools_ps2/docs/hp2_ps2_texture_decoding.md).

## Scenery Placement Notes

HP2 PS2 tracks commonly store props as base mesh templates plus instance records.

- Base mesh names come from `0x00034003`.
- Base mesh name hashes also come from `0x00034003`.
- Base mesh geometry comes from `0x00034004` and `0x00034005`.
- `0x00034102` scenery info records map instance info numbers to mesh name hashes, matching Modelulator's HP2 track-scene export path.
- Actual prop coordinates come from `0x00034103` scenery instance records.
- `export-placement` writes the raw placement transform position and derived axis scales.
- `export --with-placement` bakes those instance transforms into exported GLB geometry and omits the unplaced source-template copies.
- GLB materials use `KHR_materials_unlit` so Blender shows baked PS2 texture and vertex-lighting colors without extra scene lighting.
- CLI placement and geometry exports show `tqdm` progress bars, including final GLB byte writes.

For Godot loader implementation guidance, see [docs/godot_bun_loader_design.md](/Users/nurupo/Desktop/dev/eagl-godot/map_tools_ps2/docs/godot_bun_loader_design.md).

## Validation

Run the unit tests:

```bash
PYTHONPATH=src python3 -m unittest tests.test_comp
```

Run discovery:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests
```

Compile check:

```bash
PYTHONPATH=src python3 -m compileall -q src tests
```
