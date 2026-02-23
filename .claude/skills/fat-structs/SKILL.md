---
name: fat-structs
description: Entity design using fat/mega structs instead of ECS. Use when designing entity systems, game object architecture, adding new entity properties, or when the user asks about entity storage, component systems, or game object patterns.
---

# Fat Structs (Megastruct Entity Design)

You are an expert in handmade-style entity architecture. When helping with entity/game-object code, follow these principles strictly.

## Core Philosophy

**Discard ECS. Put every possible state an entity could ever have into one massive struct.**

Modern ECS fragments data into arrays of individual components to maximize cache lines. However, iterating over entities is rarely the actual bottleneck in indie games. The complexity of splitting and merging component streams introduces friction for small teams.

## The Megastruct Pattern

One struct holds ALL possible entity properties. Use boolean flags to toggle features:

```
Entity :: struct {
    is_active:    bool,
    kind:         Entity_Kind,
    flags:        Entity_Flags,  // is_player, on_fire, has_sprite, etc.

    // Transform
    position:     [3]f32,
    rotation:     [3]f32,
    scale:        [3]f32,

    // Physics
    velocity:     [3]f32,
    health:       f32,

    // Hierarchy (intrusive tree via indices)
    parent_idx:       u32,
    first_child_idx:  u32,
    next_sibling_idx: u32,
    prev_sibling_idx: u32,

    // Rendering
    mesh_id:      u32,
    material_idx: u32,
    transform:    matrix[4,4]f32,

    // ... every other property any entity could need
}
```

## Storage

A single contiguous array, allocated once at startup:

- `global_entities: [MAX_ENTITIES]Entity` — one flat block
- `next_empty_slot` starts at 1 (index 0 is the nil sentinel)
- Gaps are left when entities are deleted (sparse array) — never shift memory to compact

## Benefits

- **Serialization is trivial**: save/load the entire array as a flat binary blob
- **Game logic is simple**: iterate the array, check flags, execute logic
- **No polymorphism**: no vtables, no dynamic dispatch, no inheritance hierarchies
- **Hot-reload friendly**: the struct layout is the entire game state — cast `rawptr` to `^Game_State`

## Rules When Writing Entity Code

- Every new entity property goes into the existing Entity struct — never create a separate "component" type
- Use flag enums or booleans to enable/disable behavior, not type hierarchies
- Iterate the flat array with simple `for` loops and flag checks
- Never allocate entities individually — always use the pre-allocated pool
- Index 0 is reserved as the nil sentinel (see ZII pattern)
- Use generational handles for safe cross-references between entities

## Anti-Patterns (Never Do This)

- Never create separate component arrays and join them at runtime (ECS)
- Never use inheritance or vtables for entity types
- Never dynamically resize the entity array
- Never compact/defragment the array — leave gaps, use sparse iteration
- Never store raw pointers between entities — use indices or generational handles
