# Hugging Face transfers

Rose's Hub integration is optional, native Neovim Lua plus a small Python worker.
It transfers explicitly selected model/dataset assets and looks up paper metadata.
It **does not load models, execute downloaded code, provide model-callable tools,
submit papers to arXiv, create repositories, or delete remote files**.

## Requirements and opt-in setup

- Neovim with `vim.system`, `vim.ui.select` and `vim.ui.input`; no third-party
  Neovim plugins are required.
- POSIX (Linux/macOS) with secure descriptor-relative `O_NOFOLLOW` file access.
  Windows transfers currently fail closed.
- A configured Python environment containing the official `huggingface_hub`.
  Recent Hub installations include the optional `hf_xet` native dependency;
  installing it explicitly is also supported by Hugging Face.
  [Official Xet installation documentation](https://huggingface.co/docs/hub/xet/using-xet-storage).

Install dependencies yourself in the Python environment Rose will use:

```sh
python3 -m venv ~/.local/share/rose-hub-venv
~/.local/share/rose-hub-venv/bin/python -m pip install -U huggingface_hub hf_xet
```

User configuration, **not repository/model-provided configuration**:

```lua
local hub = require("rose.hub").setup({
  workspace = "/absolute/real/path/to/my-workspace",
  trusted = false, -- set true yourself before an explicitly requested upload
  python = vim.fn.expand("~/.local/share/rose-hub-venv/bin/python"),
  cache_dir = vim.fn.stdpath("cache") .. "/rose/huggingface",
  max_workers = 4,
  max_files = 256,
  max_total_bytes = 10 * 1024 ^ 3, -- selected byte limit, not a download target
  xet = "auto", -- "auto" or "disabled"
  high_performance = false,
  timeout_ms = 0, -- 0 = no overall deadline; stop/cancel remains available
  on_progress = function(event)
    -- Optional native UI integration. Events have phase/completed/total where known.
    -- Progress counts files, NOT fabricated byte-per-second measurements.
  end,
})
hub.commands() -- optional; setup never installs commands or starts a process
```

Workspace must already exist, be an absolute real path, and contain no symlink
components. `cache_dir` must be absolute, outside the workspace, and have no
symlink ancestry; it is created only on an explicit operation. Do not put the cache
on a shared/untrusted writable volume. Source and destination paths are relative
to the workspace. Settings are snapshotted per operation; `setup` refuses while
an operation is active.

**Editor buffer boundary:** this module is disk-based and independent of
`rose.tools` buffer snapshots. Uploads use saved on-disk bytes, **not unsaved
Neovim buffer edits**. Downloads do not silently reload or synchronize loaded
buffers, and there is currently no dirty-buffer transfer guard. Save and close
relevant source/destination asset buffers before transferring; reopen/reload
downloaded files explicitly afterward. Otherwise a still-open buffer may show
stale content or a later save may overwrite the downloaded file.

### Performance profile

For a capable high-bandwidth host with ample memory and a local SSD/NVMe cache:

```lua
require("rose.hub").setup({
  workspace = "/home/me/work/models",
  trusted = true,
  python = "/home/me/.local/share/rose-hub-venv/bin/python",
  cache_dir = "/local/nvme/rose-hub",
  xet_cache = "/local/nvme/rose-hub-xet",
  high_performance = true, -- sets HF_XET_HIGH_PERFORMANCE=1 before SDK import
  max_workers = 8, -- configurable 1..16, not an unbounded fan-out
  max_files = 1024, -- configurable 1..4096, all files still individually previewed
  max_total_bytes = 100 * 1024 ^ 3,
})
```

Hugging Face recommends high-performance mode for high bandwidth and at least
64 GB RAM; it increases memory buffers and can degrade performance on smaller
machines. Rose defaults it off to leave resources for on-device inference and the
editor. `HF_XET_CACHE` on local SSD/NVMe is preferable to a network-mounted cache.
Neither this profile nor Xet guarantees the fastest transfer in every environment.
[Official Xet performance guidance](https://huggingface.co/docs/hub/xet/using-xet-storage).

Rose bounds its concurrent file downloads and HTTP upload workers with
`max_workers`, permits one active Hub job per module, and sets the official current
Xet adaptive minimum/initial stream counts to 1 and maxima/file-ingestion/range-GET
counts to `max_workers`. Xet's internal concurrency is not the same as file-worker
count or a total CPU/thread limit; older `hf_xet` builds may ignore newer environment
controls. Upgrade the SDK/Xet pair or use `xet = "disabled"` when strict compatibility
is needed. High-performance mode does not remove Rose's configured bounds.
[Official adaptive-concurrency controls](https://huggingface.co/docs/hub/xet/using-xet-storage).

## API

All operation APIs return `{ id = number, cancel = function() ... end }`.
The optional `cb(err, result)` runs once, asynchronously, including validation
failures and cancellation. Without a callback, final status/errors use `vim.notify`.
There is at most one active operation; a second returns an asynchronous busy error.

```lua
local token = require("rose.hub").download(spec, function(err, result)
  if err then vim.notify(err, vim.log.levels.ERROR); return end
  vim.notify(vim.inspect(result))
end)
token.cancel() -- equivalent to hub.stop() for this job
```

`hub.status()` returns a defensive copy of active `{ id, state, direction,
progress }` or the last `{ id, state, direction, error, result }`. States include
`idle`, `starting`, `previewing`, `confirming`, `metadata`, `transferring`, `done`,
`error`, `cancelled`. `hub.stop()` returns whether an active cancellation was
requested. Setup-time `on_progress(event)` receives sanitized capability and
phase/file-count events. Hashing/staging/individual downloads report file counts;
the official upload pipeline currently has a phase-start event and completion,
not an estimated byte rate or granular upload percentage.

### Download: preview, approve, pin

```lua
require("rose.hub").download({
  repo_id = "organization/existing-model",
  repo_type = "model", -- only "model" or "dataset"; default model
  revision = "main",   -- branch, tag or commit; default main
  files = { "config.json", "model.safetensors" }, -- exact repo-relative names
  destination = "models/example",              -- workspace-relative directory
  dry_run = true,
}, function(err, preview)
  if not err then vim.notify(vim.inspect(preview)) end
end)
```

`dry_run = true` performs metadata requests, not content transfers; it returns the
preview without approval or execution. Omit it for an interactive transfer: Rose
shows a complete native scratch-buffer manifest and asks via `vim.ui.select`.
The preview includes repo/type, public/private visibility, requested revision,
pinned commit SHA, every file, sizes, cached/download bytes, destination paths,
and any existing-file overwrite with its SHA-256. Re-run with `dry_run = false`
to obtain a **fresh** preview and approve a transfer.

The worker feature-detects `hf_hub_download(..., dry_run=True)` by inspecting the
installed signature. Older SDKs use `repo_info(files_metadata=True)` and the
official `try_to_load_from_cache` without downloading content; missing size/commit
information fails closed. All subsequent file requests use the previewed commit,
not a moving branch. Official dry-run fields include name, commit, size, cache
status and whether content would be downloaded.
[Official download guide](https://huggingface.co/docs/huggingface_hub/guides/download).

Actual downloads go into the persistent official Hub cache first. Only after all
network downloads succeed does Rose securely copy them into the selected
workspace destination, rechecking existing-file hashes and directory boundaries.
Copies are atomic **per file**, not a transaction over the whole selection.
Cancellation or a destination conflict can leave already-copied files in place;
they are shown as explicit overwrites on the next fresh preview. No cache files
are removed on failure/cancellation.

### Upload: existing repo + trust + exact approval

```lua
require("rose.hub").upload({
  repo_id = "my-account/my-existing-dataset",
  repo_type = "dataset",
  revision = "main",
  files = { "curated/train.parquet", "README.md" },
  path_in_repo = "release-v1", -- optional prefix; defaults to repository root
}, function(err, result)
  if err then vim.notify(err, vim.log.levels.ERROR) end
end)
```

Uploads require `trusted = true` in user/core setup. The repo must already exist
and have a usable commit and known visibility. Rose never creates a repo, changes
visibility, creates a PR, or deletes remote content. Named assets may be overwritten.
The native preview shows **every local path -> remote path, byte size, SHA-256,
repo/type/revision/parent commit, and public/private visibility**. Selecting Cancel
or closing the prompt does not upload. `dry_run = true` is also available for an
upload-only preview and still requires workspace trust.

Immediately before upload the helper revalidates the original inode, size,
timestamps and content hash, creates a private staged copy containing only the
explicit selection, verifies content while copying, rechecks the original
selection, and rechecks remote SHA/visibility. It supplies `parent_commit` to the
official API. Visibility checking and a multi-batch upload are not one atomic
server transaction; concurrent remote administrators can still change visibility.
The parent constraint applies only to the first batch of a streamed upload.
[Official upload API](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api#huggingface_hub.HfApi.upload_folder).

This secure staging costs additional reads and up to one extra local copy of
selected data. It is deliberate: a model cannot add files after confirmation or
turn a whole-workspace scan into an accidental upload. Staging is retained under
`cache_dir/staging/` for inspection and interrupted-transfer recovery. Rose does
not silently clean or delete it. Budget free disk space for staging plus Hub/Xet
caches, and manually manage old local staging only when no transfer is active.

#### Trusted application approval capability

The default is native user confirmation. A UI owner may instead supply a
**setup-time function** that independently presents the exact preview to the user
and returns that complete approved data:

```lua
require("rose.hub").setup({
  workspace = "/home/me/work/assets",
  trusted = true,
  approve_upload = function(preview, respond)
    -- Your trusted UI MUST show the full preview and obtain explicit approval.
    my_trusted_confirmation_ui(preview, function(approved_by_user)
      respond(approved_by_user and vim.deepcopy(preview) or nil)
    end)
  end,
})
```

Rose accepts only a deep-equal complete preview; `respond(true)`, altered
destinations, and reused callback invocations fail or are ignored. This callback
is an application capability, not proof that an arbitrary caller showed a UI:
do not set it to an unconditional approval function, deserialize it from repository
content, or expose it to a model. The `spec` has **no** `approved`, `confirmed`,
`trusted`, token, endpoint, command, arbitrary URL, or `trust_remote_code` field.
Unknown fields are rejected. There is intentionally no default model tool schema.

### Xet, compatibility and fallback

The worker imports the official SDK only during an explicit operation, after
setting its environment. It inspects installed versions and public signatures.
With usable `hf_xet`, it calls `HfApi.upload_folder` on the exact staging
selection. **It never calls `upload_large_folder` or `hf upload-large-folder`.**
Current `upload_folder` uses streamed Xet uploads and adaptive commit batches;
older SDKs may use their older `upload_folder` implementation. The deprecated
large-folder APIs must not be selected merely because a transfer is large.
[Official current upload guide](https://huggingface.co/docs/huggingface_hub/guides/upload).

With missing/broken optional Xet, explicit `xet = "disabled"`, or an inherited
`HF_HUB_DISABLE_XET=1`, uploads use official `CommitOperationAdd` operations through
`HfApi.create_commit(num_threads=max_workers, parent_commit=...)`; downloads use the
official HTTP path. This compatibility upload is a single commit and may hit
server limits for large selections; reduce the explicit selection or upgrade/use
Xet rather than falling back to the deprecated API. SDK retry, chunk
deduplication and already-committed-file skipping remain SDK responsibilities.
[Official upload API](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api).

Only recognizable **download** Xet transport failures get one automatic retry in a
fresh Python process with `HF_HUB_DISABLE_XET=1`, preserving the same approved SHA,
file list and cache. Authentication, authorization, missing repositories/files,
invalid paths and generic failures do not trigger that retry. **Uploads are never
blindly retried after a transport failure**: streamed batches might already have
committed. Inspect remote state, set `xet = "disabled"` if appropriate, then make
a new explicit request and approve a fresh manifest.

High-performance mode sets `HF_XET_HIGH_PERFORMANCE=1`; `xet_cache` sets
`HF_XET_CACHE`. Environment changes happen before the SDK import because the SDK
latches its environment configuration. An explicit inherited disable is respected.
Rose does not use legacy `HF_HUB_ENABLE_HF_TRANSFER`.
[Official environment variables](https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables).

### Papers

```lua
-- Hugging Face paper metadata, if the installed official SDK supports paper_info:
require("rose.hub").paper({ id = "2501.00001" }, function(err, metadata)
  if not err then vim.notify(vim.inspect(metadata)) end
end)

-- A paper file is an asset inside an existing model/dataset repository:
require("rose.hub").paper({
  action = "download",
  repo_id = "organization/existing-dataset",
  repo_type = "dataset",
  revision = "main",
  files = { "papers/paper.pdf", "papers/README.md", "papers/citation.bib" },
  destination = "papers/reference",
})

-- Upload local PDF/MD/BIB assets using the same trust/confirmation boundaries:
require("rose.hub").paper({
  action = "upload",
  repo_id = "my-account/existing-dataset",
  repo_type = "dataset",
  files = { "paper.pdf", "citation.bib" },
  path_in_repo = "papers",
})
```

`HfApi.paper_info(id=...)` accepts an arXiv ID and returns Hub paper metadata; an
unknown Hub paper can return 404 even when it exists elsewhere. Rose returns a
small metadata allowlist (ID, Hub URL, available title/summary/date/upvotes/authors)
and reports an upgrade-required error if this SDK method is missing.
[Official paper metadata API](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api#huggingface_hub.HfApi.paper_info).

`paper` is **not** an HF `repo_type`. Asset transfers accept only PDF, MD and BIB
filenames and require an existing model/dataset repo with those exact files.
Metadata lookup does not automatically locate or download related PDFs. Use the
repo's file browser to choose paths and then the asset API above. No public-arXiv
PDF fetching, arXiv submission/publishing or credentials forwarding to arXiv is
implemented.

## Credentials and filesystem boundaries

- Existing `HF_TOKEN` is inherited by the Python process, or the official SDK
  reads its own authentication cache when an explicit operation executes.
  Rose does not request credentials, read them at setup, accept tokens in specs,
  or put them in argv, JSON, progress or status. Configure authentication separately
  through Hugging Face's official tools.
  [Official authentication guide](https://huggingface.co/docs/huggingface_hub/quick-start#authentication).
- The official `https://huggingface.co` endpoint is forced before import and
  supplied to `HfApi`; an inherited `HF_ENDPOINT` cannot redirect credentials.
  Official SDK-managed Hub/CDN/Xet endpoints and redirects remain SDK territory.
  Enterprise/custom Hub origins are not supported by this module.
- Python runs with `-I`, an absolute plugin-owned script and `cwd="/"`: repository
  `huggingface_hub.py`, `sitecustomize.py`, `PYTHONPATH`, local scripts and model
  files are not executed. The configured Python executable and its installed
  dependencies are part of the trusted local installation.
- Explicit nonempty file lists only; no implicit whole cwd, globs, traversal,
  absolute paths, control characters, symlink components, hardlinked sources or
  special files. `.env*`, `.git/`, common credential directories, private-key
  names/extensions, service-account and secrets files are refused. This name-based
  guard is not a complete secret detector: inspect selected file contents yourself.
- Worker SDK exceptions and stderr may include signed URLs/authentication details.
  Raw stderr and exception text are not surfaced. Errors report actionable
  categories, not credential-bearing request dumps. Native Xet logs are directed
  to the OS null device before SDK import, overriding any inherited log destination;
  the literal string `stderr` is not used because Xet treats it as a filename.
- Secure descriptor-relative opens/copies and SHA snapshots guard normal
  workspace changes. A malicious same-user process controlling the configured
  Python installation/private cache or remote repository administrators is outside
  this local plugin's security boundary. Per-file local writes and multi-commit
  remote uploads are not rollback transactions.

## Native commands and cancellation

After explicit `hub.commands()` (or core opt-in command wiring):

| Command | Behavior |
| --- | --- |
| `:RoseHubDownload` | Native input for a JSON download spec, then full preview/approval |
| `:RoseHubUpload` | Native input for a JSON upload spec; trusted workspace required |
| `:RoseHubPaper` | Native input for metadata ID or paper-asset JSON spec |
| `:RoseHubStatus` | Native notification of status/progress |
| `:RoseHubStop` | Cancel the current metadata, preview, confirmation or transfer job |

Example input: `{"repo_id":"org/repo","repo_type":"dataset","files":["README.md"],"destination":"datasets/example","dry_run":true}`.

Cancellation sends SIGTERM, escalates to SIGKILL after 500 ms if needed, and
invalidates late UI callbacks. It never deletes remote data or clears official
cache/resume metadata. Already committed upload batches cannot be undone.

## Offline verification

From the plugin root:

```sh
python3 -m unittest discover -s tests -p test_hub.py -v
ROSE_TEST_PYTHON=/path/to/python nvim --headless -u NONE -l tests/hub.lua
```

Tests use tiny local assets, official-SDK-shaped mocks and a native subprocess
protocol fixture. A headless test runs the actual isolated Python helper against
a rejected traversal input. Coverage includes selection/credential guards,
symlink/hardlink escapes, changed-source/destination/remote state, cached/dry-run
previews, pinned downloads, bounded compatibility uploads, approval capability,
UI cancellation, process cancellation and selective fallback. Tests perform no
remote uploads, no model downloads and no remote code execution. SDK signature
compatibility was inspected locally with `huggingface_hub 1.30.0` / `hf_xet 1.6.0`;
this is **not** an end-to-end network throughput benchmark.
