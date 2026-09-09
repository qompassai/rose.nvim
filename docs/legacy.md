# Migrating from historical Rose

Native mode replaces the old dependency-heavy default. Do not carry old provider
options into native setup expecting them to work: they are not native providers.

1. Remove old build/download hooks and Plenary/fzf requirements from your Rose
   plugin specification. Other plugins may still need them.
2. Configure `rose.base_url`, `rose.model`, workspace trust and named checks.
   Nothing reads password stores or automatically chooses a cloud provider.
   For older *native* Ollama-only configs (not historical cloud configs), the
   compatibility selection/precedence rules are in
   [configuration.md](configuration.md#provider-selection-and-migration-precedence).
3. Replace menu/finder commands with `RoseAsk`, `RoseAgent`, `RoseCheck`,
   `RoseFlow` and `RoseStop`. `RoseConfig` and `RoseDownload` are not native
   commands; `rose_check()` returns false and `get_binary_path()` returns nil.
4. Configure language servers/checkers explicitly. An empty diagnostic list is
   not a test result; unconfigured projects remain unverified.
5. Use the optional Flow CLI for its workflow, not an implicit Rose binary.

## Historical mode

```lua
require("rose").setup({ legacy = true, --[[ historical provider options ]] })
```

This is an **explicit opt-in to old executable behavior**, not a supported
compatibility promise. It may load Plenary/fzf-lua, access password-store API
keys and binary helpers, or need Rust/CMake components. Its original
configuration has known initialization defects (including undefined
`defaults`/`opts` references); enabling it may fail immediately. Rose surfaces
the actual error rather than pretending migration succeeded.

The old configuration/entrypoint are preserved under `lua/rose/legacy/`; other
historical modules remain in place but native setup does not require them.
The old dependency/secret-reading Lazy specification is also archived there as
`rose.legacy.lazy`; the optional root `lazy.lua` now describes only native setup.
The [archived README](legacy-readme.md) documents the old ecosystem, not native
installation. Pin an already-working historical revision with its matching
dependencies if you must retain that workflow, or migrate to native commands.
Old LuaRocks/Rust build metadata is historical and not the native installation
path. Do not assume an old configuration becomes safe merely by passing
`legacy=true`.
