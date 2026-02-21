package engine

import "core:dynlib"
import "core:os"
import shared "app:shared"

Game_Module :: struct {
	dll_source_path: string,
	dll_loaded_path: string,

	library: dynlib.Library,
	last_write_time: os.File_Time,
	api: shared.Game_API,
	is_loaded: bool,
}

game_symbol :: proc(module: ^Game_Module, symbol: string) -> rawptr {
	ptr, ok := dynlib.symbol_address(module.library, symbol)
	if !ok {
		log_errorf("Game symbol lookup failed for %s: %s", symbol, dynlib.last_error())
		return nil
	}
	return ptr
}

copy_file_bytes :: proc(src_path, dst_path: string) -> bool {
	data, ok_read := os.read_entire_file(src_path, context.temp_allocator)
	if !ok_read {
		log_errorf("Failed to read file for hot reload copy: %s", src_path)
		return false
	}
	defer delete(data, context.temp_allocator)

	return write_game_module_bytes(dst_path, data)
}

write_game_module_bytes :: proc(dst_path: string, data: []byte) -> bool {
	if len(data) == 0 {
		log_errorf("Failed to write empty game module copy: %s", dst_path)
		return false
	}

	if os.write_entire_file(dst_path, data) {
		return true
	}

	log_errorf("Failed to write file for hot reload copy: %s", dst_path)
	return false
}

bind_game_module_api :: proc(module: ^Game_Module) -> bool {
	module.api = {}

	module.api.get_api_version = cast(shared.Game_Get_API_Version_Proc)game_symbol(module, "game_get_api_version")
	if module.api.get_api_version == nil {
		return false
	}
	module.api.api_version = module.api.get_api_version()
	module.api.get_memory_size = cast(shared.Game_Get_Memory_Size_Proc)game_symbol(module, "game_get_memory_size")
	module.api.load = cast(shared.Game_Load_Proc)game_symbol(module, "game_load")
	module.api.update = cast(shared.Game_Update_Proc)game_symbol(module, "game_update")
	module.api.unload = cast(shared.Game_Unload_Proc)game_symbol(module, "game_unload")
	module.api.reload = cast(shared.Game_Reload_Proc)game_symbol(module, "game_reload")

	if module.api.api_version != shared.GAME_API_VERSION {
		log_errorf(
			"Game API version mismatch. Engine=%d, Game=%d",
			shared.GAME_API_VERSION,
			module.api.api_version,
		)
		return false
	}

	if module.api.get_memory_size == nil ||
	   module.api.load == nil ||
	   module.api.update == nil ||
	   module.api.unload == nil ||
	   module.api.reload == nil {
		log_error("Game API is incomplete")
		return false
	}

	return true
}

load_game_module_from_bytes :: proc(module: ^Game_Module, bytes: []byte) -> bool {
	if !write_game_module_bytes(module.dll_loaded_path, bytes) {
		return false
	}

	library, ok_library := dynlib.load_library(module.dll_loaded_path)
	if !ok_library {
		log_errorf("Failed to load game library: %s", dynlib.last_error())
		return false
	}

	module.library = library

	if !bind_game_module_api(module) {
		unload_game_module(module)
		return false
	}

	module.last_write_time, _ = os.last_write_time_by_name(module.dll_source_path)
	module.is_loaded = true
	return true
}

load_game_module :: proc(module: ^Game_Module) -> bool {
	data, ok_read := os.read_entire_file(module.dll_source_path, context.temp_allocator)
	if !ok_read {
		log_errorf("Failed to read file for hot reload copy: %s", module.dll_source_path)
		return false
	}
	defer delete(data, context.temp_allocator)

	return load_game_module_from_bytes(module, data)
}

unload_game_module :: proc(module: ^Game_Module) {
	if module.is_loaded {
		dynlib.unload_library(module.library)
	}
	module.library = dynlib.Library(nil)
	module.api = {}
	module.is_loaded = false
}

game_module_changed :: proc(module: ^Game_Module) -> bool {
	if !module.is_loaded {
		return false
	}

	t, err := os.last_write_time_by_name(module.dll_source_path)
	if err != nil {
		return false
	}

	return t != module.last_write_time
}
