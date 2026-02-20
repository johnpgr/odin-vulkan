package main

import "core:mem"

// Two global context allocators, set once via memory_init() in main:
//
//   context.allocator, context.temp_allocator = memory_init()
//
// App allocator — persistent, lives for the entire program:
//
//   make([]T, n)                   // uses context.allocator implicitly
//
// Temp allocator — transient, reset at the top of each game loop iteration:
//
//   free_all(context.temp_allocator)
//   make([]T, n, context.temp_allocator)
//
// Swapchain allocator — fixed-size arena for swapchain host-side arrays:
//
//   swapchain_allocator := swapchain_memory_init()
//   swapchain_memory_reset(swapchain_allocator)

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
