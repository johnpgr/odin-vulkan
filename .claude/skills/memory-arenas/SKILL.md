---
name: memory-arenas
description: Predictable memory management patterns for game engines. Use when implementing arena allocators, bulk memory allocation, bump allocators, or when the user asks about memory management strategy, avoiding malloc/free, or frame-scoped allocations.
---

# Predictable Memory Management

You are an expert in handmade-style game engine memory management. When helping with memory-related code, follow these principles strictly.

## Core Philosophy

**All memory is allocated upfront. Individual per-object malloc/free is forbidden.**

Dynamic runtime allocations (malloc, new, per-entity allocations) create unpredictable performance, fragment memory, and introduce failure points. Instead:

- Define **harsh limits** at compile time (e.g., `MAX_ENTITIES :: 10_000`)
- If the game loads successfully once, it will reliably run on that hardware forever — no late-game OOM crashes
- Memory fragmentation is impossible because there is no fragmentation to create

## Arena Allocator (Bump Allocator)

For dynamic-sized data (rendering commands, level loading, temporary work), use a bump/arena allocator:

1. Allocate one large block at startup
2. Advance a pointer forward through it sequentially
3. When the scope ends (frame ends, level ends), reset the offset to zero
4. No per-object free, no garbage collection, no reference counting

### Arena Lifetimes

Three distinct lifetime scopes:

| Allocator | Lifetime | Use for |
|---|---|---|
| App/permanent arena | Process lifetime | Data that must outlive a frame (entity arrays, loaded assets) |
| Frame/temp arena | Reset every frame | Per-frame scratch work (render commands, string formatting) |
| Swapchain arena | Reset on swapchain recreation | Vulkan resources tied to swapchain dimensions |

### Odin-Specific Guidance

Odin has built-in arena support in `core:mem`:

- Use `context.allocator` for permanent allocations (app arena)
- Use `context.temp_allocator` for per-frame scratch (frame arena)
- Arenas can be created with `mem.Arena` and initialized with a backing buffer
- Use `mem.arena_allocator(&arena)` to get an `Allocator` from an arena
- Reset with `mem.arena_free_all(&arena)` or `free_all(temp_allocator)` at frame start
- Size arenas via `#config` at compile time for static sizing

## Vulkan Memory

Vulkan's explicit memory management follows the same pattern:

- Make a **few large allocations at startup** based on memory type (upload buffer, static buffer, staging buffer)
- Use a bump allocator to sub-allocate within each large block
- When a level ends, reset the bump offset — no per-object vkFreeMemory
- Persistently map host-visible buffers at startup; never map/unmap per frame

## Anti-Patterns (Never Do This)

- Never `malloc`/`free` or `new`/`delete` per entity or per frame
- Never use dynamic containers (std::vector, dynamic arrays) for core entity storage
- Never implement reference counting or garbage collection
- Never call `vkAllocateMemory` per object — batch into large blocks
- Never map/unmap Vulkan buffers per frame — keep them persistently mapped

## When Reviewing or Writing Code

- If you see per-object allocation, refactor to use a pre-allocated pool or arena
- If you see dynamic arrays growing unbounded, suggest a fixed-capacity array with a harsh limit
- Always ask: "What is the lifetime of this allocation?" and match it to the correct arena
- Prefer stack allocation or arena allocation over heap allocation in all cases
