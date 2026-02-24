package engine

import "core:mem"
import "core:mem/virtual"

APP_MEMORY_SIZE :: #config(ODINGAME_APP_MEMORY_SIZE, 64 * mem.Megabyte)
FRAME_MEMORY_SIZE :: #config(ODINGAME_FRAME_MEMORY_SIZE, 16 * mem.Megabyte)
SWAPCHAIN_MEMORY_SIZE :: #config(ODINGAME_SWAPCHAIN_MEMORY_SIZE, 8 * mem.Megabyte)

@(private)
app_arena: virtual.Arena
@(private)
frame_arena: virtual.Arena
@(private)
swapchain_arena: virtual.Arena

memory_init :: proc() -> (app: mem.Allocator, frame: mem.Allocator, ok: bool) {
	if virtual.arena_init_growing(&app_arena, uint(APP_MEMORY_SIZE)) != .None {
		log_error("Failed to init app arena")
		return {}, {}, false
	}
	if virtual.arena_init_growing(&frame_arena, uint(FRAME_MEMORY_SIZE)) != .None {
		log_error("Failed to init frame arena")
		return {}, {}, false
	}
	return virtual.arena_allocator(&app_arena), virtual.arena_allocator(&frame_arena), true
}

swapchain_memory_init :: proc() -> (mem.Allocator, bool) {
	if virtual.arena_init_growing(&swapchain_arena, uint(SWAPCHAIN_MEMORY_SIZE)) != .None {
		log_error("Failed to init swapchain arena")
		return {}, false
	}
	return virtual.arena_allocator(&swapchain_arena), true
}

swapchain_memory_reset :: proc(swapchain_allocator: mem.Allocator) {
	free_all(swapchain_allocator)
}
