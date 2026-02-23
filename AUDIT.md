# Codebase Audit Against Skills

Audit of the current codebase against the 8 architecture skills defined in `.claude/skills/`.

---

## 1. ZII Pattern (Zero Is Initialization)

**Status: Mostly Compliant, 2 violations in game code**

### What's correct

- `Game_State` fields (`time`, `reload_count`, `clear_hue`) are all valid at zero — a freshly zeroed block is a valid starting state.
- `game_load` resets via `state^ = {}` (zero-init) rather than field-by-field.
- `Game_Module.is_loaded` is `false` when zeroed — safe default.
- `Log_Level` enum zero value is `.Debug` — benign default, not an "active" state.
- `Engine` struct zero-init means all Vulkan handles are nil — valid "not yet initialized" state.

### Violations

1. **`get_state()` returns `nil` instead of a nil sentinel** (`game/game.odin:13`). The ZII skill says: *"Never return null/nil pointers from lookup functions — return the nil sentinel."* If `memory` is nil or too small, this returns a raw nil pointer.

2. **Explicit nil checks in game logic** (`game/game.odin:31,42,51,61`). Every game proc does `if state == nil { return }`. The ZII skill says: *"Never write `if entity != nil` before accessing entity properties — rely on ZII defaults."* With a nil sentinel, these checks would be unnecessary.

### Recommended fix

Add a package-level zero-initialized `Game_State` stub. Have `get_state()` return `&nil_game_state` on failure instead of `nil`. Remove the nil checks from `game_load`, `game_unload`, `game_reload`, and `game_update`.

---

## 2. Memory Arenas

**Status: Well Implemented, 2 gaps**

### What's correct

- Three arenas with distinct lifetimes (app, frame, swapchain) — matches the skill exactly.
- Arena sizes set via `#config` at compile time (`memory.odin:5-7`).
- Frame arena reset at the top of every frame: `free_all(context.temp_allocator)` (`main.odin:472`).
- Swapchain arena reset on every swapchain recreation via `swapchain_memory_reset()` (`vulkan.odin:663`).
- All allocations go through arenas — no raw `malloc`/`free` anywhere.
- Temp allocator used correctly for transient data (queue family queries, extension enumeration, shader loading, file reads).

### Gaps

1. **Fixed `mem.Arena` instead of `virtual.Arena`** (`memory.odin:10-20`). The skill specifically recommends: *"For growable arenas in Odin, prefer `virtual.Arena` (`core:mem/virtual`) — it reserves a large virtual address range upfront and commits physical pages on demand."* The current fixed-size backing arrays have no growth fallback. If the 64 MB app arena is exhausted, the allocator returns a nil pointer — no ZII stub, no graceful degradation.

2. **No OOM ZII stub.** The skill describes: *"Graceful OOM via ZII stub: if the OS refuses memory, return a pointer to a global zero-initialized stub instead of NULL."* The current arenas silently return nil on overflow.

### Note

`frame_commands.quads` uses `[dynamic]Quad_Command` allocated from the app arena. Dynamic arrays grow in bulk (doubling), which is acceptable — but this means render command memory permanently grows in the app arena and is never reclaimed. A fixed-capacity array with a harsh limit (e.g., `MAX_QUADS :: 4096`) would be more aligned with the skill.

---

## 3. Fat Structs

**Status: Not Applicable (no entity system yet)**

The game currently consists of a single procedurally animated quad. No entity system, no game objects, no entity storage.

### When this becomes relevant

As soon as entities (players, enemies, items, particles) are added, this skill prescribes:
- One massive `Entity` struct with all possible fields
- A single `[MAX_ENTITIES]Entity` array allocated once
- Index 0 reserved as nil sentinel
- Flag-based behavior toggling (`Entity_Flags` bitfield)
- No ECS, no inheritance, no vtables

---

## 4. Intrusive Trees

**Status: Not Applicable (no hierarchies)**

No parent-child relationships exist. When entity hierarchies are added (scene graph, inventory, etc.), this skill prescribes embedding `parent_idx`, `first_child_idx`, `next_sibling_idx`, `prev_sibling_idx` directly into the Entity struct.

---

## 5. Generational Handles

**Status: Not Applicable (no cross-references)**

No entity-to-entity references exist. When entities need to reference each other, this skill prescribes `Handle :: struct { index: u32, generation: u32 }` with generation-checked resolution returning the nil sentinel on mismatch.

---

## 6. Multicore Default

**Status: Not Implemented — entire engine is single-threaded**

### Current state

The engine runs entirely on one thread: `main()` → `init()` → `run_main_loop()`. There is no thread infrastructure, no lane system, no work subdivision.

### What the skill prescribes

- Launch one thread per CPU core into a universal entry point at startup
- `lane_idx()` / `lane_count()` thread-local helpers
- `lane_range(count)` for mathematical work subdivision
- `lane_sync()` barriers between phases
- Lane 0 for serial operations (file I/O, GPU submit)

### Impact

At the current stage (single animated quad), single-threaded is adequate. This becomes critical when:
- Entity update loops process hundreds/thousands of entities
- Physics/collision needs parallelization
- Render data packing (filling SSBOs/indirect buffers) needs to happen in parallel

### Violation of skill philosophy

The skill states: *"Never assume code runs single-threaded by default — it's multi-core by default."* The current engine fundamentally violates this. Retrofitting lane-based parallelism later will require restructuring the main loop into phases.

---

## 7. Multicore Vulkan

**Status: Partially Implemented, significant gaps**

### What's correct

- Fence usage is correct for single-frame-in-flight: wait → acquire → record → reset → submit (signal) → present (`main.odin:526-676`).
- `VkPipelineBarrier2` used correctly for image layout transitions (`vulkan.odin:717-735, 788-805`).
- Dynamic rendering (no VkRenderPass/VkFramebuffer) — correct modern approach.
- Semaphore flow: `image_available_semaphore` (acquire → submit wait), `render_finished_semaphore` (submit signal → present wait).

### Gaps

1. **Only 1 frame in flight.** The engine has a single `in_flight_fence`, a single `image_available_semaphore`, and a single command buffer. The skill prescribes 2-3 frames in flight with per-frame fences, semaphores, and command buffers:
   ```
   fences:     [MAX_FRAMES_IN_FLIGHT]vk.Fence
   semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
   cmd_bufs:   [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer
   ```
   With 1 frame in flight, the CPU stalls every frame waiting for the GPU.

2. **Single command pool.** One `VkCommandPool` shared across the (single) thread. The skill prescribes `[MAX_FRAMES_IN_FLIGHT][NUMBER_OF_CORES]vk.CommandPool` — one pool per lane per frame.

3. **No double/triple-buffered dynamic data.** When SSBOs are added (object buffer, indirect draw buffer), they must be duplicated per frame in flight so the CPU can write frame N+1 while the GPU renders frame N.

4. **No multi-core rendering phases.** The skill prescribes: go wide (all lanes pack buffers) → `lane_sync()` → go narrow (lane 0 submits). Currently everything is serial.

5. **Fence reset before submit is not guarded by acquire result.** At `main.odin:609`, `ResetFences` happens after acquire succeeds but before submit. If recording fails between reset and submit, the fence stays unsignaled and the next frame deadlocks. Consider resetting the fence immediately before `QueueSubmit` or after a successful acquire as part of the submit path.

---

## 8. Vulkan Bindless

**Status: Early Stage — push constants used instead of bindless architecture**

### What aligns

- **No VkVertexInputState attributes** (`vulkan.odin:883-885`). The pipeline has an empty vertex input — no attribute/binding descriptions. This is correct for vertex pulling.
- **Vertex pulling by `gl_VertexIndex`** (`triangle.vert:20`). The vertex shader indexes into hardcoded positions using `gl_VertexIndex`. This is the right pattern, just with hardcoded data rather than an SSBO.
- **Single pipeline** (`vulkan.odin:974`). One graphics pipeline for all rendering — matches the uber shader approach.

### Gaps

1. **Per-draw push constants instead of bindless SSBOs.** Each quad is drawn with its own `vkCmdPushConstants` + `vkCmdDraw` call (`vulkan.odin:772-783`). The skill says: *"Never call vkCmdDraw in a loop per entity — use vkCmdDrawIndirect once."* Push constants are limited to 128 bytes on many GPUs and require one draw call per object.

2. **No VertexBuffer SSBO.** Quad vertices are hardcoded in the shader. The skill prescribes a giant SSBO (`layout(std140, set=0, binding=0) readonly buffer VertexBuffer`) containing all geometry, with the vertex shader fetching via `gl_VertexIndex`.

3. **No ObjectBuffer SSBO.** Per-object data (transforms, materials) should be in `layout(std140, set=0, binding=1) readonly buffer ObjectBuffer`, indexed by `gl_InstanceIndex`. Currently this data is delivered per-draw via push constants.

4. **No Indirect Draw Buffer.** The skill prescribes CPU lanes filling a `VkDrawIndirectCommand` buffer in parallel, then one `vkCmdDrawIndirect` call. Currently: N draw calls for N quads.

5. **No descriptor sets.** The pipeline layout has zero descriptor set layouts — only push constant ranges. The skill prescribes one global descriptor set with bindings for VertexBuffer, ObjectBuffer, and optionally a texture array.

6. **No persistently mapped buffers.** When SSBOs are added, they should be host-visible and persistently mapped at startup — never map/unmap per frame.

---

## Summary Matrix

| Skill | Status | Severity |
|---|---|---|
| ZII Pattern | 2 violations (nil returns, nil checks in game) | Low — easy fix |
| Memory Arenas | Well implemented, missing `virtual.Arena` + OOM stub | Medium |
| Fat Structs | N/A — no entity system yet | — |
| Intrusive Trees | N/A — no hierarchies yet | — |
| Generational Handles | N/A — no cross-references yet | — |
| Multicore Default | Not implemented — fully single-threaded | High (architectural) |
| Multicore Vulkan | 1 frame in flight, no per-lane pools | High (perf + architectural) |
| Vulkan Bindless | Push constants, per-draw calls, no SSBOs | High (architectural) |

## Recommended Priority Order

1. **ZII fixes** — Small, isolated changes. Fix `get_state()` and remove nil checks.
2. **Memory: `virtual.Arena`** — Switch from fixed `mem.Arena` to growable `virtual.Arena`.
3. **Frames in flight** — Add `MAX_FRAMES_IN_FLIGHT :: 2`, duplicate fences/semaphores/command buffers per frame index. This is a prerequisite for everything else.
4. **Bindless rendering** — Replace push constants with VertexBuffer SSBO + ObjectBuffer SSBO + indirect draw. This restructures the entire rendering path.
5. **Multi-core infrastructure** — Add lane system, per-lane command pools, phase-based main loop. This is the largest architectural change and depends on having the bindless buffer layout in place first (so lanes have buffers to write into).
6. **Entity system** — When game logic demands it, add the fat struct entity array with intrusive tree hierarchy and generational handles.
