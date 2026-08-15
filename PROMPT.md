# Prompt playbook

The four everyday prompts live in the README, translated into every language: [English](README.md#prompts-to-paste) · [Русский](README.ru.md#промпты-для-вставки) · [中文](README.zh-CN.md#可直接粘贴的提示词) · [Español](README.es.md#prompts-para-pegar).

This file holds the longer ones. Copy the block, replace anything in `<angle brackets>`, paste. Language does not matter — write in whatever you normally use.

---

## Land in an unfamiliar codebase

```text
I've just been dropped into this repo and know nothing about it. Using the code graph — not by reading files —
give me:
1. what this service actually does, and its entry points (HTTP routes, CLI commands, jobs, main functions);
2. the 5-10 modules that matter most, judged by fan-in/fan-out rather than by folder names;
3. the parts that look risky: highest fan-out symbols, obvious dead code, anything with a suspicious name;
4. what I should read first if I have 20 minutes.
Cite qualified symbol names so I can jump to them. Say explicitly which claims came from the graph and which
are your inference.
```

## Plan a change before touching anything

```text
I want to change <describe the change>.
Before writing any code:
1. use the graph to find every place involved, and trace_path to show the call chains that reach them;
2. use Serena's find_referencing_symbols on each symbol you intend to modify — I want the exact reference
   list, not a guess;
3. tell me the blast radius: what breaks, what needs updating in lockstep, what is safe to leave alone;
4. only then propose a plan, smallest diff first.
Do not edit anything until I approve the plan.
```

## Safe refactor loop

```text
Refactor <symbol or module> to <goal>.
Work symbol by symbol: find_referencing_symbols first, edit with replace_symbol_body / rename_symbol /
safe_delete_symbol, then get_diagnostics_for_file on every file you touched before moving to the next symbol.
If diagnostics come back non-empty, fix them before continuing — do not batch up broken states.
When finished, re-index the repo so the graph matches reality, and summarise what changed.
```

## Review a diff with real context

```text
Review my current diff. For each changed symbol, use detect_changes and the graph to find its callers, and
tell me whether the change is safe for every one of them — not just the ones the diff touches.
Flag anything that changes a contract (signature, return shape, thrown errors, nullability) without updating
all call sites. Skip style opinions; I only want correctness and blast-radius findings.
```

## Find dead code honestly

```text
Find dead code in <project>. Use the graph for zero-in-degree symbols, but before reporting anything, verify
each candidate against the source: check for dynamic dispatch, reflection, string-based lookups, DI
registration, test-only usage, and public API surface that external consumers might import.
Report two separate lists: "confirmed unreachable" and "looks unused but I could not prove it", with the
reason for each in the second list. Do not delete anything.
```

## Cross-repo impact

```text
I'm about to change <symbol> in <repo A>. Several repos are indexed in the graph. Search all of them for
call sites, HTTP routes, queue names, env var names, or shared type shapes that would be affected —
cross-service links are exactly what the graph is for.
List the affected repos with concrete locations. If nothing outside <repo A> is affected, say so plainly
instead of padding the answer.
```

## Keep the graph honest

```text
Check whether the code graph still matches the working tree for this repo: compare list_projects / index_status
against the current branch and recent commits. If it is stale, re-index. If new repos appeared under <path>,
index each one separately.
Report what you re-indexed and the node/edge counts before and after.
```

## When you suspect the agent is bluffing

```text
For your last answer, tell me for each claim whether it came from the code graph, from Serena/LSP, from
actually reading the file, or from your own inference. For anything that was inference, either verify it with
a tool now or withdraw it.
```
