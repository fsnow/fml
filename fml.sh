#!/usr/bin/env bash
# fml — Fast MongoDB Launcher. Source this file from your shell profile.

CONFIG=${FML_CONFIG:-~/fml/fml_config.json}

# Check if required dependencies are installed
function fml_check_deps()
{
  local missing=()
  for cmd in jq m mrun mongosh; do
    if ! command -v $cmd >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Required commands not found: ${missing[*]}" >&2
    echo "Please install missing dependencies before using fml." >&2
    return 1
  fi
  return 0
}

# Per-subcommand dependency check. Subcommands that call optional
# tools (mongodump/mongorestore/mongoexport) invoke this with their
# extras to produce a friendly error if a tool is missing.
function _fml_require()
{
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: required command(s) not found: ${missing[*]}" >&2
    return 1
  fi
  return 0
}

# Validate config file exists and is valid JSON
function fml_validate_config()
{
  if [[ ! -f "$CONFIG" ]]; then
    echo "Error: Config file not found: $CONFIG" >&2
    echo "Please create a config file or set FML_CONFIG environment variable." >&2
    return 1
  fi

  if ! jq empty "$CONFIG" 2>/dev/null; then
    echo "Error: Config file is not valid JSON: $CONFIG" >&2
    return 1
  fi

  return 0
}

function psgm()
{
  ps -ef | grep "m/versions" | grep -v grep
}

function psgmd()
{
  ps -ef | grep mongod | grep "m/versions" | grep -v grep
}

function psgms()
{
  ps -ef | grep mongos | grep "m/versions" | grep -v grep
}


# fml functions start here

# params are config name (e.g. customer1) and variable name (e.g. "directory").
# Returns empty string if the alias or field is missing.
function fml_conf_var()
{
  jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONFIG"
}

# Returns the unique --port values of every mongod/mongos started under m.
# Single source of truth for "which ports are running" checks below.
function _fml_running_ports()
{
  psgm | sed -nE 's/.*--port ([0-9]+).*/\1/p' | sort -u
}

# Exit 0 if alias has been initialized (data dir exists), 1 otherwise.
function fml_is_init()
{
  local dir
  dir=$(fml_conf_var "$1" "directory")
  [[ -n "$dir" && -d "$dir" ]]
}

# Exit 0 if alias's startPort matches a running mongod's --port, 1 otherwise.
function fml_is_running()
{
  local port
  port=$(fml_conf_var "$1" "startPort")
  [[ -z "$port" ]] && return 1
  _fml_running_ports | grep -qx "$port"
}

# Returns full config for all running instances
function fml_list_running_json()
{
  local port
  for port in $(_fml_running_ports)
  do
    jq -r --argjson p "$port" 'with_entries(select(.value.startPort == $p)) | select(length > 0)' "$CONFIG"
  done
  echo ""
}

# Returns aliases for all running instances
function fml_list_running_aliases()
{
  local port
  for port in $(_fml_running_ports)
  do
    jq -r --argjson p "$port" 'with_entries(select(.value.startPort == $p)) | keys[]' "$CONFIG"
  done
}

# Returns aliases for all stopped instances
function fml_list_stopped_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    if ! fml_is_running "$alias"; then
      echo "$alias"
    fi
  done
}



# Returns aliases for all running instances
function fml_list_all_aliases()
{
  jq -r "keys[]" "$CONFIG"
}

# Returns aliases that have been initialized (i.e. have existing directories)
function fml_list_dir_exists_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    local dir=$(fml_conf_var $alias "directory")
    if [[ -n "$dir" && -d "$dir" ]]; then
      echo $alias
    fi
  done
}

# Returns aliases whose data dir still has an .mlaunch_startup file (pending mrun migration)
function fml_list_pending_migrate_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    local dir=$(fml_conf_var $alias "directory")
    if [[ -n "$dir" && -f "$dir/.mlaunch_startup" && ! -f "$dir/.mrun_startup" ]]; then
      echo $alias
    fi
  done
}

# Returns aliases that have not been initialized (i.e. have no existing directories)
function fml_list_dir_not_exists_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    local dir=$(fml_conf_var $alias "directory")
    if [[ -n "$dir" && ! -d "$dir" ]]; then
      echo $alias
    fi
  done
}

# takes an alias or connection string, returns connection string
function fml_to_connection_string()
{
  if [[ $1 == mongodb://* ]] || [[ $1 == mongodb+srv://* ]]
  then
    echo $1
  else
    echo "$(fml_conf_var $1 connectionString)"
  fi
}

function fml_init()
{
  if ! fml_is_init "$1"; then
    local INIT_ARGS=$(fml_conf_var $1 initArgs)
    local DIR=$(fml_conf_var $1 directory)
    local MONGO_VER=$(fml_conf_var $1 mongoVersion)
    local START_PORT=$(fml_conf_var $1 startPort)

    # Validate required config values
    if [[ -z "$DIR" || -z "$MONGO_VER" || -z "$START_PORT" ]]; then
      echo "Error: Missing required configuration for alias '$1'" >&2
      return 1
    fi

    # suppress confirmation prompt in m
    export M_CONFIRM=0
    # install specified version of MongoDB with m
    echo "Installing MongoDB version $MONGO_VER..."
    if ! m $MONGO_VER; then
      echo "Error: Failed to install MongoDB version $MONGO_VER" >&2
      return 1
    fi

    local BINPATH=$(m bin $MONGO_VER)
    if [[ ! -x "$BINPATH/mongod" ]]; then
      echo "Error: MongoDB binaries not found at $BINPATH" >&2
      return 1
    fi

    echo "Initializing cluster with mrun..."
    if ! mrun init $INIT_ARGS --dir "$DIR" --binarypath "$BINPATH" --port $START_PORT; then
      echo "Error: mrun init failed" >&2
      return 1
    fi
    sleep 5
  fi
}

function fml_start()
{
  if ! [[ $1 == mongodb://* ]] && ! [[ $1 == mongodb+srv://* ]]
  then
    fml_init $1
    if ! fml_is_running "$1"; then
      mrun start --dir "$(fml_conf_var $1 directory)"
      sleep 5
    fi
  fi
}

function fml_stop()
{
  if ! fml_is_running "$1"; then
    return 0
  fi
  mrun stop --dir "$(fml_conf_var $1 directory)"
}

# Locally installed MongoDB versions, one per line, ascending order.
# Pre-releases (anything containing '-') are filtered out.
function _fml_installed_versions()
{
  m 2>/dev/null | awk '{print $NF}' | grep -v -- '-' | sort -V
}

# Highest installed version matching the given glob policy ('*', '8.*', '8.3.*', exact).
# Echoes empty string if no installed version matches.
function _fml_latest_matching_policy()
{
  local policy="$1"
  local v latest=""
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    [[ "$v" == $policy ]] && latest="$v"
  done < <(_fml_installed_versions)
  echo "$latest"
}

# Aliases whose config defines a non-empty upgradePolicy.
function fml_list_policy_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    local policy=$(fml_conf_var "$alias" "upgradePolicy")
    [[ -n "$policy" ]] && echo "$alias"
  done
}

# Perform the actual version-bump for one alias to one concrete version.
# Stops the cluster, ensures the binary is installed via m, rewrites
# .mrun_startup and the fml config.
function _fml_upgrade_to()
{
  local alias="$1"
  local new_ver="$2"

  export M_CONFIRM=0
  echo "Ensuring MongoDB $new_ver is installed..."
  if ! m "$new_ver" >/dev/null 2>&1; then
    echo "Error: failed to install MongoDB $new_ver via m" >&2
    return 1
  fi

  fml_stop "$alias"
  sleep 10
  local dir=$(fml_conf_var "$alias" directory)
  local ver=$(fml_conf_var "$alias" mongoVersion)

  if [[ ! -f "$dir/.mrun_startup" ]]; then
    echo "Error: mrun startup file not found: $dir/.mrun_startup" >&2
    return 1
  fi

  # Portable sed -i for both macOS and Linux
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/$ver/$new_ver/g" "$dir/.mrun_startup"
  else
    sed -i "s/$ver/$new_ver/g" "$dir/.mrun_startup"
  fi

  local tmp_config
  tmp_config=$(mktemp "${CONFIG}.XXXXXX") || {
    echo "Error: failed to create temp file beside $CONFIG" >&2
    return 1
  }
  if ! jq --arg key "$alias" --arg version "$new_ver" '.[$key].mongoVersion = $version' "$CONFIG" > "$tmp_config"; then
    rm -f "$tmp_config"
    echo "Error: Failed to update config file" >&2
    return 1
  fi
  if ! mv "$tmp_config" "$CONFIG"; then
    rm -f "$tmp_config"
    echo "Error: Failed to replace config file" >&2
    return 1
  fi
  echo "Upgraded $alias from $ver to $new_ver"
}

# Read upgradePolicy from config, resolve to a concrete version, and
# upgrade if newer than current. No-op (with message) when already at
# the latest matching version.
function _fml_upgrade_by_policy()
{
  local alias="$1"
  local policy
  policy=$(fml_conf_var "$alias" "upgradePolicy")
  if [[ -z "$policy" ]]; then
    echo "Error: alias '$alias' has no upgradePolicy. Use 'fml upgrade $alias <version>' to upgrade explicitly." >&2
    return 1
  fi

  local latest
  latest=$(_fml_latest_matching_policy "$policy")
  if [[ -z "$latest" ]]; then
    echo "Error: no installed version matches policy '$policy' for alias '$alias'" >&2
    echo "  Installed (non-RC): $(_fml_installed_versions | tr '\n' ' ')" >&2
    return 1
  fi

  local current
  current=$(fml_conf_var "$alias" "mongoVersion")
  if [[ "$current" == "$latest" ]]; then
    echo "'$alias': already at latest matching policy '$policy' ($current)"
    return 0
  fi

  # Defensive: if current > latest (e.g. a binary was uninstalled),
  # don't silently "downgrade".
  local highest
  highest=$(printf "%s\n%s\n" "$current" "$latest" | sort -V | tail -1)
  if [[ "$highest" == "$current" ]]; then
    echo "'$alias': current $current is newer than highest installed match $latest for policy '$policy'. Skipping."
    return 0
  fi

  echo "'$alias': upgrading $current -> $latest (policy '$policy')"
  _fml_upgrade_to "$alias" "$latest"
}

# For each alias with an upgradePolicy, run the policy upgrade.
function _fml_upgrade_all()
{
  local ok=0 skipped=0 failed=0
  local alias policy
  for alias in $(fml_list_all_aliases)
  do
    policy=$(fml_conf_var "$alias" "upgradePolicy")
    if [[ -z "$policy" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    if _fml_upgrade_by_policy "$alias"; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
  done
  echo
  echo "fml upgrade --all: $ok handled, $skipped skipped (no policy), $failed failed"
  (( failed > 0 )) && return 1
  return 0
}

function fml_upgrade()
{
  if [[ -z "${1:-}" ]]; then
    echo "Error: usage: fml upgrade <alias> [<version>] | fml upgrade --all" >&2
    return 1
  fi
  if [[ "$1" == "--all" ]]; then
    _fml_upgrade_all
    return $?
  fi
  if [[ -z "${2:-}" ]]; then
    _fml_upgrade_by_policy "$1"
    return $?
  fi
  _fml_upgrade_to "$1" "$2"
}

# param is cluster alias, e.g. myproject
function fml_delete_dir()
{
  local dir=$(fml_conf_var $1 directory)
  if [[ -z "$dir" ]]; then
    echo "Error: No directory configured for alias '$1'" >&2
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  # Refuse to delete obviously dangerous paths (typo defense)
  local resolved
  resolved=$(cd "$dir" && pwd -P) || {
    echo "Error: cannot resolve '$dir'" >&2
    return 1
  }
  if [[ -z "$resolved" || "$resolved" == "/" || "$resolved" == "$HOME" ]]; then
    echo "Error: refusing to rm -rf '$dir' (resolves to '$resolved')" >&2
    return 1
  fi
  echo "Deleting directory: $dir"
  rm -rf "$dir"
}

function fml_cleanup()
{
  fml_stop "$1"
  sleep 10
  fml_delete_dir "$@"
}

function fml_reinit()
{
  fml_cleanup "$1"
  fml_init "$@"
}

# Migrate one cluster's data dir from mlaunch to mrun. The startup-file
# schema is identical between the two tools, so this is just a rename.
# Safe on a running cluster: mongod keeps running and the next fml
# stop/start uses mrun against the renamed file.
function fml_migrate_one()
{
  local alias="$1"
  local dir=$(fml_conf_var $alias "directory")

  if [[ -z "$dir" ]]; then
    echo "Error: no directory configured for alias '$alias'" >&2
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    echo "Skipping '$alias': directory $dir does not exist"
    return 0
  fi
  if [[ -f "$dir/.mrun_startup" ]]; then
    echo "Skipping '$alias': already migrated (.mrun_startup exists in $dir)"
    return 0
  fi
  if [[ ! -f "$dir/.mlaunch_startup" ]]; then
    echo "Skipping '$alias': no .mlaunch_startup file in $dir"
    return 0
  fi

  mv "$dir/.mlaunch_startup" "$dir/.mrun_startup"
  echo "Migrated '$alias': $dir/.mlaunch_startup -> .mrun_startup"
}

function fml_migrate()
{
  if [[ -z "${1:-}" ]]; then
    echo "Error: alias required. Usage: fml migrate <alias> | fml migrate --all" >&2
    return 1
  fi

  if [[ "$1" == "--all" ]]; then
    local aliases=$(fml_list_all_aliases)
    local migrated=0
    for alias in $aliases; do
      local dir=$(fml_conf_var $alias "directory")
      if [[ -n "$dir" && -f "$dir/.mlaunch_startup" && ! -f "$dir/.mrun_startup" ]]; then
        if fml_migrate_one "$alias"; then
          migrated=$((migrated + 1))
        fi
      fi
    done
    echo "Done. Migrated $migrated alias(es)."
  else
    fml_migrate_one "$1"
  fi
}

function fml_sh()
{
  fml_start $1
  local arg1="$1"
  shift 1
  local conn=$(fml_to_connection_string $arg1)
  # Workaround: first mongosh connection sometimes fails after init on certain versions
  # Do a dummy eval to establish connection before opening interactive shell
  mongosh --quiet --norc --eval "db.version()" $conn >/dev/null 2>&1
  mongosh $conn "$@"
}

function fml_eval()
{
  fml_start $1
  local arg1="$1"
  local ev="$2"
  shift 2
  local conn=$(fml_to_connection_string $arg1)
  mongosh --quiet --norc --eval "$ev" $conn "$@"
}

function fml_dump()
{
  _fml_require mongodump || return 1
  fml_start $1
  local arg1="$1"
  shift
  local conn=$(fml_to_connection_string $arg1)
  mongodump $conn "$@"
}

function fml_restore()
{
  _fml_require mongorestore || return 1
  fml_start $1
  local arg1="$1"
  shift 1
  local conn=$(fml_to_connection_string $arg1)
  mongorestore $conn "$@"
}

function fml_dump_restore()
{
  _fml_require mongodump mongorestore || return 1
  fml_start $1
  fml_start $2
  local arg1="$1"
  local arg2="$2"
  local conn1=$(fml_to_connection_string $arg1)
  local conn2=$(fml_to_connection_string $arg2)
  dumpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'dump_')
  mongodump $conn1 --out="$dumpdir"
  mongorestore $conn2 --dir="$dumpdir"
  rm -rf $dumpdir
}

function fml_config()
{
  jq . "$CONFIG"
}

function fml_export()
{
  _fml_require mongoexport || return 1
  fml_start $1
  local arg1="$1"
  local db="$2"
  local coll="$3"
  local file="$4"
  shift 4
  local conn=$(fml_to_connection_string $arg1)
  mongoexport $conn --db=$db --collection=$coll --out=$file "$@"
}

function fml_help()
{
less << EndOfHELP

fml ("Fast MongoDB Launcher") is a command-line interface for managing
local MongoDB instances. Depending on the executed command, it expects that the
following tools are already installed and available on the command line:
  jq
  m
  mrun
  mongosh
  mongodump
  mongorestore
  mongoexport

Usage:
  fml [command]

Examples:
  # Initialize the cluster with alias "myproject"
  fml init myproject

Available Commands:
  help                    
      Displays this message
  list
      Lists currently running local instances by alias and data subdirectory
  config
      Displays the configuration file
  init <alias>
      Calls m to ensure that the configured version is installed, then calls mrun init
      to create a new cluster
  start <alias>
      Calls mrun start for an alias
  stop <alias>
      Calls mrun stop for an alias
  upgrade <alias> <new version>
      Upgrades the cluster to an explicit MongoDB version. Ensures the binary
      is installed via m, rewrites .mrun_startup, and updates the fml config.
  upgrade <alias>
      Reads the alias's upgradePolicy from the fml config, finds the highest
      installed MongoDB version matching it (via m), and upgrades to that.
      No-op if already at the latest matching version.
  upgrade --all
      Runs the policy-based upgrade for every alias with an upgradePolicy.
      Aliases without a policy are silently skipped.
      Policy glob: "*" any installed version, "8.*" any installed 8.x,
                   "8.3.*" any installed 8.3 patch, "8.3.5" exact pin.
  cleanup <alias>
      Stops the cluster for an alias and deletes its data directory
  reinit <alias>
      Stops the cluster for an alias, deletes its data directory, then calls mrun init
  sh <alias>
      Starts a mongosh session for an alias
  eval <alias> <command to eval>
      Evals a command in the mongosh shell.
      Example:
      fml eval myalias 'db.version'
  dump <alias>               
      Calls mongodump with no parameters except the connection string
  restore <alias> <dbName> <gz file or directory>                
      Calls mongorestore to restore the data to the specified database
  dump_restore <alias1> <alias2>               
      Calls mongodump to dump all databases from alias1 cluster to a temporary directory, 
      mongorestore of dump to alias2 cluster, deletes temp directory.
  export <alias> <db> <collection> <file>
      Calls mongoexport to export JSON data to file.
  migrate <alias> | migrate --all
      Migrates a cluster's data directory from mlaunch to mrun by renaming
      .mlaunch_startup to .mrun_startup. The startup-file schema is identical
      between the two tools, so no data is touched. Safe on running clusters.
      Use --all to migrate every alias whose data dir still has .mlaunch_startup.
EndOfHELP
}

function fml()
{
  CONFIG=${FML_CONFIG:-~/fml/fml_config.json}

  # Handle no arguments
  if [[ $# -eq 0 ]]; then
    fml_help
    return 0
  fi

  # Validate dependencies and config (skip for help command)
  if [[ "$1" != "help" ]]; then
    fml_check_deps || return 1
    fml_validate_config || return 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    list)         fml_list_running_json ;;
    init)         fml_init "$@" ;;
    start)        fml_start "$@" ;;
    stop)         fml_stop "$@" ;;
    upgrade)      fml_upgrade "$@" ;;
    cleanup)      fml_cleanup "$@" ;;
    reinit)       fml_reinit "$@" ;;
    sh|mongosh)   fml_sh "$@" ;;
    eval)         fml_eval "$@" ;;
    dump)         fml_dump "$@" ;;
    restore)      fml_restore "$@" ;;
    dump_restore) fml_dump_restore "$@" ;;
    config)       fml_config "$@" ;;
    export)       fml_export "$@" ;;
    migrate)      fml_migrate "$@" ;;
    help)         fml_help ;;
    *)
      echo "fml: unknown command '$cmd'" >&2
      fml_help
      return 1
      ;;
  esac
}


function fml_autocomplete()
{
    local cur prev prevprev opts
    local takes_no_dir_alias=("init")
    local takes_alias_any_state=("sh" "eval" "restore" "dump" "dump_restore")
    local takes_alias_already_init=("cleanup" "reinit")
    local takes_running_alias=("stop")
    local takes_stopped_alias=("start")
    local takes_second_alias=("dump_restore")
    local takes_pending_migrate_alias=("migrate")
    local takes_upgrade_target=("upgrade")

    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    prevprev="${COMP_WORDS[COMP_CWORD-2]}"
    opts="help list config init start stop upgrade cleanup reinit sh eval dump restore dump_restore export migrate"

    if [[ ${prev} == "fml" ]] ; then
      COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
      return 0
    elif [[ ${takes_no_dir_alias[@]} =~ $prev ]] ; then
      local aliases=$(fml_list_dir_not_exists_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_alias_any_state[@]} =~ $prev ]] ; then
      local aliases=$(fml_list_all_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_alias_already_init[@]} =~ $prev ]] ; then
      local aliases=$(fml_list_dir_exists_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_running_alias[@]} =~ $prev ]] ; then
      local aliases=$(fml_list_running_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_stopped_alias[@]} =~ $prev ]] ; then
      local aliases=$(fml_list_stopped_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_pending_migrate_alias[@]} =~ $prev ]] ; then
      local aliases="--all $(fml_list_pending_migrate_aliases)"
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_upgrade_target[@]} =~ $prev ]] ; then
      local aliases="--all $(fml_list_all_aliases)"
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    elif [[ ${takes_second_alias[@]} =~ $prevprev ]] ; then
      local aliases=$(fml_list_all_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    fi
}

complete -F fml_autocomplete fml


# SIGTERM, brief grace period, then SIGKILL for any leftover pids.
function _fml_kill_pids()
{
  local pids="$1"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    sleep 2
    kill -9 $pids 2>/dev/null
  fi
}

function killmongod() { _fml_kill_pids "$(psgmd | awk '{ print $2; }')"; }
function killmongos() { _fml_kill_pids "$(psgms | awk '{ print $2; }')"; }
function killmongo()  { _fml_kill_pids "$(psgm  | awk '{ print $2; }')"; }

