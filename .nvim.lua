local dap = require("dap")
local dap_view = require("dap-view")
local project_root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local joinpath = vim.fs.joinpath
local project_name = vim.fn.fnamemodify(project_root, ":t")
local output_name = project_name .. (is_windows and ".exe" or "")
local output_rel_path = joinpath("bin", output_name)
local program_path = joinpath(project_root, output_rel_path)
local uv = vim.uv or vim.loop

local lldb_dap = vim.fn.exepath("lldb-dap")
if lldb_dap == "" then
    lldb_dap = vim.fn.exepath("lldb-vscode")
end

if is_windows and lldb_dap ~= "" and not vim.g.odingame_dap_notify_filter_installed then
    local original_notify = vim.notify
    vim.notify = function(msg, level, opts)
        if type(msg) == "string" then
            local lower = msg:lower()
            if lower:match("^command `.-lldb%-dap%.exe` of adapter `lldb` exited with 1%. run :dapshowlog to open logs$") then
                return
            end
        end
        return original_notify(msg, level, opts)
    end
    vim.g.odingame_dap_notify_filter_installed = true
end

if lldb_dap ~= "" and dap.adapters.lldb == nil then
    dap.adapters.lldb = {
        type = "executable",
        command = lldb_dap,
        name = "lldb",
    }
end

dap.configurations.odin = {
    {
        name = "OdinGame (local)",
        type = "lldb",
        request = "launch",
        program = program_path,
        cwd = project_root,
        stopOnEntry = false,
        args = {},
    },
}

local function get_build_command()
    local function file_exists(path)
        return uv.fs_stat(path) ~= nil
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

    local function quote_if_needed(path)
        if path:find("%s") then
            return '"' .. path .. '"'
        end

        return path
    end

    if is_windows then
        local vulkan_sdk = vim.env.VULKAN_SDK
        if not vulkan_sdk or vulkan_sdk == "" then
            return nil, "VULKAN_SDK is not set"
        end

        local vulkan_lib_path = find_vulkan_lib_dir(vulkan_sdk)
        if not vulkan_lib_path then
            return nil, "Could not find vulkan-1.lib under VULKAN_SDK"
        end

        return {
            "odin",
            "build",
            ".",
            "-debug",
            "-subsystem:windows",
            "-out:" .. output_rel_path,
            "-extra-linker-flags:/LIBPATH:" .. quote_if_needed(vulkan_lib_path),
        }
    end

    return { "odin", "build", ".", "-debug", "-out:" .. output_rel_path }
end

local function build_command_to_string(build_cmd)
    local escaped = {}
    for _, part in ipairs(build_cmd) do
        table.insert(escaped, vim.fn.shellescape(part))
    end
    return table.concat(escaped, " ")
end

local function build_and_debug()
    if lldb_dap == "" then
        vim.notify("lldb-dap/lldb-vscode was not found in PATH", vim.log.levels.ERROR)
        return
    end

    vim.cmd("wall")
    vim.notify("Building app...")
    vim.fn.mkdir(joinpath(project_root, "bin"), "p")

    local build_cmd, build_error = get_build_command()
    if not build_cmd then
        vim.notify(build_error, vim.log.levels.ERROR)
        return
    end

    vim.system(build_cmd, { cwd = project_root, text = true }, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                local output = (res.stderr and res.stderr ~= "") and res.stderr or (res.stdout or "")
                vim.notify("Build failed:\n" .. output, vim.log.levels.ERROR)
                return
            end

            vim.notify("Build succeeded. Starting debugger...")
            dap.continue()
        end)
    end)
end

local function build_with_compile_mode()
    if vim.fn.exists(":Compile") == 0 then
        vim.notify("compile-mode.nvim is not available (:Compile missing)", vim.log.levels.ERROR)
        return
    end

    vim.cmd("wall")
    vim.fn.mkdir(joinpath(project_root, "bin"), "p")

    local build_cmd, build_error = get_build_command()
    if not build_cmd then
        vim.notify(build_error, vim.log.levels.ERROR)
        return
    end

    vim.cmd("Compile " .. build_command_to_string(build_cmd))
end

local function stop_debug_session()
    if dap.session() == nil then
        return
    end

    dap.disconnect({ terminateDebuggee = true })
    dap.close()
    dap_view.close()
end

vim.keymap.set("n", "<leader>de", build_and_debug, {
    desc = "Build + debug app",
    silent = true,
})

vim.keymap.set("n", "<leader>cb", build_with_compile_mode, {
    desc = "Build app (compile-mode)",
    silent = true,
})

vim.keymap.set("n", "<leader>dq", stop_debug_session, {
    desc = "Stop debug session",
    silent = true,
})
