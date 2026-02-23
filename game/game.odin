package game

import shared "../shared"
import "core:math"

Game_State :: struct {
	time:         f32,
	reload_count: u32,
	clear_hue:    f32,
}

@(private) nil_game_state: Game_State

get_state :: proc(memory: rawptr, memory_size: int) -> ^Game_State {
	if memory == nil || memory_size < size_of(Game_State) {
		return &nil_game_state
	}
	return cast(^Game_State)memory
}

@(export)
game_get_api_version :: proc() -> u32 {
	return shared.GAME_API_VERSION
}

@(export)
game_get_memory_size :: proc() -> int {
	return size_of(Game_State)
}

@(export)
game_load :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state := get_state(memory, memory_size)

	state^ = {}
	api.log("game_load")
}

@(export)
game_unload :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state := get_state(memory, memory_size)
	state.time = 0
	api.log("game_unload")
}

@(export)
game_reload :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state := get_state(memory, memory_size)
	state.reload_count += 1
	api.log("game_reload")
}

@(export)
game_update :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state := get_state(memory, memory_size)

	dt := api.get_dt()
	state.time += dt
	state.clear_hue += dt * 0.2

	r: f32 = 0.08 + 0.05 * math.sin(state.clear_hue)
	g: f32 = 0.09 + 0.05 * math.sin(state.clear_hue + 2.0)
	b: f32 = 0.12 + 0.05 * math.sin(state.clear_hue + 4.0)
	api.set_clear_color(r, g, b, 1.0)

	size: f32 = 0.35
	x: f32 = 0.35 * f32(math.sin(state.time))
	y: f32 = 0.25 * f32(math.cos(state.time * 1.3))

	quad_r: f32 = 0.3 + 0.7 * f32(math.abs(math.sin(state.time * 0.7)))
	quad_g: f32 = 0.3 + 0.7 * f32(math.abs(math.sin(state.time * 1.1)))
	quad_b: f32 = 0.3 + 0.7 * f32(math.abs(math.sin(state.time * 1.7)))

	api.draw_quad(x - size * 0.5, y - size * 0.5, size, size, quad_r, quad_g, quad_b, 1.0)
}
