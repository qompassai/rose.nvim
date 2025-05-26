--/qompassai/rose.nvim/rose.nvim-1.0-1.rockspec
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
package = "rose.nvim"
version = "1.0-1"
source = {
  url = "git+https://github.com/qompassai/rose.nvim.git",
  tag = "v1.0.0",
}
description = {
  summary = "rose.nvim: Your Quality AI Menu",
  detailed = [[
    Designed for 0.1x developers & 10x developers alike.
  ]],
  homepage = "https://github.com/qompassai/rose.nvim",
  license = "Q-CDA 1.0",
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    ["rose"] = "lua/rose/init.lua",
    ["init"] = "lua/init.lua",
  },
  copy_directories = {
    "plugin",
    "crates",
    "tests",
  },
}
