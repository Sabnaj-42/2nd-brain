# Claude Code — Practical Guide

Written against **Claude Code v2.1.224** (verified with `claude --help` on this machine, cross-checked
against [https://code.claude.com/docs](https://code.claude.com/docs)). Flags change between versions — when in doubt,
`claude --help` on *your* build is the truth, not this file or the website.

**Your current setup** (`~/.claude/settings.json`):

```json
{
  "enabledPlugins": { "gopls-lsp@claude-plugins-official": true },
  "theme": "dark",
  "model": "opus[1m]"
}
```

You have no `CLAUDE.md` anywhere yet. That's the single highest-value thing to fix — see §9.

---

## Table of contents

1. [Mental model](#1-mental-model)
2. [The two ways to run it](#2-the-two-ways-to-run-it)
3. [Sessions: continue, resume, fork](#3-sessions-continue-resume-fork)
4. [Model and effort](#4-model-and-effort)
5. [Permissions — the part that matters most](#5-permissions--the-part-that-matters-most)
6. [Restricting tools](#6-restricting-tools)
7. [Context: directories and compaction](#7-context-directories-and-compaction)
8. [System prompt flags](#8-system-prompt-flags)
9. [CLAUDE.md and memory](#9-claudemd-and-memory)
10. [Print mode / scripting](#10-print-mode--scripting)
11. [Background agents, cloud, worktrees](#11-background-agents-cloud-worktrees)
12. [settings.json reference](#12-settingsjson-reference)
13. [Hooks](#13-hooks)
14. [Skills (custom slash commands)](#14-skills-custom-slash-commands)
15. [Subagents](#15-subagents)
16. [MCP servers](#16-mcp-servers)
17. [Plugins](#17-plugins)
18. [Slash command reference](#18-slash-command-reference)
19. [Keyboard shortcuts](#19-keyboard-shortcuts)
20. [Troubleshooting](#20-troubleshooting)
21. [Lab track](#21-lab-track)
22. [Cheat sheet](#22-cheat-sheet)

---

## 1. Mental model

Claude Code is an **agent with tools**, not a chatbot. It reads files, runs shell commands, edits
code, and calls out to MCP servers. Three consequences shape everything else:

1. **Permissions are the safety layer.** The model decides what it *wants* to do; the permission
   system decides what it's *allowed* to do. Learn §5 before anything else.
2. **Context is finite and costs money.** Everything loaded — CLAUDE.md, file reads, tool output —
   competes for the same window. `/context` shows the breakdown.
3. **Configuration is layered.** Managed → CLI flags → local → project → user. Higher layers win,
   except permissions, which *merge*.

### Where things live

```
~/.claude/
├── settings.json            # your global settings
├── CLAUDE.md                # your global instructions (you don't have one yet)
├── skills/                  # your personal slash commands
├── agents/                  # your personal subagents
├── rules/                   # personal path-scoped rules
├── plugins/                 # installed plugins
├── projects/<project>/
│   └── memory/              # auto-memory Claude writes itself
└── plans/                   # saved plan-mode plans

<repo>/
├── CLAUDE.md                # team instructions (committed)
├── CLAUDE.local.md          # your private project notes (gitignore this)
└── .claude/
    ├── settings.json        # team settings (committed)
    ├── settings.local.json  # your private settings (auto-gitignored)
    ├── skills/              # project slash commands
    ├── agents/              # project subagents
    ├── rules/               # path-scoped rules
    └── hooks/               # hook scripts
~/.claude.json               # user-scope MCP servers
<repo>/.mcp.json             # project MCP servers (committed)
```

---

## 2. The two ways to run it

### Interactive (default)

```bash
claude                                  # start a session
claude "explain the TLS flow in this repo"   # start with an opening prompt
```

### Print mode (`-p` / `--print`) — non-interactive, for pipes and scripts

```bash
claude -p "list the exported functions in this package"
cat build.log | claude -p "why did this fail?"
git diff | claude -p "write a commit message"
```

> **Security note from the docs:** the workspace trust dialog is *skipped* in print mode (and any
> time stdout isn't a TTY). Only use `-p` in directories you trust. Malformed settings files are
> also silently ignored rather than erroring.

**Lab 2.1** — try both, and notice the difference:

```bash
cd /tmp && mkdir -p cc-lab && cd cc-lab
echo 'package main
func Add(a, b int) int { return a - b }' > buggy.go

claude -p "Is there a bug in buggy.go? Answer in one sentence."
```

Then run plain `claude` in the same directory and ask the same thing. Print mode gives you one
answer and exits; interactive keeps the conversation.

---

## 3. Sessions: continue, resume, fork

| Flag                           | Meaning                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `-c`, `--continue`         | Continue the most recent conversation**in this directory**                  |
| `-r`, `--resume [id\|name]` | Resume a specific session; no argument opens a picker                             |
| `--fork-session`             | With`-r`/`-c`: branch to a *new* session ID instead of overwriting          |
| `--session-id <uuid>`        | Force a specific session UUID (must be a valid UUID)                              |
| `-n`, `--name <name>`      | Give the session a display name (shows in prompt box,`/resume`, terminal title) |
| `--no-session-persistence`   | Don't write the session to disk (print mode only)                                 |
| `--from-pr [n]`              | Resume the session linked to a PR                                                 |

```bash
claude -n "documentdb-tls"          # named session
claude -c                            # pick up where you left off
claude -c -p "now run the tests"     # continue, one-shot, non-interactive
claude -r "documentdb-tls" "finish the vendor sync"
claude -r abc123 --fork-session      # explore a different direction, keep the original intact
```

`--fork-session` is the one people miss. Use it when you want to try a risky direction without
polluting a session you might want to go back to.

**Lab 3.1**

```bash
cd /tmp/cc-lab
claude -n "lab-session" -p "Remember the number 42."
claude -c -p "What number did I ask you to remember?"
```

The second command should answer 42 — proof the context carried. Now try it from a *different*
directory: `-c` is directory-scoped, so it won't find that session.

---

## 4. Model and effort

```bash
claude --model sonnet                # alias: fable | opus | sonnet | haiku
claude --model claude-opus-5         # or a full model ID
claude --model 'opus[1m]'            # 1M-token context variant (your current default)
claude --fallback-model sonnet,haiku # fall back when primary is overloaded (print mode only)
claude --effort high                 # low | medium | high | xhigh | max
```

**Effort** controls how much reasoning the model spends. Higher effort = better on hard problems,
slower and pricier. Roughly:

- `low` / `medium` — mechanical edits, formatting, simple lookups
- `high` — default for real engineering work
- `xhigh` / `max` — architecture decisions, subtle bugs, big refactors

Mid-session: `/model` and `/effort`. Toggle fast mode with `/fast` or `Alt+O`.

`--fallback-model` accepts a comma-separated list and re-tries the primary at the start of each
user turn. It only works with `--print`.

---

## 5. Permissions — the part that matters most

### Permission modes

Cycle live with **`Shift+Tab`**, or set at launch with `--permission-mode`:

| Mode                            | Behavior                                                                    |
| ------------------------------- | --------------------------------------------------------------------------- |
| `manual` (shown as "default") | Ask before every non-allowlisted action                                     |
| `acceptEdits`                 | Auto-accept file edits; still ask for Bash etc.                             |
| `plan`                        | **Read-only.** Claude investigates and writes a plan, changes nothing |
| `auto`                        | A classifier auto-approves safe things, asks about risky ones               |
| `dontAsk`                     | Don't prompt; skip actions that would need approval                         |
| `bypassPermissions`           | **No checks at all.** Sandboxes only                                  |

```bash
claude --permission-mode plan "how should we restructure the auth package?"
claude --permission-mode acceptEdits "fix all the lint errors"
```

**Plan mode is the highest-leverage habit in this whole document.** For anything non-trivial, start
in plan mode, read the plan, approve it, *then* let it edit. You catch wrong approaches before they
become wrong code.

### The two dangerous flags — know the difference

```bash
--dangerously-skip-permissions        # STARTS in bypass mode. No checks, immediately.
--allow-dangerously-skip-permissions  # Only ADDS bypass to the Shift+Tab cycle. Safer.
```

The second just makes the mode *available*; you still have to opt in. Anthropic's guidance:
sandboxes with no internet access only. On a machine with your SSH keys and cloud credentials —
which yours is — don't.

### Allow/deny lists

```bash
claude --allowedTools "Read" "Bash(git log *)" "Bash(git diff *)"
claude --disallowedTools "Bash(git push *)" "Write"
```

Pattern syntax:

| Pattern                | Matches                        |
| ---------------------- | ------------------------------ |
| `Bash(npm run lint)` | that exact command             |
| `Bash(git log *)`    | `git log` with any arguments |
| `Read(./.env)`       | one specific file              |
| `Read(./secrets/**)` | everything under`secrets/`   |
| `Edit(./src/**)`     | edits under`src/`            |

Persist them in `settings.json` (§12) rather than retyping flags. Note **permissions merge across
config layers** instead of overriding — a `deny` in your user settings still applies when a project
adds its own allows.

**Lab 5.1 — see plan mode refuse to write**

```bash
cd /tmp/cc-lab
claude --permission-mode plan -p "Create a file called proof.txt containing the word hello"
ls proof.txt        # No such file — plan mode is genuinely read-only
```

**Lab 5.2 — see a deny rule bite**

```bash
cd /tmp/cc-lab
claude --disallowedTools "Bash(rm *)" -p "Delete buggy.go using rm"
ls buggy.go         # still there
```

---

## 6. Restricting tools

```bash
claude --tools "Read,Grep,Glob"    # only these built-ins
claude --tools ""                  # no tools at all — pure chat
claude --tools default             # everything (the default)
```

`--tools` controls which tools *exist*. `--allowedTools` controls which are *pre-approved*.
Different axes: use `--tools` to make a capability unavailable, `--allowedTools` to skip prompting
for it.

```bash
# A read-only reviewer that literally cannot edit:
claude --tools "Read,Grep,Glob,Bash" --disallowedTools "Bash(rm *)" "Bash(git push *)" \
  -p "Review this package for bugs"
```

---

## 7. Context: directories and compaction

```bash
claude --add-dir ../apimachinery ../documentdb   # grant access outside cwd
claude --autocompact 500k                        # compact at 500k tokens
claude --autocompact auto                        # let Claude Code decide
```

`--add-dir` is essential for your Go layout, where `kubedb.dev/apimachinery` and
`kubedb.dev/documentdb` are siblings you routinely edit together:

```bash
cd ~/go/src/kubedb.dev/apimachinery
claude --add-dir ../documentdb "flatten the TLS field and update both repos"
```

By default `CLAUDE.md` files in added directories are **not** loaded. To load them:

```bash
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir ../documentdb
```

Useful in-session: `/context` (usage grid), `/compact [instructions]` (summarize now),
`/clear` (fresh start).

---

## 8. System prompt flags

| Flag                                   | Effect                                                  |
| -------------------------------------- | ------------------------------------------------------- |
| `--append-system-prompt <text>`      | Add to the default system prompt                        |
| `--append-system-prompt-file <path>` | Same, from a file*(hidden from `--help`, works)*    |
| `--system-prompt <text>`             | **Replace** the entire system prompt              |
| `--system-prompt-file <path>`        | Replace, from a file*(hidden from `--help`, works)* |

```bash
claude --append-system-prompt "Always run 'make fmt' after editing Go files."
claude --system-prompt "You are a terse Go code reviewer. Output only bullet points."
```

`--system-prompt` throws away Claude Code's built-in agent instructions — tool-use conventions,
safety guidance, all of it. Use `--append-` unless you specifically want a bare model.

> These are system-prompt-level, so they're followed more reliably than CLAUDE.md. But they must be
> passed on every invocation, which makes them better for scripts than for daily interactive use.

---

## 9. CLAUDE.md and memory

Two systems, both loaded every session:

|            | CLAUDE.md                    | Auto memory                              |
| ---------- | ---------------------------- | ---------------------------------------- |
| Written by | You                          | Claude                                   |
| Contains   | Rules, conventions, commands | Learnings it picks up                    |
| Location   | Repo /`~/.claude/`         | `~/.claude/projects/<project>/memory/` |

### Load order (broad → specific; later wins on conflict)

1. Managed policy: `/etc/claude-code/CLAUDE.md`
2. User: `~/.claude/CLAUDE.md`
3. Project: `./CLAUDE.md` or `./.claude/CLAUDE.md`
4. Local: `./CLAUDE.local.md` (gitignore it)

Files up the directory tree load at launch; files in subdirectories load on demand when Claude
reads files there.

### Writing one that actually works

- **Under 200 lines.** Longer files reduce adherence and eat context.
- **Specific and verifiable.** "Use 2-space indentation" ≫ "format code properly."
- **No contradictions.** Conflicting rules make Claude pick arbitrarily.
- **Facts, not procedures.** Multi-step procedures belong in a skill (§14).

`/init` generates a starting file by analyzing the codebase.

A realistic one for your apimachinery repo:

```markdown
# kubedb.dev/apimachinery

## Codegen
- After editing anything under `apis/`, run `make gen && make fmt`.
- `make gen` alone leaves ~940 files changed by import regrouping; `make fmt` collapses it back.
  Don't panic at the intermediate `git diff --stat`.
- CRDs use `maxDescLen=0`, so doc-comment edits change `openapi_generated.go` but not CRD YAML.

## Conventions
- DB types live in `apis/kubedb/v1alpha2/`, ops types in `apis/ops/v1alpha1/`.
- TLS wrappers embed `kmapi.TLSConfig` with `json:",inline"` — never as a named field.
- Helper methods go in `<db>_helpers.go`, not `<db>_types.go`.

## Gotchas
- `apis/gitops/v1alpha1` embeds `DocumentDBSpec` directly, so DB spec changes propagate with no
  Go edits but do regenerate `crds/gitops.kubedb.com_*.yaml`.
```

### Imports

```markdown
See @README.md for the overview.
- git workflow @docs/git-instructions.md
- personal prefs @~/.claude/my-project-instructions.md
```

Max 4 hops deep. Imports inside backticks are *not* followed — write `` `@README` `` to mention a
path literally. Imports resolving outside the working directory trigger a one-time approval dialog.

### Path-scoped rules

For instructions that only matter in part of the tree, `.claude/rules/*.md` with `paths`
frontmatter loads them only when relevant:

```markdown
---
paths:
  - "apis/**/*_types.go"
---
# API type rules
- Every new field needs `// +optional` unless required.
- Regenerate with `make gen && make fmt` before committing.
```

### Auto memory

On by default. Claude writes to `~/.claude/projects/<project>/memory/`. Only the first **200 lines
or 25KB** of `MEMORY.md` loads per session; topic files load on demand. Browse it with `/memory`.
Disable per-project with `{"autoMemoryEnabled": false}` or globally via
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`.

**Lab 9.1**

```bash
cd /tmp/cc-lab
cat > CLAUDE.md <<'EOF'
# Lab project
- Always respond with a 🦫 emoji at the start of your first sentence.
- This project uses tabs, never spaces.
EOF
claude -p "What indentation does this project use?"
```

The answer should mention tabs *and* start with 🦫 — that's CLAUDE.md loading. Run `/context` in an
interactive session to see it listed under **Memory files**.

---

## 10. Print mode / scripting

### Output formats

```bash
claude -p "query" --output-format text          # default
claude -p "query" --output-format json          # single JSON result w/ cost + session id
claude -p "query" --output-format stream-json   # newline-delimited events, realtime
```

### Structured output

```bash
claude -p "Extract the Go module path and version from go.mod" \
  --json-schema '{
    "type":"object",
    "properties":{"module":{"type":"string"},"go":{"type":"string"}},
    "required":["module","go"]
  }'
```

Validated against your schema — the reason to prefer this over "please reply in JSON."

### Budget and turn limits

```bash
claude -p --max-budget-usd 2.00 "refactor this package"
claude -p --max-turns 3 "fix the failing test"     # hidden from --help, works
```

`--max-turns` caps agentic loops — good insurance in CI against runaway spend.

### Streaming input

```bash
claude -p --input-format stream-json --output-format stream-json --replay-user-messages
```

### Other print-mode flags

| Flag                                         | Purpose                                                          |
| -------------------------------------------- | ---------------------------------------------------------------- |
| `--include-partial-messages`               | Emit token-level chunks (needs`stream-json`)                   |
| `--include-hook-events`                    | Emit hook lifecycle events                                       |
| `--forward-subagent-text`                  | Surface subagent text/thinking                                   |
| `--prompt-suggestions`                     | Emit a predicted next prompt each turn                           |
| `--permission-prompt-tool <mcp_tool>`      | Delegate permission decisions to an MCP tool*(hidden, works)*  |
| `--exclude-dynamic-system-prompt-sections` | Move cwd/env/git out of the system prompt for better cache reuse |

**Lab 10.1 — a commit-message generator**

```bash
cd ~/go/src/kubedb.dev/apimachinery
git diff | claude -p --max-turns 1 \
  "Write a conventional-commit message for this diff. Subject line only, under 72 chars."
```

**Lab 10.2 — machine-readable output**

```bash
cd /tmp/cc-lab
claude -p "How many .go files are here?" --output-format json | jq '{result, total_cost_usd}'
```

---

## 11. Background agents, cloud, worktrees

### Background

```bash
claude --bg "investigate why TestReconcile is flaky"
claude agents            # interactive dashboard
claude agents --json     # scriptable list
claude logs <id>         # tail output
claude attach <id>       # bring into this terminal
claude stop <id>
claude respawn <id>      # restart with conversation intact
```

### Worktrees

```bash
claude -w feature-tls          # new git worktree + session
claude -w feature-tls --tmux   # ...plus a tmux session
```

Genuinely useful for your workflow: an isolated worktree means an agent can't disturb your dirty
working tree while you keep working.

### Cloud / remote

```bash
claude --cloud "Fix the login bug"      # runs on claude.ai infra
claude --teleport                       # pull a web session into this terminal
claude --remote-control                 # drive this session from another device
```

---

## 12. settings.json reference

### Precedence (1 = highest)

1. Managed — `/etc/claude-code/managed-settings.json`
2. CLI flags
3. `.claude/settings.local.json` (gitignored)
4. `.claude/settings.json` (committed)
5. `~/.claude/settings.json`

Permissions **merge** across layers instead of overriding.

### A realistic config for your Go work

`~/.claude/settings.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "theme": "dark",
  "model": "opus[1m]",
  "effortLevel": "high",
  "enabledPlugins": { "gopls-lsp@claude-plugins-official": true },
  "permissions": {
    "allow": [
      "Bash(go build *)",
      "Bash(go vet *)",
      "Bash(go test *)",
      "Bash(gofmt *)",
      "Bash(git status)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Read(~/go/src/**)"
    ],
    "deny": [
      "Read(./.env)",
      "Read(./secrets/**)",
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Bash(git push *)",
      "Bash(rm -rf *)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(make gen)"
    ]
  }
}
```

That allowlist alone removes most of your daily permission prompts. `/fewer-permission-prompts`
generates one automatically by scanning your transcripts.

### Keys worth knowing

| Key                                            | Purpose                                                   |
| ---------------------------------------------- | --------------------------------------------------------- |
| `model`, `effortLevel`, `fallbackModel`  | Defaults for every session                                |
| `alwaysThinkingEnabled`                      | Extended thinking by default                              |
| `autoCompactEnabled`, `autoCompactWindow`  | Compaction behavior                                       |
| `cleanupPeriodDays`                          | Delete session files older than N days (default 30)       |
| `autoMemoryEnabled`, `autoMemoryDirectory` | Auto-memory control                                       |
| `claudeMdExcludes`                           | Glob-skip irrelevant CLAUDE.md files (monorepo lifesaver) |
| `editorMode`                                 | `"vim"` or `"normal"`                                 |
| `env`                                        | Env vars for every session                                |
| `attribution`                                | Customize commit/PR attribution                           |
| `disableAllHooks`                            | Kill switch for hooks                                     |
| `tui`                                        | `"fullscreen"` or `"stream"`                          |

### Environment variables

| Variable                                         | Effect                                |
| ------------------------------------------------ | ------------------------------------- |
| `CLAUDE_CODE_EFFORT_LEVEL`                     | Effort for the session                |
| `MAX_THINKING_TOKENS`                          | Cap thinking tokens (`0` disables)  |
| `DISABLE_AUTO_COMPACT`                         | Turn off auto-compaction              |
| `DISABLE_AUTOUPDATER`                          | Turn off auto-updates                 |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY`              | Disable auto memory                   |
| `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` | Load CLAUDE.md from`--add-dir` dirs |
| `CLAUDE_CODE_SKIP_PROMPT_HISTORY`              | Don't write transcripts               |

Check what actually loaded with `/status`.

---

## 13. Hooks

Shell commands fired at lifecycle events. **Hooks are enforcement; CLAUDE.md is suggestion.** If
something must happen every time, it's a hook.

### Events

**Per-session:** `SessionStart`, `SessionEnd`, `Setup`
**Per-turn:** `UserPromptSubmit`, `UserPromptExpansion`, `Stop`, `StopFailure`
**Tools:** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `PermissionDenied`
**Subagents:** `SubagentStart`, `SubagentStop`
**Files:** `FileChanged`, `CwdChanged`, `DirectoryAdded`, `WorktreeCreate`, `WorktreeRemove`
**Config:** `ConfigChange`, `InstructionsLoaded`, `PreCompact`, `PostCompact`
**Other:** `Notification`, `MessageDisplay`, `TaskCreated`, `TaskCompleted`, `Elicitation`

### Exit codes (command hooks)

- `0` — proceed; stdout JSON is parsed
- `2` — **blocking**; stderr goes to Claude
- anything else — non-blocking error, proceeds

### Matchers

`"*"` all · `"Bash"` exact · `"Bash|Edit|Write"` alternation · `"^Edit$"` anchored regex ·
`"mcp__.*__write.*"` regex for MCP tools

### Auto-format Go after every edit

`.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/gofmt.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

`.claude/hooks/gofmt.sh`:

```bash
#!/usr/bin/env bash
# stdin is the hook JSON payload
file=$(jq -r '.tool_input.file_path // empty')
[[ "$file" == *.go ]] || exit 0
gofmt -w "$file"
echo "{\"systemMessage\": \"gofmt applied to $file\"}"
```

```bash
chmod +x .claude/hooks/gofmt.sh
```

### Block edits to generated files

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": ".claude/hooks/protect-generated.sh" }]
      }
    ]
  }
}
```

```bash
#!/usr/bin/env bash
file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  *zz_generated*|*openapi_generated*)
    echo "Refusing: $file is generated. Edit the source type and run 'make gen'." >&2
    exit 2 ;;   # exit 2 blocks the tool call
esac
exit 0
```

That would have caught the hand-edited deepcopy in your recent TLS work.

### Inject git context at session start

```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "echo \"{\\\"hookSpecificOutput\\\":{\\\"hookEventName\\\":\\\"SessionStart\\\",\\\"additionalContext\\\":\\\"Branch: $(git branch --show-current)\\\"}}\""
      }]
    }]
  }
}
```

Hook types beyond `command`: `http`, `prompt` (ask a fast model), `mcp_tool`.

Inspect with `/hooks`. Kill all with `"disableAllHooks": true` or `--safe-mode`.

**Lab 13.1**

```bash
cd /tmp/cc-lab && mkdir -p .claude
cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "echo 'BASH ATTEMPTED' >> /tmp/cc-lab/audit.log" }]
    }]
  }
}
EOF
claude -p "run 'echo hello' in the shell"
cat /tmp/cc-lab/audit.log
```

---

## 14. Skills (custom slash commands)

A skill is a reusable prompt/procedure. Its body loads **only when used**, so unlike CLAUDE.md,
long reference material costs nothing until needed.

> Custom commands merged into skills. `.claude/commands/deploy.md` and
> `.claude/skills/deploy/SKILL.md` both create `/deploy`. Old `commands/` files still work.

### Create one

```bash
mkdir -p .claude/skills/regen
cat > .claude/skills/regen/SKILL.md <<'EOF'
---
name: regen
description: Regenerate apimachinery codegen and verify the diff is clean.
---

# Regenerate codegen

1. Run `make gen && make fmt` (it takes several minutes — run in background and wait).
2. Run `git diff --stat`. Expect changes only in files related to the types I edited.
   If ~900 files changed, `make fmt` did not run — run it.
3. Run `go build ./apis/... ./pkg/...` and report failures.
4. Summarize the diff in three bullets.
EOF
```

Now `/regen` runs it.

### Arguments

```markdown
---
name: fixbug
description: Investigate and fix a bug given an issue number.
---
Investigate issue #$1 in repo $2. All args: $ARGUMENTS
```

`/fixbug 123 kubedb/apimachinery` → `$1`=123, `$2`=kubedb/apimachinery.

### Embedding shell output and files

Inside a SKILL.md body:

- ``!`git status --short` `` — runs the command, embeds output
- `@path/to/file` — inlines the file

Disable with `disableSkillShellExecution`.

### Frontmatter

| Field                        | Purpose                                 |
| ---------------------------- | --------------------------------------- |
| `name`                     | The`/name` invocation                 |
| `description`              | How Claude decides relevance            |
| `allowed-tools`            | Restrict tools for this skill           |
| `model`                    | Force a model                           |
| `disable-model-invocation` | Only*you* can invoke it, never Claude |

Scaffold with `claude plugin init <name>`.

---

## 15. Subagents

Separate agents with their own context window and tools. Use them to keep noisy exploration out of
your main context.

`.claude/agents/go-reviewer.md`:

```markdown
---
name: go-reviewer
description: Reviews Go diffs for correctness bugs. Use after implementing a change.
tools: Read, Grep, Glob, Bash
model: opus
---

You review Go code for correctness only — not style.

Focus on: nil-pointer paths, error handling, goroutine leaks, incorrect struct embedding,
missing deepcopy for new pointer fields.

Report findings as `file:line — problem — concrete failure scenario`. Say "no issues found"
rather than inventing problems.
```

Then: *"use the go-reviewer subagent on my staged changes"*, or `/subtask`.

Built-ins include `Explore` (fan-out search), `Plan` (architecture), `general-purpose`.

`Ctrl+X Ctrl+K` stops all background subagents.

---

## 16. MCP servers

MCP connects Claude Code to external systems (GitHub, Sentry, databases, browsers).

```bash
# HTTP server
claude mcp add --transport http sentry https://mcp.sentry.dev/mcp

# with auth header
claude mcp add --transport http corridor https://app.corridor.dev/api/mcp \
  --header "Authorization: Bearer $TOKEN"

# stdio server with env
claude mcp add my-server -e API_KEY=xxx -- npx my-mcp-server

claude mcp list
claude mcp get sentry
claude mcp login sentry      # OAuth flow
claude mcp remove sentry
```

Scopes: `~/.claude.json` (user) · `.mcp.json` (project, committed) · `--mcp-config` (session).

```bash
claude --mcp-config ./mcp.json --strict-mcp-config   # ignore all other MCP config
```

Project `.mcp.json` servers need approval before connecting — unapproved ones show as
⏸ Pending. Control centrally with `enabledMcpjsonServers` / `disabledMcpjsonServers` /
`enableAllProjectMcpServers`.

MCP tools are named `mcp__<server>__<tool>`, so they work in permission rules and hook matchers:

```json
{ "permissions": { "deny": ["mcp__github__create_pull_request"] } }
```

---

## 17. Plugins

```bash
claude plugin list
claude plugin install code-review@claude-plugins-official
claude plugin details gopls-lsp        # component inventory + token cost
claude plugin disable <name>
claude plugin update <name>
claude plugin marketplace              # manage sources
claude plugin init my-plugin           # scaffold at ~/.claude/skills/
claude plugin validate ./my-plugin
```

Session-only, no install:

```bash
claude --plugin-dir ./my-plugin
claude --plugin-url https://example.com/plugin.zip
```

You already run `gopls-lsp` — that's what gives Claude Go language-server diagnostics (the
`MissingFieldOrMethod` errors you see appear mid-session come from it).

`claude plugin details <name>` is worth running occasionally: plugins consume context.

---

## 18. Slash command reference

### Session

`/clear` (`/reset`, `/new`) · `/compact [instructions]` · `/context [all]` · `/resume` ·
`/rewind` · `/branch [name]` · `/fork [prompt]` · `/export [file]` · `/copy [N]` · `/exit`

### Mode & model

`/model [name]` · `/effort [level|auto]` · `/fast [on|off]` · `/plan` · `/permissions` ·
`/config` (`/settings`) · `/status` · `/usage` (`/cost`)

### Code work

`/code-review [low|medium|high|xhigh|max|ultra] [--fix] [--comment] [pr#|branch|path]` ·
`/security-review` · `/simplify` · `/verify` · `/diff` · `/init` · `/batch <instruction>`

### Memory & config

`/memory` · `/hooks` · `/agents` · `/mcp` · `/add-dir <path>` · `/cd <path>` · `/keybindings`

### Delegation

`/subtask [prompt]` · `/tasks` · `/background` (`/bg`) · `/loop [interval] [prompt]` ·
`/deep-research <question>`

### Help & meta

`/help` · `/doctor` (`/checkup`) · `/debug` · `/bug` (`/share`) · `/insights` ·
`/fewer-permission-prompts` · `/btw [question]` · `/goal [condition|clear]`

Commands only register at the **start** of a message. Availability varies by plan and platform.

Two worth adopting immediately:

- **`/code-review`** before every PR. `ultra` runs a multi-agent cloud review (billed, user-triggered).
- **`/fewer-permission-prompts`** once, early — it writes an allowlist from your real usage.

---

## 19. Keyboard shortcuts

### General

| Key                             | Action                                                     |
| ------------------------------- | ---------------------------------------------------------- |
| `Shift+Tab`                   | **Cycle permission modes** — the one to memorize    |
| `Esc`                         | Interrupt Claude mid-turn (keeps work done so far)         |
| `Esc` `Esc`                 | Clear draft; on empty input, open the**rewind** menu |
| `Ctrl+C`                      | Interrupt; twice on empty input exits                      |
| `Ctrl+D`                      | Exit (press twice within 800ms)                            |
| `Ctrl+O`                      | Toggle transcript viewer (full tool detail)                |
| `Ctrl+R`                      | Reverse-search command history                             |
| `Ctrl+L`                      | Redraw screen; twice in fullscreen =`/clear`             |
| `Ctrl+B`                      | Background the running task                                |
| `Ctrl+T`                      | Toggle Claude's to-do checklist                            |
| `Ctrl+S`                      | Stash / restore the prompt                                 |
| `Ctrl+G` or `Ctrl+X Ctrl+E` | Edit prompt in`$EDITOR`                                  |
| `Ctrl+Z`                      | Suspend to shell (`fg` to resume)                        |
| `Ctrl+X Ctrl+K`               | Stop all background subagents (twice to confirm)           |
| `Alt+P`                       | Switch model without losing your prompt                    |
| `Alt+T`                       | Toggle extended thinking                                   |
| `Alt+O`                       | Toggle fast mode                                           |
| `?` on empty input            | Shortcut help panel                                        |

### Input prefixes

| Prefix | Effect                                                           |
| ------ | ---------------------------------------------------------------- |
| `/`  | Slash command / skill                                            |
| `!`  | **Shell mode** — run a command, output enters the session |
| `@`  | File path autocomplete                                           |
| `:`  | Emoji shortcode (v2.1.217+)                                      |

The `!` prefix is underused. When Claude needs the result of something interactive
(`gcloud auth login`, a REPL), type `! <command>` and the output lands directly in context.

### Multiline

`\` + `Enter` (universal) · `Ctrl+J` (universal) · `Shift+Enter` (native in iTerm2, WezTerm,
Ghostty, Kitty, Warp, Windows Terminal; run `/terminal-setup` for VS Code/Zed/Alacritty)

### Text editing

`Ctrl+A`/`Ctrl+E` line start/end · `Ctrl+K` kill to EOL · `Ctrl+U` kill to start ·
`Ctrl+W` kill word · `Ctrl+Y` yank · `Alt+B`/`Alt+F` word motion · `Ctrl+_` undo

Vim bindings: `"editorMode": "vim"`.

---

## 20. Troubleshooting

```bash
claude doctor                   # installation + settings diagnostics
claude --safe-mode              # disable ALL customization (hooks, plugins, MCP, CLAUDE.md)
claude --bare                   # minimal: skip hooks, LSP, plugins, auto-memory, CLAUDE.md
claude --debug                  # verbose
claude --debug 'mcp,startup'    # filter categories
claude --debug '!1p,!file'      # exclude categories
claude --debug-file /tmp/cc.log
```

**Config broken?** `--safe-mode` first. If the problem vanishes, it's your customization; bisect by
re-enabling. Managed policy settings still apply in safe mode.

**Instructions ignored?** `/context` → check **Memory files**. Not listed = not loaded. If it must
happen every time, make it a hook, not a CLAUDE.md line.

**Too many permission prompts?** `/fewer-permission-prompts`, then commit the allowlist.

**Context filling fast?** `/context` to see what's eating it. Trim CLAUDE.md, move detail to
path-scoped rules or skills, use subagents for noisy exploration.

**Session state cleanup:**

```bash
claude project purge ~/work/repo --dry-run
```

---

## 21. Lab track

A progressive set. ~45 minutes total.

### Lab A — Safe sandbox (5 min)

```bash
mkdir -p /tmp/cc-lab && cd /tmp/cc-lab && git init -q
cat > main.go <<'EOF'
package main

import "fmt"

func Divide(a, b int) int {
	return a / b
}

func main() {
	fmt.Println(Divide(10, 0))
}
EOF
git add -A && git commit -qm "initial"
```

### Lab B — Plan mode discipline (5 min)

```bash
claude --permission-mode plan "This code has a bug. Plan a fix with a table-driven test."
```

Read the plan. Approve or reject. Confirm nothing was written until you approved.

### Lab C — Permission boundaries (5 min)

```bash
claude --tools "Read,Grep,Glob" -p "Fix the divide-by-zero bug in main.go"
```

It can't — no Edit tool. Now:

```bash
claude --allowedTools "Edit" "Read" -p "Fix the divide-by-zero bug in main.go"
git diff
```

### Lab D — CLAUDE.md (5 min)

```bash
cat > CLAUDE.md <<'EOF'
# Lab
- All errors must be wrapped with fmt.Errorf and %w.
- Every exported function needs a doc comment starting with its name.
EOF
claude -p "Add error handling to Divide."
```

Check whether the output honors both rules. Then delete CLAUDE.md and rerun — that contrast is
the whole point.

### Lab E — Hook enforcement (10 min)

```bash
mkdir -p .claude/hooks
cat > .claude/hooks/gofmt.sh <<'EOF'
#!/usr/bin/env bash
file=$(jq -r '.tool_input.file_path // empty')
[[ "$file" == *.go ]] || exit 0
gofmt -w "$file"
echo "{\"systemMessage\": \"gofmt applied\"}"
EOF
chmod +x .claude/hooks/gofmt.sh
cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{ "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/gofmt.sh" }]
    }]
  }
}
EOF
claude -p "Add a function Multiply to main.go with deliberately terrible indentation."
gofmt -l .    # empty = the hook reformatted it
```

### Lab F — A skill (5 min)

```bash
mkdir -p .claude/skills/audit
cat > .claude/skills/audit/SKILL.md <<'EOF'
---
name: audit
description: Audit Go files for unhandled errors and missing doc comments.
allowed-tools: Read, Grep, Glob
---
Check every .go file for:
1. Function calls whose error return is ignored.
2. Exported identifiers without a doc comment.

Report as a markdown table: file:line | issue | suggested fix.
Say "clean" if there's nothing. Do not invent issues.
EOF
claude
```

Then type `/audit`.

### Lab G — Scripting (5 min)

```bash
claude -p "Count the functions in main.go" \
  --json-schema '{"type":"object","properties":{"count":{"type":"integer"},"names":{"type":"array","items":{"type":"string"}}},"required":["count","names"]}' \
  --output-format json | jq .
```

### Lab H — Real repo, real workflow (10 min)

```bash
cd ~/go/src/kubedb.dev/apimachinery
claude --permission-mode plan --add-dir ../documentdb
```

Ask: *"How does DocumentDB's TLS config differ from the other KubeDB databases?"* Watch it fan out
with Explore subagents. Then `/context` to see the cost, and `/code-review` on your working diff.

### Cleanup

```bash
rm -rf /tmp/cc-lab
```

---

## 22. Cheat sheet

```bash
# Daily
claude                                   # start
claude -c                                # continue here
claude -r                                # pick a session
claude --permission-mode plan "..."      # investigate safely  ← default habit
claude --add-dir ../sibling              # multi-repo work

# Scripting
claude -p "..." --output-format json
git diff | claude -p "write a commit message"
claude -p "..." --json-schema '{...}' --max-turns 3

# Safety
claude --tools "Read,Grep,Glob"          # read-only agent
claude --disallowedTools "Bash(git push *)"
claude --safe-mode                       # config broken?

# Delegation
claude --bg "long investigation"
claude -w feature-x                      # isolated worktree
claude agents                            # dashboard

# In-session
Shift+Tab   cycle permission modes
Esc         interrupt
Esc Esc     rewind
Ctrl+O      transcript
!cmd        shell into context
@file       file reference
/context /compact /code-review /memory /doctor
```

### The five habits that matter

1. **Plan mode for anything non-trivial.** Catch wrong approaches before they become wrong code.
2. **Write a CLAUDE.md.** You don't have one. Start with `/init`, then trim to under 200 lines.
3. **Hooks for anything that must always happen.** CLAUDE.md is a suggestion; a hook is a guarantee.
4. **`/context` when things feel slow or dumb.** Usually a full context window.
5. **Never `--dangerously-skip-permissions` on a machine with real credentials.**

---

## Sources

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Commands](https://code.claude.com/docs/en/commands)
- [Skills](https://code.claude.com/docs/en/slash-commands)
- [Settings](https://code.claude.com/docs/en/settings)
- [Hooks](https://code.claude.com/docs/en/hooks)
- [Memory](https://code.claude.com/docs/en/memory)
- [Interactive mode](https://code.claude.com/docs/en/interactive-mode)
- Local `claude --help` @ v2.1.224
