local M = {}

---@type Rose.Config.Defaults
M.defaults = {
    legacy = false,
    trusted = false,
    ollama = {
        base_url = 'http://127.0.0.1:11434',
        model = 'qwen2.5-coder:7b',
        timeout = 120000,
        allow_remote = false,
        transport = 'auto',
    },
    providers = {
        enabled = false,
        allow_cloud = false,
        provider = 'ollama',
    },
    speech = {
        enabled = false,
        stt = {
            provider = 'auto',
            model = nil,
            language = 'auto',
        },
        tts = {
            provider = 'auto',
            model = nil,
            voice = nil,
            format = 'mp3',
        },
        record = { cmd = nil, max_seconds = 60 },
        play = { cmd = nil },
        whisper = {
            url = nil,
        },
        piper = {
            cmd = nil,
            model = nil,
        },
        max_audio_bytes = 25 * 1024 * 1024,
        max_text_chars = 4096,
    },
    hub = {
        python = 'python3',
        max_workers = 4,
        xet = 'auto',
        high_performance = false,
    },
    agent = {
        max_iterations = 6,
        max_repair_rounds = 1,
        max_tool_calls = 8,
        max_tool_result = 24000,
        max_context = 120000,
    },
    diver = { lsp = {} },
    debug = {},
    checks = {},
    scip = { path = 'index.scip.json' },
    flow = { cmd = { 'flow', 'serve' }, timeout = 600000, bridge = true },
    mcp = { servers = {} },
    webui = {
        enabled = false,
        host = '127.0.0.1',
        port = 0,
        open = true,
        max_request_bytes = 16 * 1024 * 1024,
        max_clients = 8,
        idle_timeout_ms = 30000,
    },
}

local loopback_hosts = { ['127.0.0.1'] = true, ['::1'] = true, ['localhost'] = true }

local function integer(value, lo, hi, name)
    assert(type(name) == 'string', 'integer(): name must be a string')
    assert(lo <= hi, 'integer(): lo must not exceed hi')
    local range = name .. ' must be an integer in ' .. lo .. '..' .. hi
    assert(type(value) == 'number', range)
    assert(value % 1 == 0, range)
    assert(value >= lo, range)
    assert(value <= hi, range)
end

local function resolve_workspace(configured)
    local uv = vim.uv or vim.uv
    local root = configured or uv.cwd()
    assert(type(root) == 'string', 'workspace must be a path')
    assert(root ~= '', 'workspace must be a path')
    root = vim.fn.fnamemodify(root, ':p'):gsub('[/\\]+$', '')
    if root == '' then
        root = '/'
    end
    local real = assert(uv.fs_realpath(root), 'workspace does not exist')
    local stat = uv.fs_stat(real)
    assert(stat and stat.type == 'directory', 'workspace must be a directory')
    return real
end

local function validate_webui(webui)
    assert(type(webui) == 'table', 'webui must be a table')
    assert(type(webui.enabled) == 'boolean', 'webui.enabled must be a boolean')
    assert(type(webui.open) == 'boolean', 'webui.open must be a boolean')
    assert(loopback_hosts[webui.host] == true, 'webui.host must be a loopback address')
    integer(webui.port, 0, 65535, 'webui.port')
    integer(webui.max_request_bytes, 4096, 268435456, 'webui.max_request_bytes')
    integer(webui.max_clients, 1, 64, 'webui.max_clients')
    integer(webui.idle_timeout_ms, 100, 600000, 'webui.idle_timeout_ms')
end

local checks_max = 256

local function validate_checks(checks)
    assert(type(checks) == 'table', 'checks must be a table of named commands')
    local count = 0
    for name, check in pairs(checks) do
        count = count + 1
        assert(count <= checks_max, 'checks must define at most ' .. checks_max .. ' entries')
        assert(type(name) == 'string', 'checks must be a table of named configurations')
        assert(type(check) == 'table', 'checks must be a table of named configurations')
        if check.filetypes ~= nil then
            assert(type(check.filetypes) == 'table', 'check.filetypes must be an array')
        end
    end
end
---@return table<string, Rose.Config.MCPServer>

local function mcp_defaults(workspace)
    local config_home = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME, '.config')
    return {
        mcpls = {
            cmd = {
                'mcpls',
                '--config',
                vim.fs.joinpath(config_home, 'mcpls', 'mcpls.toml'),
            },
            trusted = true,
            readonly = true,
            timeout = 60000,
            allowtools = {
                'lsp_hover',
                'lsp_definition',
                'lsp_references',
                'lsp_diagnostics',
                'lsp_document_symbols',
                'lsp_workspace_symbols',
                'lsp_completion',
                'lsp_signature_help',
                'lsp_inlay_hints',
            },
        },
        mcp_rust = {
            cmd = {
                'mcp-language-server',
                '--workspace',
                workspace,
                '--lsp',
                'rust-analyzer',
            },
            trusted = true,
            readonly = true,
            timeout = 60000,
            allowtools = {
                'definition',
                'references',
                'diagnostics',
                'hover',
            },
        },
    }
end

local function validate_argv(argv, name)
    assert(type(argv) == 'table' and #argv > 0 and #argv <= 64, name .. ' must be a nonempty argv array')
    for index, value in ipairs(argv) do
        assert(
            type(value) == 'string' and value ~= '' and not value:find('\0', 1, true),
            name .. ' has invalid argument ' .. index
        )
    end
end

---@param mcp Rose.Config.MCP
local function validate_mcp(mcp)
    assert(type(mcp) == 'table', 'mcp must be a configuration table')
    assert(type(mcp.servers) == 'table', 'mcp.servers must be a table of named servers')

    local servers = mcp.servers or {}

    for name, server in pairs(servers) do
        assert(type(name) == 'string' and name ~= '', 'mcp server names must be nonempty strings')

        assert(type(server) == 'table', 'mcp.' .. name .. ' must be a table')

        local cmd = rawget(server, 'cmd')
        assert(type(cmd) == 'table', 'mcp.' .. name .. '.cmd must be an argv array')
        validate_argv(cmd, 'mcp.' .. name .. '.cmd')

        local trusted = rawget(server, 'trusted')
        assert(type(trusted) == 'boolean', 'mcp.' .. name .. '.trusted must be a boolean')

        local readonly = rawget(server, 'readonly')
        assert(type(readonly) == 'boolean', 'mcp.' .. name .. '.readonly must be a boolean')

        local timeout = rawget(server, 'timeout')
        assert(type(timeout) == 'number', 'mcp.' .. name .. '.timeout must be an integer')
        integer(timeout, 1, 3600000, 'mcp.' .. name .. '.timeout')

        local allowtools = rawget(server, 'allowtools')
        if allowtools ~= nil then
            assert(type(allowtools) == 'table', 'mcp.' .. name .. '.allowtools must be an array')

            for index, tool in ipairs(allowtools) do
                assert(
                    type(tool) == 'string' and tool ~= '',
                    'mcp.' .. name .. '.allowtools has invalid tool ' .. index
                )
            end
        end

        local env = rawget(server, 'env')
        if env ~= nil then
            assert(type(env) == 'table', 'mcp.' .. name .. '.env must be a table')

            for key, value in pairs(env) do
                assert(type(key) == 'string' and key ~= '', 'mcp.' .. name .. '.env has invalid name')
                assert(
                    type(value) == 'string' and not value:find('\0', 1, true),
                    'mcp.' .. name .. '.env has invalid value'
                )
            end
        end
    end
end

---@param opts? Rose.Config
---@return Rose.Config.Resolved
function M.resolve(opts)
    opts = opts or {}
    assert(type(opts) == 'table', 'Rose setup options must be a table')

    local config = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
    if opts.agent and opts.agent.max_cycles ~= nil then
        integer(opts.agent.max_cycles, 1, 4, 'agent.max_cycles')
        if opts.agent.max_repair_rounds == nil then
            config.agent.max_repair_rounds = opts.agent.max_cycles - 1
        end
    end

    assert(type(config.trusted) == 'boolean', 'trusted must be a boolean')
    config.workspace = resolve_workspace(config.workspace)

    config.mcp.servers = vim.tbl_deep_extend('keep', config.mcp.servers or {}, mcp_defaults(config.workspace))

    integer(config.ollama.timeout, 1, 3600000, 'ollama.timeout')
    integer(config.agent.max_iterations, 1, 30, 'agent.max_iterations')
    integer(config.agent.max_repair_rounds, 0, 3, 'agent.max_repair_rounds')
    config.agent.max_cycles = config.agent.max_repair_rounds + 1
    integer(config.agent.max_tool_calls, 1, 32, 'agent.max_tool_calls')
    integer(config.agent.max_tool_result, 256, 1048576, 'agent.max_tool_result')
    integer(config.agent.max_context, 1024, 4194304, 'agent.max_context')
    integer(config.flow.timeout, 1, 3600000, 'flow.timeout')
    validate_webui(config.webui)
    validate_mcp(config.mcp)

    assert(type(config.ollama.model) == 'string', 'ollama.model is required')
    assert(config.ollama.model ~= '', 'ollama.model is required')
    assert(type(config.ollama.base_url) == 'string', 'ollama.base_url must be a string')
    assert(type(config.providers) == 'table', 'providers must be a configuration table')
    assert(type(config.hub) == 'table', 'hub must be a configuration table')
    assert(type(config.speech) == 'table', 'speech must be a configuration table')
    assert(type(config.speech.enabled) == 'boolean', 'speech.enabled must be a boolean')

    local speech_ok, speech = pcall(require, 'rose.speech')
    if speech_ok then
        speech.config(config)
    else
        package.loaded['rose.speech'] = nil
    end

    validate_checks(config.checks)
    assert(type(config.workspace) == 'string', 'resolved workspace must be a string')

    ---@cast config Rose.Config.Resolved
    return config
end

---@param opts? Rose.Config
---@return Rose.Config.Resolved
function M.setup(opts)
    M.options = M.resolve(opts)
    return M.options
end

return M
