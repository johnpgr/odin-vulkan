package engine

import "base:runtime"
import "core:fmt"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import kernel32 "system:Kernel32.lib"

	@(default_calling_convention = "system")
	foreign kernel32 {
		IsDebuggerPresent :: proc() -> i32 ---
		OutputDebugStringA :: proc(lpOutputString: cstring) ---
	}
}

Log_Level :: enum {
	Debug,
	Info,
	Warn,
	Error,
}

log_level_prefix :: proc(level: Log_Level) -> string {
	switch level {
	case .Debug:
		return "[DEBUG]"
	case .Info:
		return "[INFO]"
	case .Warn:
		return "[WARN]"
	case .Error:
		return "[ERROR]"
	}

	return "[INFO]"
}

is_debugger_attached :: proc() -> bool {
	when ODIN_OS == .Windows {
		return IsDebuggerPresent() != 0
	} else {
		return false
	}
}

log_emit :: proc(level: Log_Level, text: string) {
	prefix := log_level_prefix(level)

	when ODIN_OS == .Windows {
		if is_debugger_attached() {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			line := fmt.tprintf("%s %s\n", prefix, text)
			c_line, err := strings.clone_to_cstring(line, context.temp_allocator)
			if err == nil {
				OutputDebugStringA(c_line)
				return
			}
		}
	}

	fmt.println(prefix, text)
}

logln :: proc(level: Log_Level, args: ..any, sep := " ") {
	text := fmt.tprint(..args, sep = sep)
	log_emit(level, text)
}

logf :: proc(level: Log_Level, fmt_str: string, args: ..any) {
	text := fmt.tprintf(fmt_str, ..args)
	log_emit(level, text)
}

log_debug :: proc(args: ..any, sep := " ") { logln(.Debug, ..args, sep = sep) }
log_info :: proc(args: ..any, sep := " ") { logln(.Info, ..args, sep = sep) }
log_warn :: proc(args: ..any, sep := " ") { logln(.Warn, ..args, sep = sep) }
log_error :: proc(args: ..any, sep := " ") { logln(.Error, ..args, sep = sep) }

log_debugf :: proc(fmt_str: string, args: ..any) { logf(.Debug, fmt_str, ..args) }
log_infof :: proc(fmt_str: string, args: ..any) { logf(.Info, fmt_str, ..args) }
log_warnf :: proc(fmt_str: string, args: ..any) { logf(.Warn, fmt_str, ..args) }
log_errorf :: proc(fmt_str: string, args: ..any) { logf(.Error, fmt_str, ..args) }
