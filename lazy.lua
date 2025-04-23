return {
  "qompassai/rose.nvim",
  event = "VeryLazy",
  lazy = true,
  config = function(_, opts)
    opts = opts or {}
  require("rose").setup(opts)
     local binary = require("rose.rose")
    binary.init()
    opts.default_provider = "qompass"
}  require("rose").setup(opts)
  end,
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim"
  }
}
