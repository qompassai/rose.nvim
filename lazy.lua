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
    "RoseDictate",
    "RoseSpeak",
    "RoseSpeechStop",
    "RoseSpeechStatus",
    "RoseWebUI",
    "RoseWebUIStop",
    "RoseWebUIStatus",
  },
  ---@type Rose.Config
  opts = { trusted = false },
}
