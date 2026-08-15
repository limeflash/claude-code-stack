# Global instructions

## Code navigation & editing — two systems, one split

Two code-intelligence servers are installed globally. They are not interchangeable: **cbm answers questions, Serena makes changes.** Prefer either over reading whole files or broad grepping.

### Recon, architecture, impact → `codebase-memory-mcp` (persistent graph, read-only, instant)
- `get_architecture` for the shape of a codebase; `search_graph` to locate things — it has three independent modes in one call: `query=` (BM25 natural language), `name_pattern=`/`qn_pattern=` (regex), and `semantic_query=["a","b"]` (vector search, **an array parameter — there is no separate `semantic_query` tool**).
- `trace_path` for callers and call chains — the `in`/`out` degrees in `search_graph` rows are not caller counts.
- `query_graph` (Cypher) for multi-hop patterns, `get_code_snippet` to read one symbol instead of opening the file.
- `check_index_coverage` before any exhaustive or negative claim ("nothing else calls this"). Coverage is best-effort, never proof.
- The graph spans every indexed repo at once — use it for anything cross-repo.

### Precise references, edits, type checking → `serena` (live LSP)
- **Serena holds one project at a time.** It activates the session's working directory; if you touch a repo outside it, call `activate_project("<path>")` first. A wrong active project means the wrong language servers are running and symbol lookups fail with `Cannot extract symbols ... Active language servers: [...]` — that is a binding problem, not missing language support.
- `find_symbol` / `get_symbols_overview` when you need current on-disk truth rather than the index.
- `find_referencing_symbols` before changing a symbol — LSP-accurate, use this for the impact check a refactor depends on.
- Edit at symbol level: `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rename_symbol`, `safe_delete_symbol`; then `get_diagnostics_for_file`.

### Rules
- Graph first to find and understand, Serena to verify and change. Don't run both for the same lookup.
- Indexed projects auto-refresh via a file watcher, but only while the daemon is running. After a `git pull`, branch switch, rebase, or any period with the daemon down, re-index before trusting the graph. **New** projects are never picked up automatically — run `index_repository` once.
- If the graph and the files disagree, the files win — re-index rather than trusting a stale answer.
- Config files, build scripts and other ignored subtrees are excluded by design; `index_status` lists them. Use grep there.
- Don't use Serena's `write_memory` / `read_memory`; memory is handled elsewhere.
- Plain Read/Edit is still right for small files, config, and non-code text.
