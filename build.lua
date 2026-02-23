local host_os = "linux"
local build_mode = "debug"
local build_target = "all"
local verbose = false

if package.config:sub(1, 1) == "\\" then
    host_os = "windows"
else
    local os_name = os.getenv("OS")
    if type(os_name) == "string" and os_name:lower():find("windows", 1, true) ~= nil then
        host_os = "windows"
    else
        local proc = io.popen("uname -s 2>/dev/null")
        if proc then
            local name = (proc:read("*l") or ""):upper()
            proc:close()
            if name == "DARWIN" then
                host_os = "macos"
            elseif name:find("MINGW", 1, true) ~= nil
                or name:find("MSYS", 1, true) ~= nil
                or name:find("CYGWIN", 1, true) ~= nil
                or name:find("WINDOWS", 1, true) ~= nil then
                host_os = "windows"
            end
        end
    end
end

if type(arg) == "table" then
    for i = 1, #arg do
        if type(arg[i]) == "string" then
            local value = arg[i]:lower()
            if value == "debug" or value == "release" then
                build_mode = value
            elseif value == "game" or value == "all" then
                build_target = value
            elseif value == "verbose" or value == "--verbose" or value == "-v" then
                verbose = true
            else
                io.stderr:write("Unknown arg: " .. tostring(arg[i]) .. " (use: debug/release, optional game/all, optional --verbose)\n")
                os.exit(1)
            end
        end
    end
end

local function log_verbose(message)
    if not verbose then
        return
    end
    io.stderr:write("[build] " .. tostring(message) .. "\n")
end

local function shell_escape(part)
    if host_os == "windows" then
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

local function command_to_string(parts)
    local escaped = {}
    for _, part in ipairs(parts) do
        escaped[#escaped + 1] = shell_escape(part)
    end
    return table.concat(escaped, " ")
end

local function execute_in_root(project_root, command)
    local run_cmd
    if host_os == "windows" then
        run_cmd = "cd /d " .. shell_escape(project_root) .. " && " .. command
    else
        run_cmd = "cd " .. shell_escape(project_root) .. " && " .. command
    end

    log_verbose("exec: " .. run_cmd)

    local success, reason, code = os.execute(run_cmd)
    if success == true or success == 0 then
        return true
    end

    if type(success) == "number" then
        return false, "exit code " .. success
    end
    if type(code) == "number" then
        return false, "exit code " .. code
    end
    if type(reason) == "string" and reason ~= "" then
        return false, reason
    end

    return false, "unknown error"
end

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end

local function joinpath(...)
    local sep = host_os == "windows" and "\\" or "/"
    return table.concat({ ... }, sep)
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if not f then
        return false
    end
    f:close()
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

local function find_vulkan_dylib_dir(vulkan_sdk)
    local candidates = {
        "/usr/local/lib",
        "/opt/homebrew/lib",
    }

    if type(vulkan_sdk) == "string" and vulkan_sdk ~= "" then
        table.insert(candidates, 1, joinpath(vulkan_sdk, "macOS", "lib"))
        table.insert(candidates, 1, joinpath(vulkan_sdk, "lib"))
    end

    for _, lib_dir in ipairs(candidates) do
        if file_exists(joinpath(lib_dir, "libvulkan.dylib")) or file_exists(joinpath(lib_dir, "libvulkan.1.dylib")) then
            return lib_dir
        end
    end
    return nil
end

local function engine_output_name()
    if host_os == "windows" then
        return "odingame.exe"
    end
    return "odingame"
end

local function game_output_name()
    if host_os == "windows" then
        return "game.dll"
    end
    if host_os == "macos" then
        return "libgame.dylib"
    end
    return "libgame.so"
end

local function build_engine(project_root)
    local cmd = {
        "odin",
        "build",
        "engine",
        "-collection:app=.",
        "-out:" .. joinpath("bin", engine_output_name()),
    }

    if build_mode ~= "release" then
        cmd[#cmd + 1] = "-debug"
    end

    if host_os == "windows" then
        local vulkan_sdk = os.getenv("VULKAN_SDK")
        if not vulkan_sdk or vulkan_sdk == "" then
            return false, "VULKAN_SDK is not set"
        end

        local vulkan_lib = find_vulkan_lib_dir(vulkan_sdk)
        if not vulkan_lib then
            return false, "Could not find vulkan-1.lib under VULKAN_SDK"
        end
        log_verbose("using Vulkan lib dir: " .. vulkan_lib)

        cmd[#cmd + 1] = "-subsystem:" .. ((build_mode ~= "release") and "console" or "windows")
        cmd[#cmd + 1] = "-extra-linker-flags:/LIBPATH:" .. vulkan_lib
    elseif host_os == "macos" then
        local vulkan_lib = find_vulkan_dylib_dir(os.getenv("VULKAN_SDK"))
        if not vulkan_lib then
            return false, "Could not find libvulkan(.1).dylib"
        end
        log_verbose("using Vulkan dylib dir: " .. vulkan_lib)
        cmd[#cmd + 1] = "-extra-linker-flags:-L" .. vulkan_lib .. " -Wl,-rpath," .. vulkan_lib
    end

    return execute_in_root(project_root, command_to_string(cmd))
end

local function build_game(project_root)
    local cmd = {
        "odin",
        "build",
        "game",
        "-build-mode:dll",
        "-collection:app=.",
        "-out:" .. joinpath("bin", game_output_name()),
    }

    if build_mode ~= "release" then
        cmd[#cmd + 1] = "-debug"
    end

    return execute_in_root(project_root, command_to_string(cmd))
end

local function ensure_bin(project_root)
    local cmd
    local bin_dir = joinpath(project_root, "bin")

    if host_os == "windows" then
        cmd = "if not exist " .. shell_escape(bin_dir) .. " mkdir " .. shell_escape(bin_dir)
    else
        cmd = "mkdir -p " .. shell_escape(bin_dir)
    end

    local success = os.execute(cmd)
    return success == true or success == 0
end

local function main()
    local root = script_dir()

    log_verbose("host_os=" .. host_os .. ", build_mode=" .. build_mode .. ", build_target=" .. build_target)
    log_verbose("project_root=" .. root)

    if not ensure_bin(root) then
        io.stderr:write("Could not create bin directory\n")
        return false
    end

    local ok, err
    if build_target ~= "game" then
        log_verbose("building engine")
        ok, err = build_engine(root)
        if not ok then
            io.stderr:write("Engine build failed (" .. tostring(err) .. ")\n")
            return false
        end
    end

    log_verbose("building game")
    ok, err = build_game(root)
    if not ok then
        io.stderr:write("Game DLL build failed (" .. tostring(err) .. ")\n")
        return false
    end

    return true
end

if not main() then
    io.stderr:write("[build] failed\n")
    os.exit(1)
end

io.stdout:write("[build] success\n")
