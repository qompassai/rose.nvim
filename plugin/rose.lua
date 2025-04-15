---@class LazyPluginSpec
---@field name string
---@field config fun():nil
---@field dependencies? string[] | table[]
---@field lazy? boolean
return {
    "qompassai/rose.nvim",
    lazy = true,
    dependencies = {
        "nvim-lua/plenary.nvim",
        "nvim-telescope/telescope.nvim",
        "rcarriga/nvim-notify",
        "folke/noice.nvim",
        "folke/edgy.nvim",
    },
    config = function()
        local ok, rose = pcall(require, "rose")
        if ok and not rose.did_setup then
            rose.setup()
        end

        for _, name in ipairs({ "curl", "grep", "rg", "ln" }) do
            if type(vim.fn.executable) == "function" and vim.fn.executable(name) == 0 then
                vim.notify(name .. " is not installed, run :checkhealth rose", vim.log.levels.ERROR)
            end
        end

        local timer = vim.uv.new_timer()
        timer:start(
            500,
            0,
            vim.schedule_wrap(function()
                local ok2, rose2 = pcall(require, "rose")
                if ok2 and not rose2.did_setup then
                    rose2.setup()
                end
            end)
        )

        vim.api.nvim_create_user_command("RoseConfig", function()
            require("rose.menu").open()
        end, {})
    end,
}
