local dap = require("dap")
local dap_view = require("dap-view")
local project_root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local joinpath = vim.fs.joinpath
local program_path = joinpath(project_root, "bin", is_windows and "odingame.exe" or "odingame")
local build_script_path = joinpath(project_root, "build.lua")
local lua_bin = vim.fn.exepath("lua")
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
        console = "internalConsole",
        program = program_path,
        cwd = project_root,
        stopOnEntry = false,
        args = {},
    },
}

local function command_to_string(cmd)
    local escaped = {}
    for _, part in ipairs(cmd) do
        table.insert(escaped, vim.fn.shellescape(part))
    end
    return table.concat(escaped, " ")
end

local function build_and_debug()
    if lldb_dap == "" then
        vim.notify("lldb-dap/lldb-vscode was not found in PATH", vim.log.levels.ERROR)
        return
    end

    if lua_bin == "" then
        vim.notify("lua was not found in PATH", vim.log.levels.ERROR)
        return
    end

    if uv.fs_stat(build_script_path) == nil then
        vim.notify("build.lua not found in project root", vim.log.levels.ERROR)
        return
    end

    vim.cmd("wall")
    vim.notify("Building app...")

    vim.system({ lua_bin, build_script_path }, { cwd = project_root, text = true }, function(res)
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

local function open_run_terminal(cmd_array)
    vim.cmd("botright new")
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false

    local job_id = vim.fn.jobstart(cmd_array, {
        cwd = project_root,
        term = true,
        on_exit = function(_, code)
            if code ~= 0 then
                vim.schedule(function()
                    vim.notify("Run exited with code: " .. code, vim.log.levels.WARN)
                end)
            end
        end,
    })

    if job_id <= 0 then
        vim.notify("Failed to start app process", vim.log.levels.ERROR)
        return
    end

    vim.cmd("startinsert")
end

local function build_with_compile_mode(build_target)
    if vim.fn.exists(":Compile") == 0 then
        vim.notify("compile-mode.nvim is not available (:Compile missing)", vim.log.levels.ERROR)
        return
    end

    if lua_bin == "" then
        vim.notify("lua was not found in PATH", vim.log.levels.ERROR)
        return
    end

    if uv.fs_stat(build_script_path) == nil then
        vim.notify("build.lua not found in project root", vim.log.levels.ERROR)
        return
    end

    vim.cmd("wall")

    local cmd = { lua_bin, build_script_path }
    if build_target == "game" then
        cmd[#cmd + 1] = "game"
    end

    vim.cmd("Compile " .. command_to_string(cmd))
end

local function stop_debug_session()
    if dap.session() == nil then
        return
    end

    dap.disconnect({ terminateDebuggee = true })
    dap.close()
    dap_view.close()
end

vim.keymap.set("n", "<leader>bd", build_and_debug, {
    desc = "Build + debug app",
    silent = true,
})

vim.keymap.set("n", "<F6>", build_and_debug, {
    desc = "Build + debug app",
    silent = true,
})

vim.keymap.set("n", "<leader>bb", build_with_compile_mode, {
    desc = "Build app + game DLL (compile-mode)",
    silent = true,
})

vim.keymap.set("n", "<F5>", build_with_compile_mode, {
    desc = "Build app + game DLL (compile-mode)",
    silent = true,
})

vim.keymap.set("n", "<leader>bg", function()
    build_with_compile_mode("game")
end, {
    desc = "Build game DLL only (compile-mode)",
    silent = true,
})

vim.keymap.set("n", "<F7>", function()
    build_with_compile_mode("game")
end, {
    desc = "Build game DLL only (compile-mode)",
    silent = true,
})
