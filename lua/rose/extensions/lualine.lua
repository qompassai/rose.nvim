--[[
--NOTE: Having cmd = "Rose" or lazy = true in user's lazy config, and adding lualine component using require("rose.extensions.lualine") will start the hub indirectly.
--]]
local M = require("lualine.component"):extend()
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_interval = 80 -- ms between frames
local timer = nil
local current_frame = 1

M.RoseState = {
    STARTING = "starting",
    READY = "ready",
    ERROR = "error",
    RESTARTING = "restarting",
    RESTARTED = "restarted",
    STOPPED = "stopped",
    STOPPING = "stopping",
}

vim.g.rose_status = M.RoseState.STARTING
function M:init(options)
    M.super.init(self, options)
    self:create_autocommands()
end

function M:create_autocommands()
    local group = vim.api.nvim_create_augroup("rose_lualine", { clear = true })

    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "RoseStateChange",
        callback = function(args)
            self:manage_spinner()
            if args.data then
                vim.g.rose_status = args.data.state
                vim.g.rose_active_servers = args.data.active_servers
            end
        end,
    })

    -- Tool/Resource activity events
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "Rose*" },
        callback = function(args)
            if args.match == "RoseToolStart" then
                vim.g.rose_executing = true
                vim.g.rose_tool_active = true
                vim.g.rose_tool_info = args.data
            elseif args.match == "RoseToolEnd" then
                vim.g.rose_executing = false
                vim.g.rose_tool_active = false
                vim.g.rose_tool_info = nil
            elseif args.match == "RoseResourceStart" then
                vim.g.rose_executing = true
                vim.g.rose_resource_active = true
                vim.g.rose_resource_info = args.data
            elseif args.match == "RoseHubResourceEnd" then
                vim.g.rose_executing = false
                vim.g.rose_resource_active = false
                vim.g.rose_resource_info = nil
            elseif args.match == "RosePromptStart" then
                vim.g.rose_executing = true
                vim.g.rose_prompt_active = true
                vim.g.rose_prompt_info = args.data
            elseif args.match == "RoseHubPromptEnd" then
                vim.g.rose_executing = false
                vim.g.rose_prompt_active = false
                vim.g.rose_prompt_info = nil
            end
            -- Manage animation
            self:manage_spinner()
        end,
    })
end

function M.is_connected()
    return vim.g.rose_status == M.RoseState.READY or vim.g.rose_status == M.RoseState.RESTARTED
end

function M.is_connecting()
    return vim.g.rose_status == M.RoseState.STARTING or vim.g.rose_status == M.RoseState.RESTARTING
end

function M:manage_spinner()
    local should_show = vim.g.mcphub_executing and M.is_connected()
    if should_show and not timer then
        timer = vim.loop.new_timer()
        timer:start(
            0,
            spinner_interval,
            vim.schedule_wrap(function()
                current_frame = (current_frame % #spinner_frames) + 1
                vim.cmd("redrawstatus")
            end)
        )
    elseif not should_show and timer then
        timer:stop()
        timer:close()
        timer = nil
        current_frame = 1
    end
end

-- Get appropriate status icon and highlight
function M:get_status_display()
    local tower = "󰐻"
    return tower, M.is_connected() and "DiagnosticInfo" or M.is_connecting() and "DiagnosticWarn" or "DiagnosticError"
end

-- Format with highlight
function M:format_hl(text, hl)
    if hl then
        return string.format("%%#%s#%s%%*", hl, text)
    end
    return text
end

function M:update_status()
    local status_icon, status_hl = self:get_status_display()

    local count_or_spinner = vim.g.mcphub_executing and spinner_frames[current_frame]
        or tostring(vim.g.mcphub_active_servers or 0)
    return self:format_hl(status_icon .. " " .. count_or_spinner .. " ", status_hl)
end

function M:disable()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
end

return M
