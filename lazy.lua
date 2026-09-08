-- Optional Lazy specification. Native vim.pack/native packages work without it.
return {
  "qompassai/rose.nvim",
  main = "rose",
  cmd = {
    "RoseAsk",
    "RoseAgent",
    "RoseCheck",
    "RoseFlow",
    "RoseStop",
    "RoseHubDownload",
    "RoseHubUpload",
    "RoseHubPaper",
    "RoseHubStop",
    "RoseHubStatus",
  },
  opts = { trusted = false },
}
