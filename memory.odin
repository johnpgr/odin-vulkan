package main

import "core:mem"

APP_MEMORY_SIZE :: #config(ODINGAME_APP_MEMORY_SIZE, 64 * mem.Megabyte)
FRAME_MEMORY_SIZE :: #config(ODINGAME_FRAME_MEMORY_SIZE, 16 * mem.Megabyte)

MemoryRegion :: enum {
	App,
	Frame,
}

MemorySystem :: struct {
	app_arena:       mem.Arena,
	frame_arena:     mem.Arena,
	app_allocator:   mem.Allocator,
	frame_allocator: mem.Allocator,
	initialized:     bool,
}

GameMemoryAPI :: struct {
	app:   ^mem.Allocator,
	frame: ^mem.Allocator,
}

FrameTemp :: struct {
	allocator: mem.Allocator,
	temp:      mem.Arena_Temp_Memory,
}

app_memory_backing_buffer: [APP_MEMORY_SIZE]byte
frame_memory_backing_buffer: [FRAME_MEMORY_SIZE]byte

memory_system_initialize :: proc(ms: ^MemorySystem) {
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

memory_system_shutdown :: proc(ms: ^MemorySystem) {
	if ms == nil || !ms.initialized {
		return
	}

	mem.arena_free_all(&ms.frame_arena)
	mem.arena_free_all(&ms.app_arena)
	ms^ = {}
}

memory_system_reset_frame :: proc(ms: ^MemorySystem) {
	if ms == nil || !ms.initialized {
		return
	}
	mem.arena_free_all(&ms.frame_arena)
}

memory_system_api :: proc(ms: ^MemorySystem) -> GameMemoryAPI {
	return GameMemoryAPI{app = &ms.app_allocator, frame = &ms.frame_allocator}
}

memory_begin_frame_temp :: proc(ms: ^MemorySystem) -> FrameTemp {
	if ms == nil || !ms.initialized {
		return {}
	}

	return FrameTemp {
		allocator = ms.frame_allocator,
		temp      = mem.begin_arena_temp_memory(&ms.frame_arena),
	}
}

memory_end_frame_temp :: proc(frame: ^FrameTemp) {
	if frame != nil && frame.temp.arena != nil {
		mem.end_arena_temp_memory(frame.temp)
		frame^ = {}
	}
}
