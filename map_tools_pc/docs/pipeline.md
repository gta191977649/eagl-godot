# OTools NFSHP2 Export Pipeline

This document summarizes how the existing `otools` project extracts Need for Speed: Hot Pursuit 2 (`nfs` / `nfshp` / `nfshp2`) map geometry from `.o` files.

It is not a dedicated "map package extractor". It is a generic EA `.o` exporter that can interpret NFSHP2 object files well enough to export scene geometry and material references.

## Scope

- Supported NFS operation: export only.
- Supported input type: `.o` and `.ord`.
- Main output type: `.gltf`.
- Optional output formats: `fbx`, `glb`, `dae`, `obj`, `3ds`, `x`, `x3d` via Assimp conversion.
- Texture export behavior: texture names and image URIs are written, but real texture decoding is not done here. Dummy textures can be generated.

Source references:

- Entry point: `/Users/nurupo/Desktop/dev/otools/OTools/main.cpp`
- Exporter: `/Users/nurupo/Desktop/dev/otools/OTools/export.cpp`
- NFS target: `/Users/nurupo/Desktop/dev/otools/OTools/target_nfshp2.cpp`
- README notes: `/Users/nurupo/Desktop/dev/otools/README.md`

## High-Level Pipeline

1. CLI parses the requested operation and target game.
2. `-game nfs|nfshp|nfshp2` selects `TargetNFSHP2`.
3. Export dispatch calls `oexport()`.
4. `oexport()` either:
   - writes glTF directly, or
   - writes temporary glTF and converts it to another format with Assimp.
5. `convert_o_to_gltf()` reads the `.o` file as ELF.
6. It locates `.data`, symbol table, string table, and relocations.
7. It resolves relocations in memory so internal pointers become usable.
8. It discovers model, render method, skeleton, and related objects from ELF symbols.
9. It walks model layers and primitives.
10. It interprets render commands to find vertex buffers, index buffers, primitive topology, samplers, and shader name.
11. It uses the target shader declarations to decode vertex layout.
12. It converts strips/fans into triangle lists.
13. It writes a glTF scene containing nodes, meshes, materials, accessors, buffers, and image references.
14. If requested, Assimp converts the generated glTF to another scene format.

## Pipeline by Stage

### 1. Operation selection

Input:

- CLI operation, such as `export`
- CLI game id, such as `nfs`, `nfshp`, or `nfshp2`
- input path via `-i`
- optional output path via `-o`

Process:

- `main.cpp` maps `export` to `oexport`.
- `main.cpp` maps `nfs|nfshp|nfshp2` to `TargetNFSHP2`.
- import is explicitly rejected for this target.

Output:

- exporter callback selection
- target object set to `TargetNFSHP2`
- export options loaded into global options

Relevant code:

- `main.cpp:74-79`
- `main.cpp:189-195`
- `main.cpp:321-360`

### 2. Export dispatch

Input:

- resolved input file path
- resolved output file path
- export options like `-targetFormat`, `-skeleton`, `-dummyTextures`, `-jpegTextures`

Process:

- `oexport()` decides whether to write glTF directly or to use glTF as an intermediate format.
- For non-glTF output, it creates a temp directory, exports to `temp.gltf`, then converts with Assimp.

Output:

- direct `.gltf`, or
- temporary `.gltf` followed by requested target format

Relevant code:

- `export.cpp:2825-2837`
- `export.cpp:2392-2415`

### 3. ELF parse and relocation

Input:

- one `.o` / `.ord` file as raw bytes

Process:

- verifies ELF magic
- scans sections to locate:
  - `.data` payload
  - symbol table
  - symbol names table
  - relocation table
- builds a list of symbols
- builds a relocation map
- patches relocatable pointers in memory so later object traversal works

Output:

- in-memory relocated data blob
- symbol list with names and offsets
- relocation lookup table

Relevant code:

- `export.cpp:287-360`

### 4. Optional external skeleton load

Input:

- optional `-skeleton <filePath>` argument
- skeleton `.o` file

Process:

- repeats the same ELF parse and relocation process for the skeleton file
- discovers `__Bone:::` and `__Skeleton:::` symbols there
- uses the external skeleton instead of embedded one when present

Output:

- relocated external skeleton data
- bone list and skeleton pointer

Relevant code:

- `export.cpp:363-445`

### 5. Object discovery from symbols

Input:

- relocated main `.o` data
- symbol table
- optional relocated skeleton data

Process:

- scans symbols for known object prefixes:
  - `__Model:::`
  - `__RenderMethod:::`
  - `__geoprimdatabuffer`
  - `__Bone:::`
  - `__Skeleton:::`
- picks the primary `Model`
- sorts model variations and takes the first one

Output:

- main `Model*`
- render method list
- optional skeleton and bones

Relevant code:

- `export.cpp:447-525`

### 6. Sidecar stadium extras

Input:

- original input filename and parent directory
- companion files for some EA stadium-style assets

Process:

- if the input filename matches certain stadium naming patterns, exporter also looks for:
  - `.loc` flag files
  - `.loc` light/effect files
  - `.bin` collision files
- these are generic exporter features; they are not NFS-specific

Output:

- optional flag nodes
- optional effect nodes
- optional collision meshes

Relevant code:

- `export.cpp:527-708`

Note:

- For NFSHP2 map work, this stage is usually not the core mechanism. The important extraction logic is the model/render-method path.

### 7. Scene and node graph assembly

Input:

- chosen model
- optional skeleton
- optional collision / flags / effects

Process:

- creates glTF scene and root node references
- creates one node per model layer
- creates skeleton nodes and hierarchy if bones are present
- creates extra nodes for collision, flags, and effects when available

Output:

- glTF `scenes[]`
- glTF `nodes[]`
- optional `skins[]`

Relevant code:

- `export.cpp:717-820`

### 8. Mesh primitive traversal

Input:

- `model->mLayers`
- each layer's render descriptors

Process:

- walks each layer
- detects whether the model layer block uses an old layout
- for each primitive, gets:
  - render descriptor
  - render method
  - command parameter block chain

Output:

- per-primitive decode state for geometry and materials

Relevant code:

- `export.cpp:998-1019`

### 9. Render command decode

Input:

- `renderMethod`
- linked `globalParameters` blocks
- relocation map
- target shader library

Process:

- finds the render method microcode symbol name
- resolves shader name from `<ShaderName>__EAGLMicroCode`
- looks up shader declaration via `globalVars().target->FindShader(shaderName)`
- reads command stream until enough data is found

Key commands used:

- `4` / `75`: vertex stream source
- `7`: index buffer
- `28`: skin weights / skin stream
- `33`: geo-prim state or geo-prim format symbol
- `9` / `32`: sampler / TAR texture reference

Output:

- vertex buffer pointer + stride
- index buffer pointer + element size
- primitive topology
- culling / blend hints
- texture references
- shader declaration to decode vertex attributes

Relevant code:

- `export.cpp:1038-1465`

### 10. Texture name and sampler resolution

Input:

- sampler commands
- local `TAR` structs or relocation-backed global `__EAGL::TAR:::` symbols

Process:

- extracts texture tag from local TAR data, or
- parses texture metadata from global TAR symbol names
- maps wrap/filter modes when possible
- creates image URI as `<textureName>.png` or `.jpeg`
- reuses already-created texture entries by lowercase name

Output:

- glTF sampler records
- glTF texture records
- glTF image URIs

Important limitation:

- this exporter does not decode the actual source texture payload here
- `-dummyTextures` can emit placeholder image files instead

Relevant code:

- `export.cpp:1232-1465`
- `export.cpp:2165-2198`
- `export.cpp:2240-2283`

### 11. Primitive topology normalization

Input:

- index buffer
- index element size
- topology from command `33` or geo-prim format string

Process:

- triangle lists stay as lists
- triangle strips are expanded into explicit triangles
- triangle fans are expanded into explicit triangles
- optional face winding flip can be applied

Output:

- normalized triangle-list index buffer

Relevant code:

- `export.cpp:1560-1660`

### 12. Vertex attribute decoding

Input:

- vertex buffer
- vertex stride
- selected shader declaration from the target

Process:

- iterates shader declaration entries
- maps usages to glTF semantics:
  - `POSITION`
  - `NORMAL`
  - `TEXCOORD_n`
  - `COLOR_0`
  - `JOINTS_0`
  - `WEIGHTS_0`
- calculates per-attribute byte offsets and component types
- computes bounds for positions
- optionally transforms normals/colors according to export options

Output:

- glTF accessors
- glTF bufferViews
- raw buffer payloads encoded later as base64 data URIs

Relevant code:

- `export.cpp:1660-2240`

### 13. Material assembly

Input:

- shader name
- resolved textures
- culling / transparency info

Process:

- builds a material record per primitive
- stores shader name in material naming/options
- sets `doubleSided` and `alphaMode` when inferred
- binds texture 0 as base color texture
- may emit `.mato` if material option strings become too long

Output:

- glTF materials
- optional `.mato` sidecar file

Relevant code:

- `export.cpp:2240-2283`
- `export.cpp:2284-2367`

### 14. Final glTF write

Input:

- nodes
- meshes
- materials
- accessors
- bufferViews
- binary buffers
- images / samplers / textures

Process:

- writes JSON glTF
- embeds all geometry buffers as base64 `data:` URIs
- references images by relative filename

Output:

- `.gltf`
- optional dummy texture image files
- optional `.mato`

Relevant code:

- `export.cpp:680-2367`

### 15. Optional preview export path

Input:

- `.o` file

Process:

- runs a simplified version of the same mesh traversal
- writes an old `.x`-style preview scene
- only uses a minimal subset of geometry/material logic

Output:

- preview mesh file

Relevant code:

- `export.cpp:2483-2842`

## NFS-Specific Pieces

The NFS target does not define a separate parser. Its main job is to provide shader declarations so the generic exporter knows how to interpret vertex buffers.

NFS-specific inputs:

- game id `nfs`, `nfshp`, or `nfshp2`
- NFSHP2 `.o` object files, often many files per track/map
- known NFS shader declarations in `shaders_NFSHP2`

NFS-specific processing:

- target selection in `main.cpp`
- shader lookup via `TargetNFSHP2::Shaders()`
- default shader choice via `TargetNFSHP2::DecideShader()`

NFS-specific outputs:

- mesh geometry exported from each `.o`
- material/image references based on NFS TAR metadata

Relevant code:

- `main.cpp:189-195`
- `target_nfshp2.cpp:3077-3086`

## Inputs / Process / Outputs Summary Table

| Stage | Input | Process | Output |
|---|---|---|---|
| CLI selection | operation, `-game`, `-i`, options | choose export path and target | configured export run |
| ELF load | `.o` bytes | parse ELF sections and relocations | relocated in-memory object graph |
| Symbol discovery | symbol table + data blob | find `Model`, `RenderMethod`, bones, skeleton | typed object pointers |
| Layer traversal | `model->mLayers` | iterate layers and primitives | primitive decode units |
| Render decode | render method + parameter blocks | extract VB/IB/topology/samplers/shader | geometry/material inputs |
| Shader decode | shader declaration | map vertex layout into attributes | accessors and buffer views |
| Index normalize | strip/fan/list data | expand to triangle list | normalized index buffer |
| Texture resolve | TAR/local/global texture refs | derive texture names and sampler states | glTF images/textures/samplers |
| Material build | shader + textures + state | build glTF material entries | material list |
| Scene write | all decoded data | emit glTF JSON and buffers | `.gltf` and sidecars |
| Format convert | generated glTF | Assimp export | `fbx` / `glb` / `dae` / etc. |

## What You Need as Input for a Map Extraction Tool

For a new tool modeled on this pipeline, the minimum practical inputs are:

- one NFSHP2 `.o` file to decode
- the selected target/game id

Useful optional inputs:

- a folder containing all related `.o` files for the map
- an external skeleton `.o` if some meshes depend on it
- texture archives or texture source files if real texture extraction is required

If the goal is "extract a whole NFSHP2 map", you will likely need:

- batch processing of many `.o` files
- scene merging across exported fragments
- texture archive support outside this exporter
- map-specific file discovery rules for files such as `comp*.o`, `trackg.o`, `skyg.o`

## Known Limitations and Oddities

- README says NFSHP2 support is export-only.
- README also says some NFS models cannot be exported because they use different mesh storage.
- `TargetNFSHP2::Name()` currently returns `"NBA2003"` instead of an NFS-specific name. That is likely a bug and can affect generic exporter branches that key off target name.

Relevant code and notes:

- `README.md:42`
- `README.md:94`
- `target_nfshp2.cpp:3065-3067`

## Practical Takeaway for `map_otools`

The reusable core is:

- ELF parsing
- relocation fixing
- symbol-driven object discovery
- render command decoding
- shader-declaration-driven vertex unpack
- triangle topology normalization

The missing "whole map" functionality is:

- gathering all related NFS map object files
- combining per-file exports into a single scene
- resolving real textures, not only image names
- handling alternate mesh storage layouts that `otools` does not yet support
