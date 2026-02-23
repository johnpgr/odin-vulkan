# Phase 1: 3D Depth Buffer + Perspective Camera + Colored Cube

## Context
Engine currently renders 2D quads only — no depth, no 3D transforms, no vertex buffers.
Goal: add a second GPU pipeline for 3D mesh rendering, expose it via Engine_API, and render a spinning colored cube in-game. Foundation for glTF loading (Phase 2).

---

## Approach: parallel 3D pipeline alongside quad pipeline

Keep quad pipeline intact. Add a second pipeline (`mesh_pipeline`) with:
- depth testing enabled
- vertex attributes (position + vertex color)
- push constants: `mat4 mvp` (64 bytes) + `vec4 color` (16 bytes) = 80 bytes total
- hardcoded cube geometry uploaded at engine init

Camera controlled by game via `set_camera(eye, target)`.
Engine computes view + projection per-frame (projection from swapchain aspect).

**Vulkan-specific corrections applied:**
- Projection Y-axis negated (`proj[1][1] *= -1`) for Vulkan top-down clip space
- Depth range mapped to [0,1] (Vulkan) not [-1,1] (OpenGL)
- Mesh pipeline uses `frontFace = .COUNTER_CLOCKWISE` (standard convention)

---

## Files to Create

### `engine/shaders/mesh.vert`
```glsl
#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec4 in_color;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
} push;

layout(location = 0) out vec4 v_color;

void main() {
    gl_Position = push.mvp * vec4(in_position, 1.0);
    v_color = in_color * push.color;
}
```

### `engine/shaders/mesh.frag`
```glsl
#version 450

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = v_color;
}
```

---

## Files to Modify

### `shared/game_api.odin`
- Add `Engine_Set_Camera_Proc :: proc(eye_x, eye_y, eye_z, tx, ty, tz: f32)`
- Add `Engine_Draw_Cube_Proc :: proc(model: mat4, r, g, b, a: f32)`
  - Game builds full model matrix (translate × rotate × scale) — allows spinning
- Add both to `Engine_API` struct
- Bump `GAME_API_VERSION` to `2`

### `engine/vulkan.odin`

**New types:**
```odin
Mesh_Vertex :: struct { pos: vec3, color: vec4 }  // 28 bytes

Mesh_Command :: struct { model: mat4, color: vec4 }

Mesh_Push_Constants :: struct { mvp: mat4, color: vec4 }  // 80 bytes

Gpu_Buffer :: struct { handle: vk.Buffer, memory: vk.DeviceMemory }
```

**Extend `SwapchainContext`:**
```odin
depth_image:      vk.Image
depth_image_view: vk.ImageView
depth_memory:     vk.DeviceMemory
```

**New procs:**
- `create_depth_image(device, physical_device, extent) -> (image, view, memory, bool)`
  - format `D32_SFLOAT`, usage `DEPTH_STENCIL_ATTACHMENT`, memory `DEVICE_LOCAL`
- `destroy_depth_image(device, image, view, memory)`
- `create_device_local_buffer(device, pd, cmd_pool, queue, data_ptr, data_size, usage) -> (Gpu_Buffer, bool)`
  - staging pattern: HOST_VISIBLE staging → copy cmd → DEVICE_LOCAL final → destroy staging
- `create_mesh_pipeline(device, image_format, depth_format, shader_stages, descriptor_layout) -> (layout, pipeline, bool)`
  - depth test: LESS, depth write: true
  - vertex input: binding 0, stride `size_of(Mesh_Vertex)` = 28
    - attr 0: pos `R32G32B32_SFLOAT` offset 0
    - attr 1: color `R32G32B32A32_SFLOAT` offset 12
  - push constants: 80 bytes, stages `{.VERTEX, .FRAGMENT}`
  - rasterizer: `frontFace = .COUNTER_CLOCKWISE`, cull back faces
  - PipelineRenderingCreateInfo: `depthAttachmentFormat = .D32_SFLOAT`
- Extend `destroy_swapchain_context`: destroy depth image/view/memory if present
- Extend `create_swapchain_context`: call `create_depth_image` after swapchain images

**Modify `record_command_buffer` signature — add params:**
```
depth_image_view: vk.ImageView
mesh_pipeline:    vk.Pipeline
mesh_layout:      vk.PipelineLayout
cube_vbuf:        Gpu_Buffer
cube_ibuf:        Gpu_Buffer
mesh_commands:    []Mesh_Command
view_matrix:      mat4
proj_matrix:      mat4
```

**Inside `record_command_buffer`:**
1. Add depth attachment to `RenderingInfo`:
   - `loadOp = .CLEAR`, `storeOp = .DONT_CARE`, clear value = 1.0
   - `imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL`
2. Draw quads first (unchanged, unaffected by depth — they write z=0.0)
3. Bind mesh_pipeline, vertex buffer, index buffer
4. For each Mesh_Command:
   - Compute `mvp = proj * view * cmd.model`
   - Push constants: `Mesh_Push_Constants{mvp, cmd.color}`
   - `vkCmdDrawIndexed(36, 1, 0, 0, 0)`

### `engine/main.odin`

**New fields in `Engine`:**
```odin
mesh_vert_module:     vk.ShaderModule
mesh_frag_module:     vk.ShaderModule
mesh_shader_stages:   [2]vk.PipelineShaderStageCreateInfo
mesh_pipeline_layout: vk.PipelineLayout
mesh_pipeline:        vk.Pipeline
cube_vbuf:            Gpu_Buffer
cube_ibuf:            Gpu_Buffer
camera_eye:           vec3
camera_target:        vec3
```

**Extend `Frame_Commands`:**
```odin
meshes: [dynamic]Mesh_Command
```

**Extend `App_Callback_Context`:**
```odin
camera_eye:    ^vec3   // points into Engine.camera_eye
camera_target: ^vec3   // points into Engine.camera_target
```
Set these pointers in `init` alongside existing callback setup.

**New callbacks:**
```odin
engine_set_camera :: proc(ex, ey, ez, tx, ty, tz: f32) {
    if app_callback_context.camera_eye == nil do return
    app_callback_context.camera_eye^    = {ex, ey, ez}
    app_callback_context.camera_target^ = {tx, ty, tz}
}

engine_draw_cube :: proc(model: mat4, r, g, b, a: f32) {
    if app_callback_context.commands == nil do return
    append(&app_callback_context.commands.meshes, Mesh_Command{
        model = model,
        color = {r, g, b, a},
    })
}
```

**In `init` (after existing pipeline):**
1. Load `mesh.vert.spv` + `mesh.frag.spv`
2. `create_mesh_pipeline(...)` with depth format `D32_SFLOAT`
3. Build cube vertex data (8 × Mesh_Vertex, white vertex colors)
4. Build cube index data (36 × u16)
5. Upload both via `create_device_local_buffer` using `frames[0].command_pools[0]`
6. Set default camera: eye={0,3,6}, target={0,0,0}

**In main loop (after quad_count copy):**
```odin
// Compute view + projection
aspect := f32(extent.width) / f32(extent.height)
proj := linalg.matrix4_perspective_f32(math.to_radians(f32(45)), aspect, 0.1, 100.0)
proj[1][1] *= -1  // Vulkan Y-flip

view := linalg.matrix4_look_at_f32(e.camera_eye, e.camera_target, {0, 1, 0})

// Pass to record_command_buffer along with mesh_commands slice
```

Clear `e.frame_commands.meshes` each frame alongside quads.

**In `cleanup`:** destroy mesh pipeline, layout, shader modules, cube_vbuf, cube_ibuf

**Swapchain recreation:** extend `recreate_swapchain_and_pipeline` to also destroy+recreate `mesh_pipeline` (depth image is already handled via SwapchainContext).

### `game/game.odin`
```odin
import "core:math/linalg"

// in game_update:
api.set_clear_color(0.53, 0.81, 0.92, 1.0)  // sky blue
api.set_camera(0, 3, 6, 0, 0, 0)

// spinning cube
angle := state.time
rot := linalg.matrix4_rotate_f32(angle, {0, 1, 0})
model := rot  // centered at origin, unit scale
api.draw_cube(model, 0.8, 0.4, 0.2, 1.0)  // orange
```

Bump `game_get_api_version` to return `2`.

---

## Cube Geometry

8 vertices, white vertex colors (tint via push constant):
```
v0: (-0.5,-0.5,-0.5)  v1: ( 0.5,-0.5,-0.5)
v2: ( 0.5, 0.5,-0.5)  v3: (-0.5, 0.5,-0.5)
v4: (-0.5,-0.5, 0.5)  v5: ( 0.5,-0.5, 0.5)
v6: ( 0.5, 0.5, 0.5)  v7: (-0.5, 0.5, 0.5)
```

36 indices (CCW winding from outside, matching `frontFace = .COUNTER_CLOCKWISE`):
```
front:  4,5,6, 4,6,7    back:    1,0,3, 1,3,2
right:  5,1,2, 5,2,6    left:    0,4,7, 0,7,3
top:    3,2,6, 3,6,7    bottom:  4,5,1, 4,1,0
```

---

## Vulkan Projection Fix

`linalg.matrix4_perspective_f32` produces OpenGL-style projection.
Two corrections needed for Vulkan:

1. **Y-flip**: `proj[1][1] *= -1` (Vulkan Y points down in clip space)
2. **Depth [0,1]**: verify `linalg` output. If depth maps to [-1,1], remap:
   - At impl time: check if `flip_z_axis=true` param produces [0,1] mapping
   - Fallback: manually adjust `proj[2][2]` and `proj[3][2]`

---

## Staging Buffer Upload Pattern

```
1. create HOST_VISIBLE mapped buffer (staging) via create_mapped_buffer
2. mem.copy(staging.mapped, data_ptr, byte_size)
3. create DEVICE_LOCAL buffer (final) — not mapped, usage includes TRANSFER_DST
4. alloc temp command buffer from frames[0].command_pools[0]
5. begin + record vkCmdCopyBuffer(staging → final) + end
6. submit to graphics_queue + vkQueueWaitIdle
7. free temp command buffer
8. destroy_mapped_buffer(staging)
```

---

## Swapchain Recreation

`recreate_swapchain_and_pipeline` must also recreate mesh pipeline.
Depth image is part of SwapchainContext — recreated automatically with swapchain.
Extend function signature to accept mesh shader stages, return new mesh pipeline handles.

---

## Verification

1. `lua build_shaders.lua` — compiles mesh.vert + mesh.frag → .spv (no errors)
2. `lua build.lua` — builds engine + game (no compile errors)
3. Run: spinning orange cube on sky-blue background with perspective depth
4. Resize window: depth buffer + aspect ratio update correctly (no stretching/crash)
5. Hot-reload: `lua build.lua game` while running — cube persists, state survives
