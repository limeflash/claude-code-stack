# Claude Code stack: memory + code intelligence

A reproducible setup of four tools that give Claude Code (and most other agent CLIs) **persistent memory across sessions** and **structural understanding of a codebase**, plus the global instruction file that stops them from fighting each other.

Everything here was installed and verified end-to-end on Windows 11 / PowerShell 5.1. The gotchas section is the part you actually want — each entry cost real debugging time.

## The stack

| Tool | What it gives you | Runs |
|---|---|---|
| [claude-mem](https://github.com/thedotmack/claude-mem) | Cross-session **conversational** memory. Auto-captures what happened and injects relevant past work at session start. | Local worker + SQLite + Chroma |
| [claude-mem-ollama-proxy](https://github.com/limeflash/claude-mem-ollama-proxy) | Points claude-mem's memory generation at **Ollama Cloud** instead of a paid provider, disables reasoning, and **redacts secrets** before anything leaves the machine. | Local proxy on `127.0.0.1:11435` |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Persistent **code knowledge graph** — functions, call chains, routes, cross-repo links. Answers architecture questions in milliseconds. | Native binary + daemon |
| [serena](https://github.com/oraios/serena) | Live **LSP** symbol navigation, precise references, and symbol-level *editing*. | Language servers per project |

The two code tools are **not** redundant — see [CLAUDE.md](CLAUDE.md) for the division of labor. Short version: **codebase-memory-mcp answers questions, Serena makes changes.**

## Why the split matters

Installing both without a rule makes the agent thrash: one system says "read the graph", the other says "use LSP". [CLAUDE.md](CLAUDE.md) is a drop-in `~/.claude/CLAUDE.md` that assigns each tool its job:

- **Recon, architecture, impact, cross-repo** → the graph. It is instant and already covers every indexed repo.
- **Exact references before an edit, the edit itself, type checking after** → Serena. It reads the current on-disk truth and can modify code.
- Files win over the graph when they disagree; re-index rather than trust a stale answer.

## Install (Windows)

Order matters: the proxy edits `~/.claude-mem/settings.json`, so claude-mem must exist first.

### 1. claude-mem

```powershell
npx claude-mem install
```

Pick **Worker** runtime. For the provider choose whichever you like — the proxy in step 2 overrides it to Ollama Cloud anyway, so the cheapest path is to pick an OpenAI-compatible option and paste an **Ollama** key (`https://ollama.com/settings/keys`).

> The installer may end with `Fatal error: ENOENT ... .install-version` and an npm `ERESOLVE` warning. **Both are harmless** — see gotchas.

### 2. Ollama proxy

```powershell
git clone https://github.com/limeflash/claude-mem-ollama-proxy.git
cd claude-mem-ollama-proxy
.\windows\install.ps1
```

Registers an at-logon Scheduled Task (no admin needed), points claude-mem at `http://127.0.0.1:11435/v1`, and defaults to `deepseek-v4-flash:0731`. Pick another model with `-Model "gpt-oss:120b"`; list them at `https://ollama.com/v1/models`.

The proxy injects `reasoning_effort: "none"` — without it a reasoning model puts its answer in `reasoning`, leaves `content` empty, and claude-mem silently stores nothing.

### 3. codebase-memory-mcp

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.ps1 -OutFile install.ps1
Unblock-File .\install.ps1
.\install.ps1
```

Native binary, **no API key and no runtime required** — semantic search uses embedded embeddings, and nothing leaves the machine. It auto-configures every agent CLI it detects.

Then index your repos and keep a daemon warm:

```powershell
codebase-memory-mcp daemon start
codebase-memory-mcp cli index_repository --repo-path C:\path\to\repo
codebase-memory-mcp cli list_projects
```

Index **each repo separately** rather than an umbrella folder — a parent directory full of `node_modules` and build output produces one useless blob instead of clean per-project graphs.

### 4. Serena

```powershell
uv tool install --from git+https://github.com/oraios/serena serena-agent
claude mcp add serena -s user -- serena start-mcp-server --context claude-code --project-from-cwd --enable-web-dashboard False
```

### 5. Global instructions

Copy [CLAUDE.md](CLAUDE.md) to `~/.claude/CLAUDE.md`. It is loaded into every session automatically, so the rules apply without you saying anything.

For a session that should orient itself out loud — or on a machine where `CLAUDE.md` is not installed — paste one of the ready-made prompts from [PROMPT.md](PROMPT.md).

## Verify

```powershell
# proxy alive and routing
Get-ScheduledTask -TaskName claude-mem-ollama-proxy
Get-Content "$env:USERPROFILE\.claude-mem-proxy\proxy.log" -Tail 5
# healthy line: POST /v1/chat/completions -> 200 [reasoning_effort=none]

# claude-mem worker
Invoke-WebRequest http://localhost:37777 -UseBasicParsing | Select-Object StatusCode

# graph
codebase-memory-mcp daemon status
codebase-memory-mcp cli list_projects
# UI: http://127.0.0.1:9749
```

In Claude Code, `/mcp` should list both `serena` and `codebase-memory-mcp`. **MCP servers only connect at startup — restart Claude Code after installing.**

## Gotchas

Every one of these was hit for real.

| Symptom | Cause | Fix |
|---|---|---|
| `npx claude-mem install` ends in `Fatal error: ENOENT ... marketplaces\thedotmack\plugin\.install-version` | Cosmetic path bug — the file is written one level up, at `marketplaces\thedotmack\.install-version` | Ignore. Verify the plugin cache has `node_modules` and the MCP responds. |
| Same install shows an npm `ERESOLVE` tree-sitter conflict | Redundant install of **dev-only** grammar deps; runtime deps already installed via `bun` | Ignore. |
| Memory generation costs a fortune | Default paths bill per observation (Haiku path ≈ $58/1k, OpenRouter ≈ $8/1k) | Use the Ollama proxy — generation moves to your Ollama Cloud balance. |
| claude-mem stores nothing, no visible error | Reasoning model returned text in `reasoning` with empty `content` | The proxy's `reasoning_effort: "none"` fixes it. |
| `codebase-memory-mcp` install exits 1, PATH never registered | One failing agent config aborts the whole activation. A **Hermes** config at `%LOCALAPPDATA%\hermes\config.yaml` fails deterministically, regardless of its contents ([issue #1656](https://github.com/DeusData/codebase-memory-mcp/issues/1656)) | Remove/rename the Hermes dir, or add the install dir to PATH by hand. The other agents configure fine. |
| `daemon status` says "not running" while the UI on :9749 answers | Multiple competing daemons, usually from repeated `install --force` | `daemon stop`, kill leftover `codebase-memory-mcp.exe`, `daemon start` once. |
| Graph answers look stale | `auto_watch=true` keeps **indexed** projects fresh, but `auto_index=false` — new repos are never picked up | Run `index_repository` once per new repo. |
| PowerShell 5.1: a script dies with "The property cannot be found on this object" | `$json.NewKey = value` throws on 5.1 for keys absent from a `ConvertFrom-Json` object | Use `Add-Member -NotePropertyName ... -Force`. |
| PowerShell: a path variable turns into something like `MSFT_TaskSettings3` | PowerShell variable names are **case-insensitive** — `$settings` silently clobbers `$Settings` | Rename one. |
| Native `.exe` output shows up as red `NativeCommandError` | PowerShell wraps a native program's stderr; the program did not fail | Check the exit code, not the color. |

## Costs

- **codebase-memory-mcp** and **Serena** — free, fully local, no API keys.
- **claude-mem** — bills per observation. With the proxy it draws on your Ollama Cloud balance instead of a per-token provider.

## Footprint

Worth knowing before installing on a small machine.

| | Disk | Memory |
|---|---|---|
| codebase-memory-mcp | 282 MB binary + graph cache (~450 MB for 19 repos / 111k nodes) | one daemon |
| Serena | small | ~1.6 GB with language servers across several open sessions |
| claude-mem | SQLite + Chroma, grows with use | worker + embedding stack |

## Privacy

- The graph and Serena are entirely local.
- claude-mem **does** send conversation content to a model. The proxy scans message bodies and replaces credentials with `[SECRET:{type}]` before forwarding — its log shows `[redacted: ...]` when it fires. Keep `CMP_REDACT` on.
