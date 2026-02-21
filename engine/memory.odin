package engine

import "core:mem"

APP_MEMORY_SIZE :: #config(ODINGAME_APP_MEMORY_SIZE, 64 * mem.Megabyte)
FRAME_MEMORY_SIZE :: #config(ODINGAME_FRAME_MEMORY_SIZE, 16 * mem.Megabyte)
SWAPCHAIN_MEMORY_SIZE :: #config(ODINGAME_SWAPCHAIN_MEMORY_SIZE, 8 * mem.Megabyte)

@(private)
_app_arena: mem.Arena
@(private)
_app_backing: [APP_MEMORY_SIZE]byte
@(private)
_frame_arena: mem.Arena
@(private)
_frame_backing: [FRAME_MEMORY_SIZE]byte
@(private)
_swapchain_arena: mem.Arena
@(private)
_swapchain_backing: [SWAPCHAIN_MEMORY_SIZE]byte

memory_init :: proc() -> (app: mem.Allocator, frame: mem.Allocator) {
	mem.arena_init(&_app_arena, _app_backing[:])
	mem.arena_init(&_frame_arena, _frame_backing[:])
	return mem.arena_allocator(&_app_arena), mem.arena_allocator(&_frame_arena)
}

swapchain_memory_init :: proc() -> mem.Allocator {
	mem.arena_init(&_swapchain_arena, _swapchain_backing[:])
	return mem.arena_allocator(&_swapchain_arena)
}

swapchain_memory_reset :: proc(swapchain_allocator: mem.Allocator) {
	free_all(swapchain_allocator)
}
