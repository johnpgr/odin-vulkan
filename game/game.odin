package game

import shared "../shared"
import "core:math/linalg"

Game_State :: struct {
	time:         f32,
	reload_count: u32,

	world: World,

	tree_mesh: shared.Mesh_Handle,
	rock_mesh: shared.Mesh_Handle,
}

get_state :: proc(memory: rawptr, memory_size: int) -> (^Game_State, bool) {
	if memory == nil || memory_size < size_of(Game_State) {
		return nil, false
	}
	return cast(^Game_State)memory, true
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
	state, ok := get_state(memory, memory_size)
	if !ok {
		api.log("game_load: invalid state memory")
		return
	}

	state^ = {}
	state.tree_mesh = api.load_mesh(cast(cstring)"assets/tree.glb")
	state.rock_mesh = api.load_mesh(cast(cstring)"assets/rock.glb")
	api.log("game_load")
}

@(export)
game_unload :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state, ok := get_state(memory, memory_size)
	if !ok {
		api.log("game_unload: invalid state memory")
		return
	}

	state.time = 0
	api.log("game_unload")
}

@(export)
game_reload :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state, ok := get_state(memory, memory_size)
	if !ok {
		api.log("game_reload: invalid state memory")
		return
	}

	state.reload_count += 1
	api.log("game_reload")
}

@(export)
game_update :: proc(api: ^shared.Engine_API, memory: rawptr, memory_size: int) {
	state, ok := get_state(memory, memory_size)
	if !ok {
		api.log("game_update: invalid state memory")
		return
	}

	dt := api.get_dt()
	state.time += dt

	api.set_clear_color(0.53, 0.81, 0.92, 1.0)
	api.set_camera(0, 5, 10, 0, 0, 0)

	angle := state.time
	cube_model := linalg.matrix4_rotate_f32(angle, {0, 1, 0})
	api.draw_cube(cube_model, 0.8, 0.4, 0.2, 1.0)

	tree_model := linalg.matrix4_translate_f32({3, 0, 0})
	api.draw_mesh(state.tree_mesh, tree_model, 0.3, 0.7, 0.2, 1.0)

	for i in 0 ..< 3 {
		pos := vec3{f32(i) * 2 - 2, 0, -3}
		rock_model := linalg.matrix4_translate_f32(pos)
		api.draw_mesh(state.rock_mesh, rock_model, 0.6, 0.6, 0.6, 1.0)
	}
}
