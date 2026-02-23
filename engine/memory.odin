package engine

import "core:mem"
import "core:mem/virtual"

APP_MEMORY_SIZE :: #config(ODINGAME_APP_MEMORY_SIZE, 64 * mem.Megabyte)
FRAME_MEMORY_SIZE :: #config(ODINGAME_FRAME_MEMORY_SIZE, 16 * mem.Megabyte)
SWAPCHAIN_MEMORY_SIZE :: #config(ODINGAME_SWAPCHAIN_MEMORY_SIZE, 8 * mem.Megabyte)

@(private)
_app_arena: virtual.Arena
@(private)
_frame_arena: virtual.Arena
@(private)
_swapchain_arena: virtual.Arena

memory_init :: proc() -> (app: mem.Allocator, frame: mem.Allocator) {
	if virtual.arena_init_growing(&_app_arena, uint(APP_MEMORY_SIZE)) != .None {
		log_error("Failed to init app arena")
	}
	if virtual.arena_init_growing(&_frame_arena, uint(FRAME_MEMORY_SIZE)) != .None {
		log_error("Failed to init frame arena")
	}
	return virtual.arena_allocator(&_app_arena), virtual.arena_allocator(&_frame_arena)
}

swapchain_memory_init :: proc() -> mem.Allocator {
	if virtual.arena_init_growing(&_swapchain_arena, uint(SWAPCHAIN_MEMORY_SIZE)) != .None {
		log_error("Failed to init swapchain arena")
	}
	return virtual.arena_allocator(&_swapchain_arena)
}

swapchain_memory_reset :: proc(swapchain_allocator: mem.Allocator) {
	free_all(swapchain_allocator)
}
