## Build

The build script is `build.lua` (Lua 5.x). Run it from the project root:

```sh
lua build.lua
```

This builds two targets in order:
1. Builds `engine/` → `bin/odingame.exe`
2. Builds `game/` → `bin/game.dll`

**Prerequisites:** Odin compiler on PATH, `VULKAN_SDK` env var set (Windows/macOS).

**Debug vs release:** Debug is default (`lua build.lua`). Use `lua build.lua release` for optimized/non-console build.

**Run:**
```sh
bin/odingame.exe        # Windows
./bin/odingame          # Linux/macOS
```

**Build just the game DLL** (hot-reload workflow — engine stays running):
```sh
lua build.lua game
# release game-only build:
lua build.lua game release
```

The engine detects the new DLL automatically via mtime polling and reloads it within the current frame.

**Build shaders:** run `lua build_shaders.lua` to compile all `engine/shaders/*.vert` and `*.frag` to `.spv`.

**Add a new shader:** drop a `.vert` or `.frag` file into `engine/shaders/`, then run `lua build_shaders.lua`. Load it at runtime with `load_shader(device, "myshader.vert")`.

There are no tests or linting tools.

## Architecture

Three Odin packages with a strict ownership model:

| Package | Output | Role |
|---|---|---|
| `engine/` | `bin/odingame.exe` | Host process: Vulkan, GLFW, frame loop, hot-reload |
| `game/`   | `bin/game.dll`     | Game logic only — no persistent allocations |
| `shared/` | (compile-time only) | Versioned ABI structs shared by both |

Packages use relative imports (`import shared "../shared"`), not Odin collections.

### Shared ABI (`shared/game_api.odin`)

`Engine_API` — function pointers the engine fills in and passes down to the game:
- `draw_quad(x, y, w, h, r, g, b, a)` — enqueues a `Quad_Command` into `Frame_Commands`
- `set_clear_color(r, g, b, a)` — sets the background clear colour for this frame
- `log`, `get_dt`, `is_key_down`

`Game_API` — function pointers the engine resolves from the DLL after each load:
- `get_api_version() → u32` — must match `GAME_API_VERSION` or reload is aborted
- `get_memory_size() → int` — tells the engine how many bytes to allocate for game state
- `load`, `update`, `unload`, `reload` — all receive `(api, memory, memory_size)`

**When changing `Engine_API` or `Game_API` structs, bump `GAME_API_VERSION`** so mismatched DLLs are rejected cleanly.

### Hot-Reload Mechanism

The engine polls `game.dll` mtime every frame. On change:

1. `vk.DeviceWaitIdle` — GPU must be idle before touching game state
2. `game_api.unload(api, memory)` — game serializes any transient state
3. `dynlib.unload_library`
4. Read `game.dll` bytes → write to `game_loaded.dll` → `dynlib.load_library(game_loaded.dll)`
   - The copy releases the OS file lock on `game.dll`, letting the compiler overwrite it while the engine runs
5. Resolve and bind all exported symbols; verify `api_version`
6. `game_api.reload(api, memory)` — game restores from the same memory block

**Game state is engine-owned memory.** `get_memory_size()` is called once at startup; the engine allocates that many bytes and passes `rawptr + size` on every call. The game must not hold heap allocations that survive across `unload/reload`. Cast the pointer to `^Game_State` inside each proc.

### Rendering

The engine uses **Vulkan 1.3 dynamic rendering** — no `VkRenderPass` or `VkFramebuffer` objects exist.

Frame loop (simplified):
1. `game_update()` populates `Frame_Commands` (a `clear_color` + `[dynamic]Quad_Command`)
2. `AcquireNextImageKHR` → `image_index`
3. Pipeline barrier: `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL`
4. `CmdBeginRendering` with inline attachment (clears to `clear_color`)
5. For each `Quad_Command`: `CmdPushConstants(rect, color)` + `CmdDraw(6, 1, 0, 0)`
6. `CmdEndRendering`
7. Pipeline barrier: `COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR`
8. `QueueSubmit` → `QueuePresentKHR`

Quads have no vertex buffer. The vertex shader (`triangle.vert`) indexes into 6 hardcoded NDC positions using `gl_VertexIndex`. Push constants deliver `rect` (xy = position, zw = size in NDC) and `color` per draw call.

Swapchain recreation (triggered by `SUBOPTIMAL_KHR` or `ERROR_OUT_OF_DATE_KHR`) rebuilds the swapchain, pipeline, and per-image semaphores atomically via `recreate_swapchain_and_pipeline`.

### Memory

Three static arenas, sized at compile time via `#config`:

| Allocator | Default | Lifetime |
|---|---|---|
| `context.allocator` (app arena) | 64 MB | Process lifetime |
| `context.temp_allocator` (frame arena) | 16 MB | Reset at start of every frame |
| swapchain arena | 8 MB | Reset on every swapchain recreation |

Use `context.temp_allocator` for per-frame scratch work. Use `context.allocator` for data that must outlive a frame.

### Logging

`log_info/warn/error/debug` and `log_infof/...f` variants. On Windows with a debugger attached, output routes to `OutputDebugStringA` (visible in the VS/WinDbg Output window); otherwise `fmt.println`.
