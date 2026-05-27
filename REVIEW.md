# fml code review punch list

Issues found during the initial code review (May 2026), saved here as a follow-up backlog. Line numbers are current as of the mongosync/legacy-shell removal commit. Ordered roughly by severity.

## Bugs & correctness

### 1. ~~`fml_is_running` does substring port matching against the wrong column~~ DONE

Extracted a `_fml_running_ports` helper that pulls `--port N` from each mongod's args (single sed pipeline, no column counting), then `grep -qx` for exact match. Same fix also applied to `fml_list_running_aliases`, which had the same bug. `fml_list_running_json` already used the sed approach; routed it through the new helper too for consistency. Bonus: closed the related nice-to-have by switching `fml_is_init`/`fml_is_running` to exit-code idiom (`if fml_is_running x; then ...`).

### 2. ~~`tmp.json` written in CWD by `fml_upgrade`~~ DONE

Writes to a `mktemp` sibling of `$CONFIG`, cleans up on failure of either `jq` or `mv`.

### 3. ~~`fml_conf_var` is jq-injection-prone~~ DONE

Now uses `jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONFIG"`. Aliases with dots, spaces, or other special chars work correctly, and missing keys produce empty string instead of the literal `"null"`. The dead `"null"` checks added defensively in earlier commits were removed.

## Robustness

### 4. ~~`fml_delete_dir` guards empty but not `/` or `~`~~ DONE

Now resolves the dir with `cd && pwd -P` and refuses if it resolves to `/`, `$HOME`, empty, or unresolvable. Also refuses when the configured value is literally `"null"` (jq's missing-key marker).

### 5. ~~`fml_stop` errors loudly if the cluster isn't running~~ DONE

Now short-circuits and returns 0 if `fml_is_running` is false.

### 6. ~~Dep check ignores optional binaries~~ DONE

Added a small `_fml_require <cmds...>` helper called at the top of `fml_dump`, `fml_restore`, `fml_dump_restore`, and `fml_export`. Produces a friendly `"required command(s) not found: ..."` message and returns 1 instead of letting bash emit `command not found`.

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

- ~~Echo `"true"`/`"false"` instead of exit codes in `fml_is_init`/`fml_is_running`.~~ DONE — both now use exit codes, callers updated.
- ~~README is solid, but one small gap: `FML_CONFIG` is documented but the `M_CONFIRM=0` side effect of `fml init` isn't.~~ DONE — added note in README.
- ~~`fml help` returns 0 when an unknown command is passed.~~ DONE — now prints to stderr and returns 1.

## Suggested priority

All top-priority items are resolved. Remaining items are polish or low-frequency edge cases.
