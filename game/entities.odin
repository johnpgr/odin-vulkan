package game

import shared "../shared"

vec2 :: shared.vec2
vec3 :: shared.vec3
vec4 :: shared.vec4
mat2 :: shared.mat2
mat3 :: shared.mat3
mat4 :: shared.mat4
quat :: shared.quat

MAX_ENTITIES :: 1024

Handle :: struct {
	index:      u32,
	generation: u32,
}

Entity_Flag :: enum u8 {
	On_Fire,
	Invisible,
	Frozen,
}
Entity_Flags :: bit_set[Entity_Flag;u8]

// --- Entity variant data ---

Player_Data :: struct {
	health:  f32,
	stamina: f32,
}

Enemy_Data :: struct {
	health:      f32,
	aggro_range: f32,
	target:      Handle,
}

Projectile_Data :: struct {
	damage:   f32,
	lifetime: f32,
	owner:    Handle,
}

Item_Data :: struct {
	item_id:    u32,
	stack_size: u16,
}

Entity_Data :: union {
	Player_Data,
	Enemy_Data,
	Projectile_Data,
	Item_Data,
}

// --- Entity (shared fields + type-specific union) ---

Entity :: struct {
	flags:    Entity_Flags,

	// Transform
	position: vec3,
	rotation: vec3,
	scale:    vec3,
	velocity: vec3,

	// Intrusive hierarchy (index 0 = no relation)
	parent_idx:       u32,
	first_child_idx:  u32,
	next_sibling_idx: u32,
	prev_sibling_idx: u32,

	// Type-specific data (nil union = empty/inactive slot)
	data: Entity_Data,
}

Entity_Slot :: struct {
	entity:      Entity,
	generation:  u32,
	is_occupied: bool,
}

// --- World ---

World :: struct {
	slots:      [MAX_ENTITIES]Entity_Slot,
	free_list:  [MAX_ENTITIES]u32,
	free_count: u32,
	next_slot:  u32, // next never-used index; starts at 1 (0 = nil sentinel)
	count:      u32,
}

world_spawn :: proc(world: ^World) -> (entity: ^Entity, handle: Handle) {
	if world.next_slot == 0 {
		world.next_slot = 1
	}

	idx: u32
	if world.free_count > 0 {
		world.free_count -= 1
		idx = world.free_list[world.free_count]
	} else {
		if world.next_slot >= MAX_ENTITIES {
			return &world.slots[0].entity, {}
		}
		idx = world.next_slot
		world.next_slot += 1
	}

	slot := &world.slots[idx]
	slot.entity = {}
	slot.is_occupied = true
	world.count += 1

	return &slot.entity, Handle{index = idx, generation = slot.generation}
}

world_despawn :: proc(world: ^World, handle: Handle) {
	if handle.index == 0 || handle.index >= MAX_ENTITIES {
		return
	}
	slot := &world.slots[handle.index]
	if !slot.is_occupied || slot.generation != handle.generation {
		return
	}
	slot.entity = {}
	slot.is_occupied = false
	slot.generation += 1
	world.count -= 1
	if world.free_count < MAX_ENTITIES {
		world.free_list[world.free_count] = handle.index
		world.free_count += 1
	}
}

world_resolve :: proc(world: ^World, handle: Handle) -> ^Entity {
	if handle.index == 0 || handle.index >= MAX_ENTITIES {
		return &world.slots[0].entity
	}
	slot := &world.slots[handle.index]
	if !slot.is_occupied || slot.generation != handle.generation {
		return &world.slots[0].entity
	}
	return &slot.entity
}
