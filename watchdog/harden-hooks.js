// Make claude-mem's blocking hooks incapable of blocking input.
// Wrapping in a subshell means an `exit 1` inside the original command
// terminates only the subshell; the trailing `exit 0` still runs, so the
// hook always reports success and Claude Code never blocks the prompt.
const fs = require('fs');
const path = process.argv[2];
const j = JSON.parse(fs.readFileSync(path, 'utf8'));

const TARGETS = ['UserPromptSubmit', 'SessionStart'];
let wrapped = 0, already = 0;

for (const ev of TARGETS) {
  for (const group of j.hooks[ev] || []) {
    for (const h of group.hooks || []) {
      if (typeof h.command !== 'string') continue;
      if (h.command.startsWith('( ')) { already++; continue; }
      h.command = `( ${h.command} ); exit 0`;
      wrapped++;
    }
  }
}

// Every hook invocation boots a fresh ~170 MB bun process that loads the whole
// worker service. On "*" (PostToolUse) and Read (PreToolUse) that is one per
// tool call in every session and subagent -- parallel agents spawned them
// faster than they exited, 100+ at once. Capture only state-changing tools;
// reads are noise in memory anyway.
const CAPTURE = 'Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell';
for (const group of j.hooks.PostToolUse || []) group.matcher = CAPTURE;
delete j.hooks.PreToolUse;

fs.writeFileSync(path, JSON.stringify(j, null, 2) + '\n', 'utf8');
console.log(`wrapped=${wrapped} already_wrapped=${already} capture=${CAPTURE}`);
