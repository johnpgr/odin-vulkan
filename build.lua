local M = {}

local function detect_windows()
    if package.config:sub(1, 1) == "\\" then
        return true
    end

    local os_name = os.getenv("OS")
    if type(os_name) == "string" and os_name:lower():find("windows", 1, true) then
        return true
    end

    local proc = io.popen("uname -s 2>/dev/null")
    if not proc then
        return false
    end

    local name = (proc:read("*l") or ""):upper()
    proc:close()

    return name:find("MINGW", 1, true) ~= nil
        or name:find("MSYS", 1, true) ~= nil
        or name:find("CYGWIN", 1, true) ~= nil
        or name:find("WINDOWS", 1, true) ~= nil
end

local is_windows = detect_windows()
local sep = is_windows and "\\" or "/"

local function detect_macos()
    if is_windows then
        return false
    end

    local proc = io.popen("uname -s 2>/dev/null")
    if not proc then
        return false
    end

    local name = proc:read("*l") or ""
    proc:close()
    return name == "Darwin"
end

local is_macos = detect_macos()

local function env_is_truthy(value)
    if type(value) ~= "string" then
        return false
    end

    local lowered = value:lower()
    return lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on"
end

local verbose = env_is_truthy(os.getenv("ODINGAME_BUILD_VERBOSE"))

local function log_debug(message)
    if not verbose then
        return
    end
    io.stderr:write("[build] " .. tostring(message) .. "\n")
end

local function dynamic_lib_name(base)
    if is_windows then
        return base .. ".dll"
    end
    if is_macos then
        return "lib" .. base .. ".dylib"
    end
    return "lib" .. base .. ".so"
end

local function joinpath(...)
    local parts = { ... }
    return table.concat(parts, sep)
end

local shader_root = joinpath("engine", "shaders")

local function basename(path)
    return path:match("[^/\\]+$") or path
end

local function current_working_directory()
    local cmd = is_windows and "cd" or "pwd"
    local proc = io.popen(cmd)
    if not proc then
        return nil
    end

    local dir = (proc:read("*l") or ""):gsub("\r$", "")
    proc:close()
    if dir == "" then
        return nil
    end

    return dir
end

local function resolve_project_name(project_root)
    local root = project_root:gsub("[/\\]+$", "")
    local name = basename(root)
    if name ~= "" and name ~= "." then
        return name
    end

    local cwd = current_working_directory()
    if cwd then
        local cwd_name = basename(cwd:gsub("[/\\]+$", ""))
        if cwd_name ~= "" and cwd_name ~= "." then
            return cwd_name
        end
    end

    return "odingame"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

local function quote_if_needed(path)
    if path:find("%s") then
        return '"' .. path .. '"'
    end
    return path
end

local function shell_escape(part)
    if is_windows then
        local escaped = part:gsub('"', '\\"')
        if escaped:find('[%s%%&%%|%%<%%>%%^]') then
            return '"' .. escaped .. '"'
        end
        return escaped
    end

    if part == "" then
        return "''"
    end
    return "'" .. part:gsub("'", "'\\''") .. "'"
end

local function command_to_string(cmd)
    local escaped = {}
    for _, part in ipairs(cmd) do
        escaped[#escaped + 1] = shell_escape(part)
    end
    return table.concat(escaped, " ")
end

local function execute_in_dir(project_root, command)
    local run_cmd
    if is_windows then
        run_cmd = "cd /d " .. shell_escape(project_root) .. " && " .. command
    else
        run_cmd = "cd " .. shell_escape(project_root) .. " && " .. command
    end

    log_debug("exec: " .. run_cmd)

    local success, reason, code = os.execute(run_cmd)
    if success == true or success == 0 then
        log_debug("exec ok")
        return true
    end

    if type(success) == "number" then
        log_debug("exec failed with numeric status: " .. tostring(success))
        return false, "exit code " .. success
    end

    log_debug("exec failed: success=" .. tostring(success) .. ", reason=" .. tostring(reason) .. ", code=" .. tostring(code))

    if type(code) == "number" then
        return false, "exit code " .. code
    end
    if type(reason) == "string" and reason ~= "" then
        return false, reason
    end

    return false, "unknown error"
end

local function popen_in_dir(project_root, command)
    local run_cmd
    if is_windows then
        run_cmd = "cd /d " .. shell_escape(project_root) .. " && " .. command
    else
        run_cmd = "cd " .. shell_escape(project_root) .. " && " .. command
    end
    log_debug("popen: " .. run_cmd)
    return io.popen(run_cmd)
end

local function normalize_slashes(path)
    return path:gsub("\\", "/")
end

local function make_relative_path(project_root, path)
    local root = normalize_slashes(project_root):gsub("/+$", "")
    local candidate = normalize_slashes(path):gsub("^%./", "")

    if is_windows then
        if candidate:sub(1, #root):lower() == root:lower() then
            candidate = candidate:sub(#root + 1)
        end
    elseif candidate:sub(1, #root) == root then
        candidate = candidate:sub(#root + 1)
    end

    return candidate:gsub("^/+", "")
end

local function discover_shader_sources(project_root)
    log_debug("discover shaders: project_root=" .. tostring(project_root) .. ", shader_root=" .. tostring(shader_root))

    local list_cmds
    if is_windows then
        list_cmds = {
            "dir /s /b " .. shell_escape(shader_root .. "\\*.vert") .. " 2>nul",
            "dir /s /b " .. shell_escape(shader_root .. "\\*.frag") .. " 2>nul",
        }
    else
        list_cmds = {
            "find " .. shell_escape(shader_root) .. " -type f \\( -name '*.vert' -o -name '*.frag' \\) -print 2>/dev/null",
        }
    end

    local dedup = {}
    for _, list_cmd in ipairs(list_cmds) do
        log_debug("shader list cmd: " .. list_cmd)
        local proc = popen_in_dir(project_root, list_cmd)
        if not proc then
            return nil, "Could not enumerate shader sources"
        end

        for raw_line in proc:lines() do
            local line = raw_line:gsub("\r$", "")
            if line ~= "" and line ~= "File Not Found" then
                log_debug("shader list output: " .. line)
                dedup[make_relative_path(project_root, line)] = true
            end
        end
        proc:close()
    end

    local sources = {}
    for path in pairs(dedup) do
        sources[#sources + 1] = path
    end

    table.sort(sources)
    log_debug("shader source count: " .. tostring(#sources))
    return sources
end

local function find_glslc()
    local vulkan_sdk = os.getenv("VULKAN_SDK")
    local candidates = {}

    if vulkan_sdk and vulkan_sdk ~= "" then
        if is_windows then
            candidates[#candidates + 1] = joinpath(vulkan_sdk, "Bin", "glslc.exe")
        elseif is_macos then
            candidates[#candidates + 1] = joinpath(vulkan_sdk, "macOS", "bin", "glslc")
            candidates[#candidates + 1] = joinpath(vulkan_sdk, "bin", "glslc")
        else
            candidates[#candidates + 1] = joinpath(vulkan_sdk, "bin", "glslc")
        end
    end

    for _, candidate in ipairs(candidates) do
        if file_exists(candidate) then
            return candidate
        end
    end

    return is_windows and "glslc.exe" or "glslc"
end

local function compile_shaders(project_root)
    local shaders, discover_err = discover_shader_sources(project_root)
    if not shaders then
        return false, discover_err
    end
    if #shaders == 0 then
        return false, "No shaders found under engine/shaders/ (*.vert, *.frag). Re-run with --verbose or set ODINGAME_BUILD_VERBOSE=1"
    end

    local glslc = find_glslc()
    log_debug("using glslc: " .. glslc)
    for _, shader_src in ipairs(shaders) do
        log_debug("compiling shader: " .. shader_src)
        local cmd = command_to_string({ glslc, shader_src, "-o", shader_src .. ".spv" })
        local ok, err = execute_in_dir(project_root, cmd)
        if not ok then
            return false, "Shader compilation failed for " .. shader_src .. " (" .. err .. ")"
        end
    end

    return true
end

local function is_debug_build()
    local mode = os.getenv("ODINGAME_BUILD_MODE")
    if mode then
        mode = mode:lower()
        if mode == "release" then
            return false
        end
        if mode == "debug" then
            return true
        end
    end
    return true
end

local function find_vulkan_lib_dir(vulkan_sdk)
    local candidates = {
        joinpath(vulkan_sdk, "Lib"),
        joinpath(vulkan_sdk, "Lib", "x64"),
    }

    for _, lib_dir in ipairs(candidates) do
        if file_exists(joinpath(lib_dir, "vulkan-1.lib")) then
            return lib_dir
        end
    end

    return nil
end

local function find_vulkan_dylib_dir(candidates)
    for _, lib_dir in ipairs(candidates) do
        if file_exists(joinpath(lib_dir, "libvulkan.dylib")) or file_exists(joinpath(lib_dir, "libvulkan.1.dylib")) then
            return lib_dir
        end
    end

    return nil
end

local function get_build_command(project_root)
    local project_name = resolve_project_name(project_root)
    local output_name = project_name .. (is_windows and ".exe" or "")
    local output_rel_path = joinpath("bin", output_name)
    local debug_build = is_debug_build()

    if is_windows then
        local vulkan_sdk = os.getenv("VULKAN_SDK")
        if not vulkan_sdk or vulkan_sdk == "" then
            return nil, "VULKAN_SDK is not set"
        end

        local vulkan_lib_path = find_vulkan_lib_dir(vulkan_sdk)
        if not vulkan_lib_path then
            return nil, "Could not find vulkan-1.lib under VULKAN_SDK"
        end

        local build_cmd = {
            "odin",
            "build",
            "engine",
            "-collection:app=.",
            "-subsystem:" .. (debug_build and "console" or "windows"),
            "-out:" .. output_rel_path,
            "-extra-linker-flags:/LIBPATH:" .. quote_if_needed(vulkan_lib_path),
        }

        if debug_build then
            table.insert(build_cmd, 4, "-debug")
        end

        return build_cmd
    end

    if is_macos then
        local build_cmd = { "odin", "build", "engine", "-collection:app=.", "-out:" .. output_rel_path }
        if debug_build then
            table.insert(build_cmd, "-debug")
        end
        local vulkan_sdk = os.getenv("VULKAN_SDK")

        local candidates = {
            "/usr/local/lib",
            "/opt/homebrew/lib",
        }

        if vulkan_sdk and vulkan_sdk ~= "" then
            table.insert(candidates, 1, joinpath(vulkan_sdk, "macOS", "lib"))
            table.insert(candidates, 1, joinpath(vulkan_sdk, "lib"))
        end

        local vulkan_dylib_dir = find_vulkan_dylib_dir(candidates)
        if not vulkan_dylib_dir then
            return nil, "Could not find libvulkan(.1).dylib in /usr/local/lib, /opt/homebrew/lib, or VULKAN_SDK"
        end

        local linker_flags = "-L" .. quote_if_needed(vulkan_dylib_dir)
            .. " -Wl,-rpath," .. quote_if_needed(vulkan_dylib_dir)
        table.insert(build_cmd, "-extra-linker-flags:" .. linker_flags)
        return build_cmd
    end

    local build_cmd = { "odin", "build", "engine", "-collection:app=.", "-out:" .. output_rel_path }
    if debug_build then
        table.insert(build_cmd, "-debug")
    end
    return build_cmd
end

local function get_game_build_command(project_root)
	local output_rel_path = joinpath("bin", dynamic_lib_name("game"))
    local cmd = {
        "odin",
        "build",
        "game",
        "-build-mode:dll",
        "-collection:app=.",
        "-out:" .. output_rel_path,
    }

    if is_debug_build() then
        table.insert(cmd, "-debug")
    end

    return cmd
end

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end

local function mkdir_bin(project_root)
    local bin_dir = joinpath(project_root, "bin")
    local cmd
    if is_windows then
        cmd = "if not exist " .. shell_escape(bin_dir) .. " mkdir " .. shell_escape(bin_dir)
    else
        cmd = "mkdir -p " .. shell_escape(bin_dir)
    end
    return os.execute(cmd)
end

local function run_build(project_root)
    local ok = mkdir_bin(project_root)
    if not ok then
        return false, "Could not create bin directory"
    end

    local shaders_ok, shaders_err = compile_shaders(project_root)
    if not shaders_ok then
        return false, shaders_err
    end

    local build_cmd, build_error = get_build_command(project_root)
    if not build_cmd then
        return false, build_error
    end

    local command = command_to_string(build_cmd)
    local success, err = execute_in_dir(project_root, command)
    if not success then
        return false, "Build failed (" .. err .. ")"
    end

    local game_cmd = command_to_string(get_game_build_command(project_root))
    local game_success, game_err = execute_in_dir(project_root, game_cmd)
    if not game_success then
        return false, "Game DLL build failed (" .. game_err .. ")"
    end

    return true
end

function M.get_build_command(project_root)
    return get_build_command(project_root)
end

function M.get_game_build_command(project_root)
    return get_game_build_command(project_root)
end

function M.command_to_string(cmd)
    return command_to_string(cmd)
end

function M.run(project_root)
    return run_build(project_root)
end

local function parse_cli_args(args)
    local root
    local print_only = false
    local cli_verbose = false

    for i = 1, #args do
        local value = args[i]
        if value == "--print-cmd" then
            print_only = true
        elseif value == "--verbose" then
            cli_verbose = true
        elseif value ~= "" and value:sub(1, 2) == "--" then
            -- ignore unknown flags
        elseif not root then
            root = value
        end
    end

    return root, print_only, cli_verbose
end

function M.main(argv)
    local args = argv or arg or {}
    local root_arg, print_only, cli_verbose = parse_cli_args(args)
    local root = root_arg or script_dir()

    if cli_verbose then
        verbose = true
    end

    log_debug("platform: is_windows=" .. tostring(is_windows) .. ", is_macos=" .. tostring(is_macos) .. ", sep=" .. sep)
    log_debug("root: " .. tostring(root))

    if print_only then
        local build_cmd, build_error = get_build_command(root)
        if not build_cmd then
            io.stderr:write(build_error .. "\n")
            return false
        end
        print(command_to_string(build_cmd))
        return true
    end

    local success, err = run_build(root)
    if not success then
        io.stderr:write(err .. "\n")
        return false
    end
    return true
end

local function running_as_script()
    return type(arg) == "table"
        and type(arg[0]) == "string"
        and arg[0]:match("build%.lua$") ~= nil
end

if running_as_script() then
    local ok = M.main(arg)
    if not ok then
        os.exit(1)
    end
end

return M
