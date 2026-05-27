# fml code review punch list

Issues found during the initial code review (May 2026), saved here as a follow-up backlog. Line numbers are current as of the mongosync/legacy-shell removal commit. Ordered roughly by severity.

## Bugs & correctness

### 1. `fml_is_running` does substring port matching against the wrong column

[fml.sh:78-88](fml.sh#L78-L88)

```bash
runningports=$(psgm | grep dbpath | awk '{ print $16 }' | uniq | sort)
if [[ ${runningports[@]} =~ $port ]]
```

Two problems:

- `$16` is plucked from `ps -ef` output by column, which is fragile (varies by platform/mongod args). The next function ([fml.sh:91-99](fml.sh#L91-L99)) does the same thing differently via `sed -E 's/.*--port ([0-9]+).*/\1/'` — pick one approach.
- `=~ $port` is a substring/regex match. If `startPort=2700`, it will match any running port containing "2700" (e.g. 27000, 27001, 12700). Use exact-match against a list, or `[[ " $runningports " == *" $port "* ]]`.

Note: mrun now provides `mrun list --json --dir <dir>`, which would be a more robust source of truth than parsing `ps` output. Worth considering as part of the fix.

### 2. ~~`tmp.json` written in CWD by `fml_upgrade`~~ DONE

Writes to a `mktemp` sibling of `$CONFIG`, cleans up on failure of either `jq` or `mv`.

### 3. ~~`fml_conf_var` is jq-injection-prone~~ DONE

Now uses `jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONFIG"`. Aliases with dots, spaces, or other special chars work correctly, and missing keys produce empty string instead of the literal `"null"`. The dead `"null"` checks added defensively in earlier commits were removed.

## Robustness

### 4. ~~`fml_delete_dir` guards empty but not `/` or `~`~~ DONE

Now resolves the dir with `cd && pwd -P` and refuses if it resolves to `/`, `$HOME`, empty, or unresolvable. Also refuses when the configured value is literally `"null"` (jq's missing-key marker).

### 5. `fml_stop` errors loudly if the cluster isn't running

[fml.sh:237-240](fml.sh#L237-L240)

`fml_cleanup`/`fml_upgrade` call it unconditionally. Consider a quick `fml_is_running` check (once #1 is fixed).

### 6. Dep check ignores optional binaries

[fml.sh:5-21](fml.sh#L5-L21)

`fml dump` with no `mongodump` installed gets a `command not found` instead of the friendly "install missing dependencies" message. Either check per-subcommand, or expand the global list with a note that some are optional.

### 7. ~~No shebang~~ DONE

Added `#!/usr/bin/env bash` and a short purpose comment.

## Code quality

### 8. Dispatcher should be a `case`

[fml.sh:491-563](fml.sh#L491-L563)

The if/elif chain is still 50+ lines and has one alias (`mongosh` → `sh`) that a `case` with `|` patterns would express in one line.

### 9. Autocomplete arrays leak into global scope

[fml.sh:567-573](fml.sh#L567-L573)

`takes_no_dir_alias`, etc. become globals when the script is sourced. Move them inside `fml_autocomplete` (or prefix with `_fml_`).

### 10. Repeated kill-then-kill-9 pattern

[fml.sh:622-650](fml.sh#L622-L650) — `killmongod`, `killmongos`, and `killmongo` all do the same three-line kill/sleep/kill-9. Could be a `_fml_kill_pids` helper.

## Nice-to-haves

- [fml.sh:78](fml.sh#L78) and similar: echoing `"true"`/`"false"` and string-comparing is a common bash idiom but exit codes (`return 0`/`return 1`) are faster and idiomatic — `if fml_is_running "$alias"; then ...`.
- ~~README is solid, but one small gap: `FML_CONFIG` is documented but the `M_CONFIRM=0` side effect of `fml init` isn't.~~ DONE — added note in README.
- ~~`fml help` returns 0 when an unknown command is passed.~~ DONE — now prints to stderr and returns 1.

## Suggested priority

Remaining top priority:

- **#1** — port match is wrong and will misreport state

Everything else is polish or low-frequency edge cases.
