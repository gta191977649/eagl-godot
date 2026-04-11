# NFSHP2 Track Render-State Runtime Notes

This file documents the original `nfshp2.exe` track render-state path found by
static analysis, plus the related files and local parser code in this repo.

The main conclusion is:

- `drvpath.ini` is read at runtime.
- The EXE hard-codes parser keys and default render-state values.
- I did not find per-track hard-coded `drvpath.ini` node tables in the EXE.
- The state-switching "anchor" appears to be a runtime object position, tested
  against loaded compartment/region geometry, while `drvpath.ini` supplies the
  ordered compartment ring and per-node render/fog state.
- Reverse travel is handled with the same circular `drvpath.ini` ring plus a
  per-slot direction/side flag; no separate reverse route table was found.

The analysis target was:

```text
/Users/nurupo/Desktop/nfshp2/nfshp2.exe
/Users/nurupo/Desktop/nfshp2/tracks
```

## Related Files

Original game files:

```text
/Users/nurupo/Desktop/nfshp2/nfshp2.exe
  PE32 Windows executable. Contains loader/state-switching code.

/Users/nurupo/Desktop/nfshp2/tracks/Tracks.ini
  Playable track catalog. Maps track ids to a theme folder and route variant.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/levelNN/drvpath.ini
  Runtime route/render-state order.
  Contains [path] nodenum, [nodeN] compartmentId, [PlayerCopN] spawn data,
  and [effectsN] fog/glow state.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/levelNN/level.dat
  Route metadata. Local tooling currently parses placement records,
  levelft selectors, group records, and point records.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/levelNN/aipaths.dat
  AI path data. It is referenced separately by the EXE and is not the
  `drvpath.ini` render-state table.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/compNN.o
  Shared compartment geometry. These files are MIPS ELF relocatables.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/compNN.viv
  Texture/resource sidecar for a compartment.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/levelNN/levelG.o
  Route-local geometry pool selected by `level.dat` levelft records.

/Users/nurupo/Desktop/nfshp2/tracks/<TrackName>/levelNN/level.fsh
  Route-local texture bank.
```

Local repo files:

```text
map_otools/parsers/drvpath.py
  Parses `drvpath.ini` and currently returns `DrvPath(compartment_ids, start_nodes)`.

map_otools/parsers/level_dat.py
  Parses `level.dat` into fixed-size tables.

map_otools/models.py
  Defines `DrvPath`, `LevelDat`, `RouteContext`, and related dataclasses.

map_otools/route_resolver.py
  Resolves playable track/theme/level context.

map_otools/track_manager.py
  Builds export components from the resolved route context.

map_otools/render/layer_policy.py
map_otools/render/scene_builder.py
  Local renderer/exporter policy. These are not the original game runtime,
  but they should use this document as guidance for faithful route windows.
```

## Evidence Summary

Important strings in `nfshp2.exe`:

```text
0x006940f0  drvpath.ini
0x006940e8  nodenum
0x006940e0  path
0x006940d4  PlayerCop%d
0x006940c8  startNode
0x006940c0  posX
0x006940b8  posY
0x006940b0  posZ
0x00694098  node
0x00694090  %s%d
0x00694080  compartmentId
0x00693250  effects
0x00693fbc  ngcFogFarClip
0x00693fac  ngcFogNearClip
0x00693f9c  ngcFogSkyFog
0x00693f90  ngcFogType
0x00693f7c  ngcFogRangeAdjust
0x00693f68  ngcFogRampFramespan
0x00693f58  ngcFogColorR
0x00693f48  ngcFogColorG
0x00693f38  ngcFogColorB
```

Key functions:

```text
0x4389b0  Load lighting.ini and drvpath.ini render state.
0x439120  Initialize/update loaded node wrappers after drvpath load.
0x4396a0  Force current route ordinal and update a wider old/new window.
0x439aa0  Update direction flag / previous state, then unload/update wrapper.
0x439b50  Next node index, with wraparound.
0x439b90  Two-ahead node index, with wraparound.
0x439c00  Previous node index, with wraparound.
0x439c40  Two-behind node index, with wraparound.
0x439d80  Advance preload target and load comp%02d.viv.
0x439f40  Main non-event render-state update path.
0x43a150  State-switch decision using an engine-reported current index.
0x43a3f0  Alternate event/tree-aware update path.
0x43a910  Build comp%02d.viv path and start async load.
0x43a970  Poll async compartment load completion.
0x43b4f0  Point-in-region test against loaded geometry/region data.
0x4d00a0  Per-frame level/render update caller; calls 0x439f40 or 0x43a3f0.
0x533010  Small accessor: returns current index and a direction/side flag.
```

Direct hard-code checks:

```text
All 24 tracks/*/level*/drvpath.ini files were scanned.
Full compartmentId sequences were searched in nfshp2.exe as i32, i16, and u8.
Result: 0 full-sequence hits.

Full PlayerCop XYZ vectors were searched as little-endian float triplets.
Result: 0 full-vector hits.

Some individual floats matched, but only generic constants such as 10.0,
36.0, 64.0, or 76.5. These are not meaningful evidence of per-track tables.
```

## Track Rendering Pipeline

ASCII overview:

```text
              +------------------------------+
              | Tracks.ini                    |
              | track id -> theme + level id  |
              +---------------+--------------+
                              |
                              v
              +------------------------------+
              | tracks/<theme>/levelNN/      |
              | drvpath.ini + level.dat      |
              +---------------+--------------+
                              |
                              v
         +--------------------+--------------------+
         |                                         |
         v                                         v
+--------------------+                  +----------------------+
| drvpath.ini loader |                  | level/asset loaders  |
| 0x4389b0           |                  | compNN.o/compNN.viv  |
+---------+----------+                  | levelG.o/level.fsh   |
          |                             +----------+-----------+
          |                                        |
          v                                        v
+----------------------------+       +-------------------------+
| TrackRenderState           |       | Loaded compartments     |
| - node_count               |       | - geometry              |
| - comp_order[]             |       | - region/point data     |
| - per-node effects[]       |       | - resource handles      |
| - current_index per slot   |       +------------+------------+
+-------------+--------------+                    |
              |                                   |
              +-----------------+-----------------+
                                |
                                v
                 +-----------------------------+
                 | Per-frame update 0x4d00a0   |
                 +--------------+--------------+
                                |
                                v
                +------------------------------+
                | Render-state update          |
                | 0x439f40 or 0x43a3f0         |
                +--------------+---------------+
                               |
                               v
        +-----------------------------------------------+
        | For each active slot/player/camera context     |
        | - render current, previous, and next wrappers  |
        | - test if runtime anchor crossed a region      |
        | - preload/unload +/-2 neighborhood             |
        +----------------------+------------------------+
                               |
                               v
          +------------------------------------------+
          | State switch decision 0x43a150           |
          | current_from_engine = accessor 0x533010  |
          | if current is same: keep state           |
          | if current is adjacent: advance/rewind   |
          | if current jumps: mark state error/reset |
          +----------------------+-------------------+
                               |
                               v
              +---------------------------------+
              | Load/poll comp%02d.viv handles |
              | 0x43a910 / 0x43a970            |
              +---------------------------------+
```

State decision detail:

```text
Runtime anchor position
   |
   | 0x43b4f0 tests X/Z against region polygons
   | using data reached through global object pointer 0x6d1e2c[index] + 0x120
   v
Matched route context / current compartment index
   |
   | 0x533010 returns:
   |   out_index = object->index_table[slot]
   |   out_direction_flag = object->flag_table[slot] != 0
   v
Compare against drvpath ring:
   same index      -> no switch
   next/previous   -> normal transition
   non-adjacent    -> set state fault/reset marker
   |
   v
Update active slot:
   current_index[slot]
   next preload target
   direction flag
   wrapper load state
```

Reverse driving / direction changes:

```text
HP2 does handle reverse travel in the render-state machine.

The EXE does not use a separate reverse `drvpath.ini` table. It keeps the same
circular node ring and stores a per-slot direction/side flag at state offset
`+0x40 + slot`. When that flag changes, the engine unloads the stale two-away
wrapper on the old side, keeps the current/previous/next window alive, and
starts a preload on the opposite two-away side.

Important addresses from the second dump:

0x533010
  Returns the engine-reported route boundary/index from
  `index_source + 0x40 + slot * 4`, and the direction/side flag from
  `index_source + 0x38 + slot * 4`.

0x43a150
  Accepts only adjacent movement in the circular ring. If the new index is not
  previous or next relative to the stored render index, it sets the same state
  fault/reset marker used by other transition failures.

  If the direction flag is nonzero:
    current render index becomes index - 1 with wrap
    preload target becomes index + 1 with wrap

  If the direction flag is zero:
    current render index becomes index + 1 with wrap
    preload target becomes index - 1 with wrap

  The bit value is therefore best treated as "which side of the boundary is
  current" rather than naming it forward or reverse without more evidence from
  the vehicle/controller code.

0x439aa0
  Detects a direction/side flag change for a slot. It reads the active context
  through `0x6d1e2c[slot] + 0x12c`, calls `0x4ccfe0`, compares the returned
  scalar with `-1.0f` at `0x65d4e8`, and updates `state + 0x40 + slot`.
  On change it unloads a two-away wrapper chosen from the old/new side.

0x439d80
  Starts the next preload two nodes ahead on one side or two nodes behind on the
  other side:
    flag nonzero -> current + 2 with wrap
    flag zero    -> current - 2 with wrap
```

## What `drvpath.ini` Controls

Example shape:

```ini
[path]
nodenum=9

[node0]
compartmentId=2

[node1]
compartmentId=1

[PlayerCop1]
startNode=1
posX=-519.3
posY=147.1
posZ=479.4

[effects0]
SunFogDensity=0.1000
BaseFogDensity=0.1000
NgcFogFarClip=6000
```

Confirmed loader behavior at `0x4389b0`:

```text
1. Build path to lighting.ini and read global track glow/shadow settings.
2. Build path to drvpath.ini.
3. Read [path] nodenum into this->node_count.
4. Clamp node_count to 63.
5. For each node ordinal:
   - build "node%d"
   - initialize two adjacent node records
   - read `compartmentId`
   - build "effects%d"
   - set default fog/glow values
   - read SunFog*, BaseFog*, NgcFog* values
   - store the node/effect record
6. Read PlayerCop or TreeEvent start nodes depending on the active context.
7. Initialize route state bookkeeping.
```

Meaning:

```text
[nodeN].compartmentId is not a coordinate.
It is the compartment id used to build `comp%02d.viv` and to select the
shared `compNN.o` geometry/resource compartment.

[effectsN] belongs to the same node ordinal.
It is the per-node render/fog/glow state applied when the active context moves
through that ordinal.

[PlayerCopN].posX/Y/Z is spawn/placement-like data.
It was parsed by 0x4389b0, but I did not find evidence that these coordinates
drive the track render-state transition itself.
```

## Inferred Runtime Structures

Names are invented. Offsets are from observed instructions and should be
treated as working labels, not original symbol names.

### Drvpath file model

This is the file-side schema:

```c
typedef struct DrvPathFileNode {
    int32_t compartmentId;   /* [nodeN].compartmentId */
} DrvPathFileNode;

typedef struct DrvPathFileSpawn {
    int32_t startNode;       /* [PlayerCopN].startNode or Tree event start */
    float posX;
    float posY;
    float posZ;
} DrvPathFileSpawn;

typedef struct DrvPathFileEffects {
    int32_t baseEqSun;       /* BaseEqSun, default 1 */

    float sunFogDensity;
    float sunFogSkyDensity;
    uint32_t sunFogColor;    /* packed RGB, alpha forced high */

    float baseFogDensity;
    float baseFogSkyDensity;
    uint32_t baseFogColor;   /* packed RGB, alpha forced high */

    float ngcFogFarClip;
    float ngcFogNearClip;
    float ngcFogSkyFog;
    int32_t ngcFogType;
    bool ngcFogRangeAdjust;
    uint32_t ngcFogColor;    /* packed RGB, alpha forced high */
    int32_t ngcFogRampFramespan;
} DrvPathFileEffects;
```

### Track render state object

Observed from `0x4389b0`, `0x439120`, and neighbor helpers:

```c
#define MAX_DRVPATH_NODES 63

typedef struct TrackRenderState {
    /* +0x000 */ uint32_t unknown_000;
    /* +0x004 */ int32_t node_count;           /* [path].nodenum, clamped to 63 */
    /* +0x008 */ bool init_guard_or_dirty;

    /*
     * +0x030
     * One current route ordinal per active render/player/camera slot.
     * Helpers 0x439b50/0x439c00 index this as current_index[slot].
     */
    /* +0x030 */ int32_t current_index_by_slot[/* active slot count */];

    /*
     * +0x038
     * Secondary preload/previous index by slot.
     * Functions 0x439d80 and 0x43a150 write this.
     */
    /* +0x038 */ int32_t preload_index_by_slot[/* active slot count */];

    /*
     * +0x040
     * Direction/side flag per slot. 0x533010 returns this flag via
     * out_direction_flag, and 0x43a150 compares it to the prior value.
     */
    /* +0x040 */ uint8_t direction_flag_by_slot[/* active slot count */];

    /*
     * +0x044
     * Load-state or transition-ready flag by slot. 0x43a150 and 0x439f40
     * test this before using a freshly loaded wrapper.
     */
    /* +0x044 */ int32_t ready_by_slot[/* active slot count */];

    /*
     * +0x04c
     * Additional state reset by 0x438110. Exact layout unresolved.
     */
    /* +0x04c */ uint8_t aux_state[0x5c];

    /*
     * Conceptual fields from 0x4389b0 and later transition code.
     * Exact offsets are not resolved enough to place them confidently here.
     */
    DrvPathFileSpawn spawn[2];
    int32_t tree_start_node;
    bool transition_fault_0x54f8;

    /*
     * +0x0a8 onward.
     * Route wrapper grid. Several functions compute:
     *
     *   wrapper = this + 0xa8 + (slot + node_index * 2 + 1) * 0xa8
     *
     * The +0x150 stride used by the loader means each drvpath node owns
     * two 0xa8-ish wrapper records plus related effect data.
     */
    /* +0x0a8 */ uint8_t node_wrappers_and_effects[];
} TrackRenderState;
```

The route's conceptual `comp_order[node_index]` is the `compartmentId` copied
into the node wrapper for that ordinal. I avoid giving it a separate confirmed
offset because the disassembly mostly accesses it through wrapper records.

### Node wrapper / render resource state

Observed from `0x437130`, `0x437200`, `0x437540`, `0x43a910`, and `0x43a970`:

```c
typedef struct CompartmentWrapper {
    /* +0x00 */ int32_t compartment_id;      /* copied from drvpath compartmentId */
    /* +0x04 */ uint32_t unknown_04;
    /* +0x08 */ uint32_t unknown_08;

    /* +0x3c */ void *async_load_handle;     /* comp%02d.viv async load handle */
    /* +0x44 */ int32_t requested_comp_id;   /* used to format comp%02d.viv */
    /* +0x48 */ bool loaded;                 /* set after 0x43a970 completes */

    /*
     * +0x84 and +0xa0/+0xa4 are used by mesh.sim, particle.mpb,
     * particle.fsh, and lightglow.dat initialization in 0x437540.
     */
    /* +0x84 */ uint8_t mesh_sim_state[0x1c];
    /* +0xa0 */ void *particle_manager;
    /* +0xa4 */ void *track_lightglow;
} CompartmentWrapper;
```

### Active object / anchor source

The global pointer table at `0x6d1e2c` is heavily referenced. In this render path
it is indexed by the active slot/player/camera context:

```c
typedef struct ActiveRenderContext {
    uint8_t unknown_000[0x120];

    /*
     * 0x43a3f0 and 0x439f40 read a Vec3 from object + 0x120 and pass it to
     * 0x43b4f0. The point-in-region test uses X and Z only in the visible
     * disassembly.
     */
    /* +0x120 */ float anchor_x;
    /* +0x124 */ float anchor_y;
    /* +0x128 */ float anchor_z;

    /* 0x439aa0 also reads object + 0x12c and deeper state. */
    /* +0x12c */ void *mode_or_camera_state;
} ActiveRenderContext;

extern ActiveRenderContext *g_active_contexts[]; /* base observed at 0x6d1e2c */
```

Interpretation:

```text
`anchor_x/y/z` is probably the player's/camera's active world position or a
closely related render anchor. The state machine uses it to decide if the
active context is inside a neighboring route region. This is separate from
`[PlayerCopN].posX/Y/Z`, which is parsed during setup but was not seen in the
state-switch decision path.
```

### Engine accessor used by state switch

Observed function `0x533010`:

```c
typedef struct CurrentIndexSource {
    uint8_t unknown_000[0x38];
    /*
     * Not a clean C layout yet:
     * - flag table is read at +0x38 + slot * 4
     * - index table is read at +0x40 + slot * 4
     */
} CurrentIndexSource;

static void get_current_index_0x533010(
    CurrentIndexSource *src,
    int slot,
    int32_t *out_index,
    bool *out_direction_flag
) {
    *out_index = *(int32_t *)((uint8_t *)src + 0x40 + slot * 4);
    *out_direction_flag = (*(int32_t *)((uint8_t *)src + 0x38 + slot * 4) != 0);
}
```

The caller obtains `src` from:

```c
global_0x83c024->field_0x84
```

## Disassembly Pseudocode

This section intentionally keeps C-like pseudocode close to the disassembly.
Names are descriptive labels, not recovered symbols.

### Load `drvpath.ini` and per-node effects, `0x4389b0`

```c
void load_track_render_state_0x4389b0(TrackRenderState *st) {
    Ini lighting = open_ini(build_level_path("lighting.ini"));

    read_float(lighting, "TrackGlows", "GlowDistScale", &g_glow_dist_scale);
    read_float(lighting, "TrackGlows", "GlowFadeScale", &g_glow_fade_scale);
    read_float(lighting, "TrackGlows", "GlowScale", &g_glow_scale);
    read_float(lighting, "TrackShadow", "ShadowColorR", &g_shadow_r);
    read_float(lighting, "TrackShadow", "ShadowColorG", &g_shadow_g);
    read_float(lighting, "TrackShadow", "ShadowColorB", &g_shadow_b);
    read_float(lighting, "TrackShadow", "ShadowColorA", &g_shadow_a);

    Ini drv = open_ini(build_level_path("drvpath.ini"));

    st->node_count = 0;
    read_int(drv, "path", "nodenum", &st->node_count);
    if (st->node_count >= 0x40) {
        st->node_count = 0x3f;
    }

    /*
     * The real code chooses between PlayerCop%d and Tree%dEvent%d depending
     * on current race/tree-event state. Both paths only read startNode here;
     * PlayerCop also reads posX/Y/Z into two spawn records.
     */
    if (has_player_cop_context()) {
        for (int i = 0; i < 2; i++) {
            char section[256];
            sprintf(section, "PlayerCop%d", i + 1);
            read_int(drv, section, "startNode", &st->spawn[i].startNode);
            read_float(drv, section, "posX", &st->spawn[i].posX);
            read_float(drv, section, "posY", &st->spawn[i].posY);
            read_float(drv, section, "posZ", &st->spawn[i].posZ);
        }
    } else {
        char section[256];
        sprintf(section, "Tree%dEvent%d", tree_index, event_index);
        read_int(drv, section, "startNode", &st->tree_start_node);
    }

    for (int node = 0; node < st->node_count; node++) {
        char section[256];
        sprintf(section, "node%d", node);

        CompartmentWrapper *a = node_primary_wrapper(st, node);
        CompartmentWrapper *b = node_secondary_wrapper(st, node);
        init_wrapper_0x437130(a, node);
        init_wrapper_0x437130(b, node);

        read_int(drv, section, "compartmentId", &a->compartment_id);
        read_int(drv, section, "compartmentId", &b->compartment_id);

        sprintf(section, "effects%d", node);
        DrvPathFileEffects *fx = effects_for_node(st, node);

        *fx = default_effects();
        read_int(drv, section, "BaseEqSun", &fx->baseEqSun);
        read_float(drv, section, "sunFogDensity", &fx->sunFogDensity);
        read_float(drv, section, "sunFogSkyDensity", &fx->sunFogSkyDensity);
        read_rgb(drv, section, "sunFogColorR", "sunFogColorG", "sunFogColorB",
                 &fx->sunFogColor);

        if (!fx->baseEqSun) {
            read_float(drv, section, "baseFogDensity", &fx->baseFogDensity);
            read_float(drv, section, "baseFogSkyDensity", &fx->baseFogSkyDensity);
            read_rgb(drv, section, "baseFogColorR", "baseFogColorG", "baseFogColorB",
                     &fx->baseFogColor);
        } else {
            fx->baseFogDensity = fx->sunFogDensity;
            fx->baseFogSkyDensity = fx->sunFogSkyDensity;
            fx->baseFogColor = fx->sunFogColor;
        }

        read_float(drv, section, "ngcFogFarClip", &fx->ngcFogFarClip);
        read_float(drv, section, "ngcFogNearClip", &fx->ngcFogNearClip);
        read_float(drv, section, "ngcFogSkyFog", &fx->ngcFogSkyFog);
        read_int(drv, section, "ngcFogType", &fx->ngcFogType);
        read_int(drv, section, "ngcFogRangeAdjust", &fx->ngcFogRangeAdjust);
        read_int(drv, section, "ngcFogRampFramespan", &fx->ngcFogRampFramespan);
        read_rgb(drv, section, "ngcFogColorR", "ngcFogColorG", "ngcFogColorB",
                 &fx->ngcFogColor);
    }

    reset_aux_state_0x438110(&st->aux_state);
}
```

### Ring helper functions, `0x439b50`, `0x439c00`, `0x439b90`, `0x439c40`

```c
int next_index_0x439b50(TrackRenderState *st, int slot) {
    int cur = st->current_index_by_slot[slot];
    return (cur == st->node_count - 1) ? 0 : cur + 1;
}

int prev_index_0x439c00(TrackRenderState *st, int slot) {
    int cur = st->current_index_by_slot[slot];
    return (cur == 0) ? st->node_count - 1 : cur - 1;
}

int two_ahead_0x439b90(TrackRenderState *st, int slot) {
    int cur = st->current_index_by_slot[slot];
    if (cur == st->node_count - 1) return 1;
    if (cur == st->node_count - 2) return 0;
    return cur + 2;
}

int two_behind_0x439c40(TrackRenderState *st, int slot) {
    int cur = st->current_index_by_slot[slot];
    if (cur == 1) return st->node_count - 1;
    if (cur == 0) return st->node_count - 2;
    return cur - 2;
}
```

### Main per-frame update caller, `0x4d00a0`

```c
void level_render_update_0x4d00a0(bool render_enabled) {
    /*
     * Large function. Only the track render-state decision branch is shown.
     */

    TrackRenderState *state = global_0x83c024->track_render_state_0x24;
    bool event_mode = (global_0x83c024->track_info_0x48->field_0x8c != 0);

    if (!event_mode) {
        update_track_render_state_0x439f40(state, render_enabled);
    } else {
        update_track_render_state_event_0x43a3f0(state, render_enabled);
    }

    update_other_level_systems();
}
```

### Non-event update path, `0x439f40`

```c
void update_track_render_state_0x439f40(TrackRenderState *st, bool render_enabled) {
    /*
     * First it applies/render-updates a sentinel wrapper at:
     * st + st->node_count * 0x150 + 0xa8.
     */
    update_wrapper_render_state_0x437d50(sentinel_wrapper(st), render_enabled);

    int active_slots = global_0x83c024->track_info_0x48->active_slot_count_0xb0;

    for (int slot = 0; slot < active_slots; slot++) {
        int cur = st->current_index_by_slot[slot];

        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, cur), render_enabled);
        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, next_index_0x439b50(st, slot)),
                                             render_enabled);
        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, prev_index_0x439c00(st, slot)),
                                             render_enabled);

        if (!render_enabled) {
            continue;
        }

        /*
         * Several branches deal with loaded/preloaded wrappers and direction.
         * The important behavior is that the active runtime anchor is tested
         * against next/current/previous region data. If a test succeeds, the
         * state advances and the next preload is started.
         */
        if (should_check_region_transition(st, slot)) {
            Vec3 anchor = g_active_contexts[slot]->anchor_at_0x120;

            if (point_in_region_0x43b4f0(region_for(st, slot, CURRENT), &anchor) ||
                point_in_region_0x43b4f0(region_for(st, slot, NEXT), &anchor) ||
                point_in_region_0x43b4f0(region_for(st, slot, PREVIOUS), &anchor)) {
                prepare_neighbor_preload_0x43a7f0(st, slot);
                advance_preload_target_0x439d80(st, slot);
            } else {
                st->transition_fault_0x54f8 = 1;
                global_0x83c024->state_manager_0x60->state_0x24 = 0x17;
            }
        }
    }
}
```

### Event-aware update path, `0x43a3f0`

```c
void update_track_render_state_event_0x43a3f0(TrackRenderState *st, bool render_enabled) {
    update_wrapper_render_state_0x437d50(sentinel_wrapper(st), render_enabled);

    int active_slots = global_0x83c024->track_info_0x48->active_slot_count_0xb0;

    for (int slot = 0; slot < active_slots; slot++) {
        int cur = st->current_index_by_slot[slot];

        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, cur), render_enabled);
        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, next_index_0x439b50(st, slot)),
                                             render_enabled);
        update_wrapper_render_state_0x437d50(wrapper_for(st, slot, prev_index_0x439c00(st, slot)),
                                             render_enabled);

        if (render_enabled && !st->transition_fault_0x54f8) {
            switch_render_state_0x43a150(st, slot);

            Vec3 anchor = g_active_contexts[slot]->anchor_at_0x120;
            if (!point_in_region_0x43b4f0(region_for(st, slot, CURRENT), &anchor) &&
                !point_in_region_0x43b4f0(region_for(st, slot, NEXT), &anchor) &&
                !point_in_region_0x43b4f0(region_for(st, slot, PREVIOUS), &anchor)) {
                st->transition_fault_0x54f8 = 1;
                global_0x83c024->state_manager_0x60->state_0x24 = 0x17;
            }
        }
    }
}
```

### Switch render-state decision, `0x43a150`

```c
void switch_render_state_0x43a150(
    TrackRenderState *st,
    int slot
) {
    int current_from_engine;
    bool new_direction_flag;

    /*
     * The real code passes a pointer to a byte inside the stack slot argument
     * as the direction output. Treat it as a local bool, not as a caller input.
     */
    get_current_index_0x533010(
        global_0x83c024->index_source_0x84,
        slot,
        &current_from_engine,
        &new_direction_flag
    );

    int old = st->current_index_by_slot[slot];
    if (old == current_from_engine) {
        /*
         * No index switch. It can still poll the pending preload wrapper and
         * update direction-dependent wrapper state.
         */
        if (!st->ready_by_slot[slot]) {
            int preload = st->preload_index_by_slot[slot];
            bool ready = poll_compartment_load_0x43a970(wrapper_for(st, slot, preload));
            st->ready_by_slot[slot] = ready ? 1 : 0;
            if (!ready) {
                return;
            }
        }

        if (st->direction_flag_by_slot[slot] != new_direction_flag) {
            /*
             * This is the "player changed side/direction without a boundary
             * index change" case. The real branch mirrors 0x439aa0:
             * - if the old flag was nonzero, unload old + 2 with wrap
             * - if the old flag was zero, unload old - 2 with wrap
             * Then it preloads the two-away wrapper for the new flag.
             */
            int unload_index = two_away_for_old_direction(st, old,
                                                          st->direction_flag_by_slot[slot]);
            unload_wrapper_0x43a9d0(wrapper_for(st, slot, unload_index));
            st->direction_flag_by_slot[slot] = new_direction_flag;
            st->preload_index_by_slot[slot] =
                new_direction_flag ? wrap_index(old + 2, st->node_count)
                                   : wrap_index(old - 2, st->node_count);
            start_compartment_load_0x43a910(
                wrapper_for(st, slot, st->preload_index_by_slot[slot]),
                comp_id_for_index(st, st->preload_index_by_slot[slot])
            );
            st->ready_by_slot[slot] = 0;
        }
        return;
    }

    /*
     * The new index must be adjacent in the circular drvpath ring.
     * Otherwise the function marks a state fault/reset through
     * global_0x83c024->state_manager_0x60->state_0x24 = 0x17.
     */
    if (current_from_engine != next_index_value(st, old) &&
        current_from_engine != prev_index_value(st, old)) {
        st->transition_fault_0x54f8 = 1;
        global_0x83c024->state_manager_0x60->state_0x24 = 0x17;
        return;
    }

    /*
     * Normal adjacent transition:
     * - unload stale wrapper in the direction opposite the move
     * - update current_index_by_slot from the direction/side flag
     * - choose the next preload target on the opposite side
     * - start loading comp%02d.viv for that target
     */
    int stale = choose_stale_wrapper_for_transition(st, slot, old, current_from_engine,
                                                    new_direction_flag);
    unload_wrapper_0x437180_or_0x43a9d0(wrapper_for(st, slot, stale));

    st->direction_flag_by_slot[slot] = new_direction_flag;
    if (new_direction_flag) {
        st->current_index_by_slot[slot] = wrap_index(current_from_engine - 1, st->node_count);
        st->preload_index_by_slot[slot] = wrap_index(current_from_engine + 1, st->node_count);
    } else {
        st->current_index_by_slot[slot] = wrap_index(current_from_engine + 1, st->node_count);
        st->preload_index_by_slot[slot] = wrap_index(current_from_engine - 1, st->node_count);
    }

    start_compartment_load_0x43a910(
        wrapper_for(st, slot, st->preload_index_by_slot[slot]),
        comp_id_for_index(st, st->preload_index_by_slot[slot])
    );
    st->ready_by_slot[slot] = 0;
}
```

### Load and poll `comp%02d.viv`, `0x43a910` and `0x43a970`

```c
void start_compartment_load_0x43a910(CompartmentWrapper *w, int comp_id) {
    char path[260];

    sprintf(path, "%s%s\\comp%02d.viv",
            global_0x83c024->base_path_0x04 + 0x20c,
            global_0x83c024->track_path_0x28 + 0x8c,
            w->compartment_id);

    w->requested_comp_id = comp_id;
    w->async_load_handle = async_load_file(path, comp_id, 0);
    w->loaded = false;
}

bool poll_compartment_load_0x43a970(CompartmentWrapper *w) {
    if (w->loaded) {
        return true;
    }

    if (async_status(w->async_load_handle) == 1) {
        async_complete(w->async_load_handle, 0, NULL);
        w->async_load_handle = NULL;
        w->loaded = true;
        return true;
    }

    return false;
}
```

### Point-in-region test, `0x43b4f0`

```c
bool point_in_region_0x43b4f0(void *region_blob, const Vec3 *anchor) {
    /*
     * The region blob is decoded through helper calls at 0x43ba80 and
     * 0x43b970. The visible math checks X/Z edge orientation for a polygon.
     * Y is present in the Vec3 but not used in the shown comparisons.
     */
    RegionPolygon *poly = decode_region_polygon_0x43ba80(region_blob, anchor);
    if (!poly || poly->edge_count <= 0) {
        return false;
    }

    for (int i = 0; i < poly->edge_count; i++) {
        Vec3 *a, *b, *c, *d;
        decode_region_edge_0x43b970(poly, i, &a, &b, &c, &d);

        /*
         * Disassembly uses FPU comparisons equivalent to a same-side /
         * edge-orientation test in X/Z space.
         */
        if (outside_edge_xz(anchor, a, b, c, d)) {
            return false;
        }
    }

    return true;
}
```

## Exporter Guidance For Future Agents

If the goal is to mimic the original runtime more faithfully:

```text
1. Parse `drvpath.ini` into:
   - node_count
   - ordered compartment ids
   - per-node effects records
   - PlayerCop/TreeEvent start nodes and positions

2. Treat ordered `compartmentId` values as a circular ring.
   The original helper window uses previous/current/next for immediate
   rendering and +/-2 for load/unload/preload transitions.

3. Do not assume all `compNN.o` files in a theme folder are active at once.
   `drvpath.ini` selects the route's compartment ring.

4. Keep route-local `levelG.o`/`level.fsh` separate from shared compartment
   geometry and textures. The existing exporter already follows that pattern.

5. If implementing runtime-like culling, add a state object with:
   - current_index_by_slot
   - preload_index_by_slot
   - direction_flag_by_slot
   - a loaded/unloaded wrapper state for prev/current/next/two-neighbor windows

6. Do not use `[PlayerCopN].posX/Y/Z` as the render-state transition anchor
   unless new dynamic evidence proves it. The disassembly points at a runtime
   active-context vector at `g_active_contexts[slot] + 0x120`.

7. If a debug viewer keeps using "project the camera to nearest route" instead
   of HP2's real region-polygon tests, do not collapse that result to one
   nearest node only. Keep at least:
   - projected boundary/index
   - route-distance movement sign or side flag
   - current render index derived from the side flag
   - two-away preload side derived from the same flag

   Otherwise reverse travel can choose the wrong current/preload side at a
   boundary even though the projection itself is reasonable.
```

Current Godot debug viewer status:

```text
The Godot debug viewer intentionally approximates HP2's region-polygon test by
projecting the debug camera/player position onto the route. The approximation
must still keep the `drvpath.ini` node ring as the source of truth.

Do not derive route-node anchors from compartment AABB centers. That was tested
and caused a visible Medit level00 bug: comp15/node7 projected near the
node10->node0 seam, so the viewer selected node7 around the seam and rendered
the wrong neighbor set instead of the HP2-style prev/current/next window.
The result was missing road geometry near node10/node0.

The current Godot fix keeps route-node positions in route-distance order via
EaglTrackRoute._rebuild_default_route_nodes() / use_default_route_node_anchors().
The minimap may display all nodes, but blue inactive boxes and orange preload
dots are debug markers only; the circular render-state order remains numeric
node order from drvpath.
```

Current local parser gaps:

```text
map_otools/parsers/drvpath.py currently keeps only compartment_ids and
start_nodes. It orders compartment_ids by numeric `nodeN` ordinal from
`[path].nodenum`, not physical file section order. It drops PlayerCop
positions and effects blocks.

To model original render-state behavior later, extend it to parse:
  - nodenum
  - node ordinal -> compartmentId
  - PlayerCopN startNode and posX/Y/Z
  - Tree%dEvent%d startNode if needed
  - effectsN fog/glow keys
```
