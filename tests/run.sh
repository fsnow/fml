#!/usr/bin/env bash
# fml test suite. Run with: bash tests/run.sh (from repo root or anywhere).
#
# Tests are pure-bash. Functions that depend on running mongods are
# tested by overriding the helper that reads /bin/ps (`psgm` or
# `_fml_running_ports`) so we don't need a real cluster.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FML_PATH="$SCRIPT_DIR/../fml.sh"

if [[ ! -f "$FML_PATH" ]]; then
  echo "ERROR: cannot find fml.sh at $FML_PATH" >&2
  exit 2
fi

# Counters live in a tempfile so they survive subshell isolation in each test.
COUNT_FILE=$(mktemp)
trap 'rm -f "$COUNT_FILE"' EXIT
export COUNT_FILE

pass() {
  echo "  ok   $1"
  echo "P" >> "$COUNT_FILE"
}

fail() {
  echo "  FAIL $1"
  echo "F $1" >> "$COUNT_FILE"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc — expected [$expected], got [$actual]"
  fi
}

# assert_exit "desc" expected_code <command...>
assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc — expected exit $expected, got $rc"
  fi
}

# Each test gets its own mktemp dir and config.
new_config() {
  local dir
  dir=$(mktemp -d)
  echo "$dir"
}

# ---- tests ----

test_fml_conf_var() {
  echo "## fml_conf_var (#3 jq injection)"
  local tmp; tmp=$(new_config)
  cat > "$tmp/cfg.json" <<'EOF'
{
  "normal": {"directory": "/x", "startPort": 27000},
  "a.b.c":  {"directory": "/y"},
  "with space": {"directory": "/z"}
}
EOF
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"
    assert_eq "normal alias"           "/x" "$(fml_conf_var normal directory)"
    assert_eq "dotted alias"           "/y" "$(fml_conf_var 'a.b.c' directory)"
    assert_eq "spaced alias"           "/z" "$(fml_conf_var 'with space' directory)"
    assert_eq "missing alias is empty" ""   "$(fml_conf_var nonexistent directory)"
    assert_eq "missing field is empty" ""   "$(fml_conf_var normal absent)"
    assert_eq "numeric field"          "27000" "$(fml_conf_var normal startPort)"
  )
  rm -rf "$tmp"
}

test_fml_is_init_and_running() {
  echo "## fml_is_init / fml_is_running (#1 port match + exit-code idiom)"
  local tmp; tmp=$(new_config)
  mkdir -p "$tmp/a"
  cat > "$tmp/cfg.json" <<EOF
{
  "a": {"directory": "$tmp/a", "startPort": 27000},
  "b": {"directory": "$tmp/b-missing", "startPort": 2700}
}
EOF
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"

    # fml_is_init: dir exists → 0, missing → 1
    assert_exit "fml_is_init a (dir exists)"  0 fml_is_init a
    assert_exit "fml_is_init b (dir missing)" 1 fml_is_init b

    # fml_is_running: override _fml_running_ports to return a fixed set,
    # then make sure the EXACT-match (not substring) behavior is correct.
    _fml_running_ports() { printf "%s\n" 27000 28000; }

    assert_exit "is_running a (port 27000 listed)"          0 fml_is_running a
    assert_exit "is_running b (port 2700 NOT listed; substring of 27000)" 1 fml_is_running b
  )
  rm -rf "$tmp"
}

test_fml_delete_dir_safety() {
  echo "## fml_delete_dir (#4 path-sanity guard)"
  local tmp; tmp=$(new_config)
  cat > "$tmp/cfg.json" <<EOF
{
  "rootdir":  {"directory": "/"},
  "homedir":  {"directory": "$HOME"},
  "nodir":    {"directory": ""},
  "realdir":  {"directory": "$tmp/real"}
}
EOF
  mkdir -p "$tmp/real"
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"
    assert_exit "refuse to delete /"     1 fml_delete_dir rootdir
    assert_exit "refuse to delete \$HOME" 1 fml_delete_dir homedir
    assert_exit "error on empty dir"     1 fml_delete_dir nodir
    assert_exit "delete legitimate dir"  0 fml_delete_dir realdir
    if [[ -d "$tmp/real" ]]; then
      fail "real dir was not deleted"
    else
      pass "real dir was deleted"
    fi
  )
  rm -rf "$tmp"
}

test_fml_require() {
  echo "## _fml_require (#6 per-subcommand dep check)"
  (
    source "$FML_PATH"
    assert_exit "_fml_require bash (present)"  0 _fml_require bash
    assert_exit "_fml_require fakecmd-xyzzy"   1 _fml_require fakecmd-xyzzy
    assert_exit "_fml_require multi: one bad"  1 _fml_require bash fakecmd-xyzzy
  )
}

test_running_ports_extraction() {
  echo "## _fml_running_ports (#1 sed extraction, exact match)"
  (
    source "$FML_PATH"
    # Mock psgm to emit a synthetic ps -ef line containing --port N.
    psgm() {
      cat <<'EOF'
501  101  1   0  9:00AM ??   mongod --dbpath /a/db --port 27000 --logpath /a/log
501  102  1   0  9:00AM ??   mongod --dbpath /b/db --port 27001 --logpath /b/log
501  103  1   0  9:00AM ??   mongos --configdb cfg/host:30000 --port 27017
EOF
    }
    local got
    got=$(_fml_running_ports | tr '\n' ' ' | sed 's/ $//')
    assert_eq "ports extracted and sorted" "27000 27001 27017" "$got"
  )
}

test_fml_migrate_one() {
  echo "## fml_migrate_one (migration feature)"
  local tmp; tmp=$(new_config)
  mkdir -p "$tmp/c1" "$tmp/c2" "$tmp/c3"
  echo '{"protocol_version":2}' > "$tmp/c1/.mlaunch_startup"
  echo '{"protocol_version":2}' > "$tmp/c2/.mrun_startup"   # already migrated
  # c3: empty, nothing to migrate
  cat > "$tmp/cfg.json" <<EOF
{
  "c1": {"directory": "$tmp/c1"},
  "c2": {"directory": "$tmp/c2"},
  "c3": {"directory": "$tmp/c3"},
  "c4": {"directory": "$tmp/no-such-dir"}
}
EOF
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"

    assert_exit "migrate c1 (.mlaunch_startup present)" 0 fml_migrate_one c1
    [[ -f "$tmp/c1/.mrun_startup" && ! -f "$tmp/c1/.mlaunch_startup" ]] \
      && pass "c1 file was renamed" \
      || fail "c1 rename did not occur"

    assert_exit "migrate c1 a 2nd time (idempotent)" 0 fml_migrate_one c1
    assert_exit "migrate c2 (already migrated)"      0 fml_migrate_one c2
    assert_exit "migrate c3 (no .mlaunch_startup)"   0 fml_migrate_one c3
    assert_exit "migrate c4 (dir missing)"           0 fml_migrate_one c4
  )
  rm -rf "$tmp"
}

test_fml_upgrade_atomic_write() {
  echo "## fml_upgrade (#2 atomic config write, no tmp.json in cwd)"
  local tmp; tmp=$(new_config)
  mkdir -p "$tmp/x"
  echo '{"protocol_version":2,"mongo_version":"7.0.0"}' > "$tmp/x/.mrun_startup"
  cat > "$tmp/cfg.json" <<EOF
{"x": {"directory": "$tmp/x", "startPort": 27000, "mongoVersion": "7.0.0"}}
EOF
  (
    export FML_CONFIG="$tmp/cfg.json"
    cd "$tmp"  # so we can check tmp.json doesn't appear here
    source "$FML_PATH"
    # stub the side effects we don't want in tests
    fml_stop() { :; }
    sleep()     { :; }

    if fml_upgrade x 8.0.0 >/dev/null 2>&1; then
      pass "fml_upgrade exited 0"
    else
      fail "fml_upgrade failed"
    fi

    local new_ver
    new_ver=$(jq -r '.x.mongoVersion' "$tmp/cfg.json")
    assert_eq "config mongoVersion updated" "8.0.0" "$new_ver"

    [[ -f "$tmp/tmp.json" ]] && fail "tmp.json leaked into cwd" || pass "no tmp.json in cwd"

    # And no leftover mktemp siblings
    if ls "$tmp"/cfg.json.* >/dev/null 2>&1; then
      fail "leftover cfg.json.* sibling tempfile"
    else
      pass "no leftover mktemp siblings"
    fi
  )
  rm -rf "$tmp"
}

test_dispatcher_exit_codes() {
  echo "## fml dispatcher (unknown command, no args)"
  local tmp; tmp=$(new_config)
  echo '{}' > "$tmp/cfg.json"
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"

    # Run in subshells so the fml_help heredoc-to-less doesn't interfere
    fml >/dev/null 2>&1
    assert_eq "no-args returns 0"      "0" "$?"
    fml help >/dev/null 2>&1
    assert_eq "fml help returns 0"     "0" "$?"
    fml bogus >/dev/null 2>&1
    assert_eq "unknown cmd returns 1"  "1" "$?"
  )
  rm -rf "$tmp"
}

test_autocomplete_no_globals() {
  echo "## fml_autocomplete (#9 no global leakage)"
  local tmp; tmp=$(new_config)
  echo '{}' > "$tmp/cfg.json"
  (
    export FML_CONFIG="$tmp/cfg.json"
    source "$FML_PATH"
    local leaked=""
    for v in takes_no_dir_alias takes_alias_any_state takes_alias_already_init \
             takes_running_alias takes_stopped_alias takes_second_alias \
             takes_pending_migrate_alias; do
      if [[ -n "${!v+x}" ]]; then
        leaked+="$v "
      fi
    done
    assert_eq "no takes_* globals after sourcing" "" "$leaked"
  )
  rm -rf "$tmp"
}

# ---- runner ----

main() {
  echo "Running fml test suite"
  echo "  fml.sh: $FML_PATH"
  echo

  test_fml_conf_var
  test_fml_is_init_and_running
  test_fml_delete_dir_safety
  test_fml_require
  test_running_ports_extraction
  test_fml_migrate_one
  test_fml_upgrade_atomic_write
  test_dispatcher_exit_codes
  test_autocomplete_no_globals

  local passed=0 failed=0
  if [[ -f "$COUNT_FILE" ]]; then
    passed=$(grep -c '^P'  "$COUNT_FILE" || :)
    failed=$(grep -c '^F ' "$COUNT_FILE" || :)
  fi
  echo
  echo "==========================="
  echo "  Passed: $passed  Failed: $failed"
  if (( failed > 0 )); then
    echo "  Failures:"
    grep '^F ' "$COUNT_FILE" | sed 's/^F /    - /'
    exit 1
  fi
  echo "  All tests passed."
}

main
