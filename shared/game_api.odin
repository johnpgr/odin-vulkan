package shared

GAME_API_VERSION :: u32(3)

Mesh_Handle :: distinct u32
CUBE_MESH :: Mesh_Handle(0)

Engine_Draw_Quad_Proc :: proc(x, y, width, height: f32, r, g, b, a: f32)
Engine_Set_Clear_Color_Proc :: proc(r, g, b, a: f32)
Engine_Set_Camera_Proc :: proc(eye_x, eye_y, eye_z, tx, ty, tz: f32)
Engine_Load_Mesh_Proc :: proc(path: cstring) -> Mesh_Handle
Engine_Draw_Mesh_Proc :: proc(handle: Mesh_Handle, model: mat4, r, g, b, a: f32)
Engine_Draw_Cube_Proc :: proc(model: mat4, r, g, b, a: f32)
Engine_Log_Proc :: proc(message: string)
Engine_Get_DT_Proc :: proc() -> f32
Engine_Is_Key_Down_Proc :: proc(key: i32) -> bool

Engine_API :: struct {
	api_version: u32,

	draw_quad:       Engine_Draw_Quad_Proc,
	set_clear_color: Engine_Set_Clear_Color_Proc,
	set_camera:      Engine_Set_Camera_Proc,
	load_mesh:       Engine_Load_Mesh_Proc,
	draw_mesh:       Engine_Draw_Mesh_Proc,
	draw_cube:       Engine_Draw_Cube_Proc,
	log:             Engine_Log_Proc,
	get_dt:          Engine_Get_DT_Proc,
	is_key_down:     Engine_Is_Key_Down_Proc,
}

Game_Get_API_Version_Proc :: proc() -> u32
Game_Get_Memory_Size_Proc :: proc() -> int
Game_Load_Proc :: proc(api: ^Engine_API, memory: rawptr, memory_size: int)
Game_Update_Proc :: proc(api: ^Engine_API, memory: rawptr, memory_size: int)
Game_Unload_Proc :: proc(api: ^Engine_API, memory: rawptr, memory_size: int)
Game_Reload_Proc :: proc(api: ^Engine_API, memory: rawptr, memory_size: int)

Game_API :: struct {
	api_version: u32,

	get_api_version: Game_Get_API_Version_Proc,
	get_memory_size: Game_Get_Memory_Size_Proc,
	load:            Game_Load_Proc,
	update:          Game_Update_Proc,
	unload:          Game_Unload_Proc,
	reload:          Game_Reload_Proc,
}
