# Session bootstrap prompts

`CLAUDE.md` already tells the agent the rules on every session — these are for when it is not installed yet, when you are on someone else's machine, or when you want the agent to *prove* the stack works before trusting it.

Language does not matter; paste them in whatever you normally write in.

---

## 1. Orientation — paste at the start of a session in a new repo

> This machine has two code-intelligence servers. Use them instead of grepping the tree or reading whole files.
>
> **The graph (`codebase-memory-mcp`) answers questions. Serena makes changes.**
>
> 1. Call `list_projects` first. If the repo I'm working in is not indexed, index it with `index_repository` before doing anything else.
> 2. For "where is X / who calls X / how is this built / what breaks if I change X" use `get_architecture`, `search_graph`, `trace_path`, `query_graph`, `semantic_query`, `get_code_snippet`. These are instant — do not fall back to Grep/Glob for structural questions.
> 3. Before you edit a symbol, get exact references with Serena's `find_referencing_symbols`. Make the edit with `replace_symbol_body` / `insert_after_symbol` / `rename_symbol` / `safe_delete_symbol`, then check `get_diagnostics_for_file`.
> 4. If the graph and the files disagree, the files win — re-index rather than trusting a stale answer.
>
> Start by giving me a short architecture summary of this repo **from the graph**, and tell me if anything above was unavailable.

That last sentence matters: it turns a silent missing-MCP into a visible report instead of the agent quietly grepping and pretending.

---

## 2. Health check — paste when something feels off

> Check my setup and report what is actually broken, not what should be there:
> - is the `codebase-memory-mcp` daemon active, and how many projects are indexed?
> - is `serena` connected?
> - does the claude-mem worker answer on `http://localhost:37777`?
> - does `~/.claude-mem-proxy/proxy.log` show recent `-> 200 [reasoning_effort=none]` lines?
>
> For anything failing, give me the cause and the fix — do not just restart things.

---

## 3. Onboarding a new machine

> Read the README in this repo and set up the whole stack on this machine, in the order given. Stop and tell me before doing anything that needs a paid key. When you are done, run the health check and show me the result.

---

## 4. Indexing a batch of repos

> Index every git repository under `<path>` into the code graph. Index each repo separately — do not index a parent folder that contains several of them, and skip empty stubs, archives, and folders that are only build output or datasets. Then show me the resulting project list with node and edge counts.
