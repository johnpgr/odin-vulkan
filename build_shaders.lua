local host_os = "linux"

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

local function script_dir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end

local function run_in_root(project_root, command)
    local run_cmd
    if host_os == "windows" then
        run_cmd = "cd /d " .. shell_escape(project_root) .. " && " .. command
    else
        run_cmd = "cd " .. shell_escape(project_root) .. " && " .. command
    end

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

local function find_glslc()
    local vulkan_sdk = os.getenv("VULKAN_SDK")
    local candidates = {}

    if type(vulkan_sdk) == "string" and vulkan_sdk ~= "" then
        if host_os == "windows" then
            candidates[#candidates + 1] = joinpath(vulkan_sdk, "Bin", "glslc.exe")
        elseif host_os == "macos" then
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

    if host_os == "windows" then
        return "glslc.exe"
    end
    return "glslc"
end

local function discover_shaders(project_root)
    local commands
    if host_os == "windows" then
        commands = {
            "dir /s /b " .. shell_escape("engine\\shaders\\*.vert") .. " 2>nul",
            "dir /s /b " .. shell_escape("engine\\shaders\\*.frag") .. " 2>nul",
        }
    else
        commands = {
            "find " .. shell_escape("engine/shaders") .. " -type f \\( -name '*.vert' -o -name '*.frag' \\) -print 2>/dev/null",
        }
    end

    local dedup = {}
    local shaders = {}

    for _, command in ipairs(commands) do
        local run_cmd
        if host_os == "windows" then
            run_cmd = "cd /d " .. shell_escape(project_root) .. " && " .. command
        else
            run_cmd = "cd " .. shell_escape(project_root) .. " && " .. command
        end

        local proc = io.popen(run_cmd)
        if not proc then
            return nil, "Could not enumerate shader files"
        end

        for raw in proc:lines() do
            local line = raw:gsub("\r$", "")
            if line ~= "" and line ~= "File Not Found" and not dedup[line] then
                dedup[line] = true
                shaders[#shaders + 1] = line
            end
        end

        proc:close()
    end

    table.sort(shaders)
    return shaders
end

local function main()
    local root = script_dir()
    local shaders, err = discover_shaders(root)
    if not shaders then
        io.stderr:write(err .. "\n")
        return false
    end
    if #shaders == 0 then
        io.stderr:write("No shaders found under engine/shaders\n")
        return false
    end

    local glslc = find_glslc()
    for _, shader in ipairs(shaders) do
        local cmd = command_to_string({ glslc, shader, "-o", shader .. ".spv" })
        local ok, compile_err = run_in_root(root, cmd)
        if not ok then
            io.stderr:write("Shader compile failed for " .. shader .. " (" .. tostring(compile_err) .. ")\n")
            return false
        end
    end

    return true
end

if not main() then
    os.exit(1)
end
