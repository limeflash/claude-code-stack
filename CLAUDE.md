# Global instructions

## Code navigation & editing — two systems, one split

Two code-intelligence servers are installed globally. They are not interchangeable: **cbm answers questions, Serena makes changes.** Prefer either over reading whole files or broad grepping.

### Recon, architecture, impact → `codebase-memory-mcp` (persistent graph, read-only, instant)
- `get_architecture` for the shape of a codebase; `search_graph` / `search_code` to locate things.
- `trace_path` for call chains, `detect_changes` to map a diff to affected symbols, `query_graph` (Cypher) and `semantic_query` for anything structural.
- `get_code_snippet` to read one symbol instead of opening the file.
- Reach for this first on an unfamiliar or large codebase, and for anything spanning multiple repos — the graph already covers the active projects.

### Precise references, edits, type checking → `serena` (live LSP)
- `find_symbol` / `get_symbols_overview` when you need the current on-disk truth rather than the index.
- `find_referencing_symbols` before changing a symbol — LSP-accurate, use this for the impact check that a refactor depends on.
- Edit at symbol level: `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rename_symbol`, `safe_delete_symbol`.
- `get_diagnostics_for_file` after non-trivial edits.
- Auto-activates the project from the working directory; call `activate_project` if none is active.

### Rules
- Graph first to find and understand, Serena to verify and change. Don't run both for the same lookup.
- The graph is kept fresh by a file watcher, but **new** projects are not auto-indexed — run `index_repository` once for a repo that isn't in `list_projects`.
- If the graph and the files disagree, the files win — re-index rather than trusting a stale answer.
- Don't use Serena's `write_memory` / `read_memory`; memory is handled elsewhere.
- Plain Read/Edit is still right for small files, config, and non-code text.
