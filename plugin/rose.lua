-- Command registration only: no processes, providers, builds or secret reads.
if vim.g.loaded_rose_native then
  return
end
vim.g.loaded_rose_native = true
require("rose").register_commands()
