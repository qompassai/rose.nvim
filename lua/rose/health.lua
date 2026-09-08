-- :checkhealth rose. Reports configuration and local capabilities only; it never contacts a
-- provider, reads an API key or spawns a recorder/player.
local M = {}

local function check_runtime()
  if type(vim.system) == "function" then
    vim.health.ok("vim.system available")
  else
    vim.health.warn("vim.system missing: HTTP, MCP and named checks require Neovim 0.10+")
  end
  local capabilities = require("rose.native.http").capabilities()
  if capabilities.native_request then
    vim.health.ok(
      "vim.net.request available (currently curl-backed; auto uses hardened curl until "
        .. "safe options exist)"
    )
  else
    vim.health.info("vim.net.request unavailable; hardened vim.system curl fallback supported")
  end
  if capabilities.curl then
    vim.health.ok("curl executable available")
  else
    vim.health.warn("curl missing: Ollama HTTP unavailable in both current transports")
  end
  if vim.lsp and vim.lsp.get_clients then
    vim.health.ok("Native LSP client discovery available")
  else
    vim.health.warn("Native LSP discovery unavailable; editor tools will report unavailable")
  end
  if vim.diagnostic and vim.diagnostic.get then
    vim.health.ok("Native diagnostics available")
  end
end

local function check_model(options)
  assert(type(options) == "table", "check_model: options must be a table")
  local model = require("rose.native.model")
  local info, model_caps = model.describe(options), model.capabilities(options)
  vim.health.info(
    "Configured model: "
      .. info.provider
      .. " / "
      .. tostring(info.model)
      .. " (not contacted by health check)"
  )
  if info.cloud then
    vim.health.warn(
      "Explicit cloud mode: tasks, source context and tool output leave this device; "
        .. "keys are checked only when requests run."
    )
    if not model_caps.tools then
      vim.health.warn(
        "Selected API/model has not enabled custom tools; use chat or explicitly configure "
          .. "a tool-capable model."
      )
    end
  else
    vim.health.ok("Local Ollama is selected; cloud providers are not contacted")
  end
end

local function check_hub(rose)
  local hub = package.loaded["rose.hub"]
  if rose.hub_error then
    vim.health.warn("Hugging Face: " .. rose.hub_error)
  elseif hub then
    vim.health.info(
      "Hugging Face transfers are manual; Python SDK/Xet availability and credentials are "
        .. "checked only at execution."
    )
    if vim.fn.executable(rose.options.hub.python) ~= 1 then
      vim.health.warn("Configured Hugging Face Python executable is unavailable")
    end
  end
end

local function check_webui(rose)
  vim.health.start("Rose web UI")
  local webui_ok, webui = pcall(require, "rose.webui")
  if not webui_ok then
    vim.health.warn("Web UI module unavailable: " .. tostring(webui))
    return
  end
  if rose.webui_error then
    vim.health.error("Web UI setup failed: " .. rose.webui_error)
    return
  end
  local section = webui.section(rose.options)
  local status = webui.status()
  if not section.enabled then
    vim.health.info("Web UI disabled; set webui.enabled = true and run :RoseWebUI")
  elseif status.running then
    vim.health.ok(
      string.format(
        "Web UI listening on %s:%d (%d clients, %d requests served)",
        status.host,
        status.port,
        status.clients,
        status.requests_served
      )
    )
  else
    vim.health.ok("Web UI enabled but not running; :RoseWebUI starts it on " .. section.host)
  end
  vim.health.info("Web UI is loopback-only, plaintext HTTP, per-session bearer token; no TLS")
end

local function check_flow(options)
  local flow_cmd = options.flow.cmd
  local flow_available = false
  if type(flow_cmd) == "table" and flow_cmd[1] then
    flow_available = vim.fn.executable(flow_cmd[1]) == 1
  end
  if flow_available then
    vim.health.ok("Configured Flow executable available")
  else
    vim.health.info("Flow CLI missing; standalone RoseAsk/RoseAgent do not require it")
  end
end

-- Speech capabilities and tool detection call vim.fn.executable() only.
local function check_speech(options)
  local speech_ok, speech = pcall(require, "rose.speech")
  if not speech_ok then
    return
  end
  if not (options.speech and options.speech.enabled) then
    vim.health.info(
      "Speech disabled; set speech.enabled = true (cloud also needs providers.allow_cloud)"
    )
    return
  end
  local caps = speech.capabilities(options)
  for _, kind in ipairs({ "stt", "tts" }) do
    for _, item in ipairs(caps[kind]) do
      if item.available then
        vim.health.ok("speech " .. kind .. " " .. item.provider .. " configured")
      else
        vim.health.info("speech " .. kind .. " " .. item.provider .. ": " .. item.reason)
      end
    end
  end
  local audio = require("rose.speech.audio")
  local recorder, why = audio.detect(audio.recorders, options.speech.record.cmd, "record")
  if recorder then
    vim.health.ok("speech recorder: " .. recorder[1])
  else
    vim.health.warn(why or "speech recorder unavailable")
  end
  local player, play_why = audio.detect(audio.players.wav, options.speech.play.cmd, "play")
  if player then
    vim.health.ok("speech player: " .. player[1])
  else
    vim.health.warn(play_why or "speech player unavailable")
  end
end

function M.check()
  vim.health.start("Rose native core")
  local rose = require("rose")
  if rose.legacy then
    vim.health.warn("Historical legacy mode is unsupported; see docs/legacy.md")
    return
  end
  check_runtime()
  if rose.did_setup then
    vim.health.ok("Native configuration loaded; workspace: " .. rose.options.workspace)
    vim.health.info("Workspace trusted: " .. tostring(rose.options.trusted))
    check_model(rose.options)
    check_hub(rose)
    check_webui(rose)
    if rose.tool_error then
      vim.health.error(rose.tool_error)
    end
    if next(rose.options.checks) == nil then
      vim.health.warn("No named checks: agent validation remains unverified")
    end
    check_flow(rose.options)
    check_speech(rose.options)
  else
    vim.health.info("Call require('rose').setup(opts) to configure the workspace")
  end
  vim.health.info(
    "No assumed vim.debug API. Optional Rose stdio DAP probe requires an explicitly configured "
      .. "adapter; no full debug UI."
  )
  vim.health.info(
    "No plenary, fzf-lua, Rust build or secret store required. Local Ollama needs no key; "
      .. "opt-in cloud/Hugging Face operations may require credentials."
  )
end

return M
