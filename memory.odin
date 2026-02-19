package main

import "core:mem"

APP_MEMORY_SIZE :: #config(ODINGAME_APP_MEMORY_SIZE, 64 * mem.Megabyte)
FRAME_MEMORY_SIZE :: #config(ODINGAME_FRAME_MEMORY_SIZE, 16 * mem.Megabyte)

Memory_Region :: enum {
	App,
	Frame,
}

Memory_System :: struct {
	app_arena:       mem.Arena,
	frame_arena:     mem.Arena,
	app_allocator:   mem.Allocator,
	frame_allocator: mem.Allocator,
	initialized:     bool,
}

Game_Memory_API :: struct {
	app:   ^mem.Allocator,
	frame: ^mem.Allocator,
}

Frame_Temp :: struct {
	allocator: mem.Allocator,
	temp:      mem.Arena_Temp_Memory,
}

app_memory_backing_buffer: [APP_MEMORY_SIZE]byte
frame_memory_backing_buffer: [FRAME_MEMORY_SIZE]byte

memory_system_initialize :: proc(ms: ^Memory_System) {
	if ms == nil {
		return
	}
	if ms.initialized {
		return
	}

	mem.arena_init(&ms.app_arena, app_memory_backing_buffer[:])
	mem.arena_init(&ms.frame_arena, frame_memory_backing_buffer[:])

	ms.app_allocator = mem.arena_allocator(&ms.app_arena)
	ms.frame_allocator = mem.arena_allocator(&ms.frame_arena)
	ms.initialized = true
}

memory_system_shutdown :: proc(ms: ^Memory_System) {
	if ms == nil || !ms.initialized {
		return
	}

	mem.arena_free_all(&ms.frame_arena)
	mem.arena_free_all(&ms.app_arena)
	ms^ = {}
}

memory_system_reset_frame :: proc(ms: ^Memory_System) {
	if ms == nil || !ms.initialized {
		return
	}
	mem.arena_free_all(&ms.frame_arena)
}

memory_system_api :: proc(ms: ^Memory_System) -> Game_Memory_API {
	return Game_Memory_API{app = &ms.app_allocator, frame = &ms.frame_allocator}
}

memory_begin_frame_temp :: proc(ms: ^Memory_System) -> Frame_Temp {
	if ms == nil || !ms.initialized {
		return {}
	}

	return Frame_Temp {
		allocator = ms.frame_allocator,
		temp      = mem.begin_arena_temp_memory(&ms.frame_arena),
	}
}

memory_end_frame_temp :: proc(frame: ^Frame_Temp) {
	if frame != nil && frame.temp.arena != nil {
		mem.end_arena_temp_memory(frame.temp)
		frame^ = {}
	}
}
