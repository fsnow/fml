
CONFIG=${FML_CONFIG:-~/fml/fml_config.json}

# Check if required dependencies are installed
function fml_check_deps()
{
  local missing=()
  for cmd in jq m mlaunch mongosh; do
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

# params are config name, e.g. customer1, and variable name, e.g. "directory"
function fml_conf_var()
{
  # jq -r returns the values without quotes
  jq -r ".$1.$2" "$CONFIG"
}

# Returns true if alias has been initialized, directory exists
function fml_is_init()
{
  dir=$(fml_conf_var $1 "directory")
  if [[ -d $dir ]] 
  then
    echo "true"
  else
    echo "false"
  fi
}


# Returns true if alias is running
function fml_is_running()
{
  port=$(fml_conf_var $1 "startPort")
  runningports=$(psgm | grep dbpath | awk '{ print $16 }' | uniq | sort)
  if [[ ${runningports[@]} =~ $port ]] 
  then
    echo "true"
  else
    echo "false"
  fi
}

# Returns full config for all running instances
function fml_list_running_json()
{
  ports=$(psgm | grep "port" | sed -E 's/.*--port ([0-9]+).*/\1/' | uniq | sort)
  for port in $ports
  do
    jq -r "with_entries(select(.value.startPort == $port)) | select(length > 0)" "$CONFIG"
  done
  echo ""
}

# Returns aliases for all running instances
function fml_list_running_aliases()
{
  ports=$(psgm | grep dbpath | awk '{ print $16 }' | uniq | sort)
  for port in $ports
  do
    jq -r "with_entries(select(.value.startPort == $port)) | keys[]" "$CONFIG"
  done
}

# Returns aliases for all stopped instances
function fml_list_stopped_aliases()
{
  local aliases=$(fml_list_all_aliases)
  for alias in $aliases
  do
    local is_running=$(fml_is_running $alias)
    if [[ $is_running == "false" ]]
    then
      echo $alias
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
  local is_init=$(fml_is_init $1)
  if [[ $is_init == "false" ]]
  then
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

    echo "Initializing cluster with mlaunch..."
    if ! mlaunch init $INIT_ARGS --dir "$DIR" --binarypath "$BINPATH" --port $START_PORT; then
      echo "Error: mlaunch init failed" >&2
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
    local is_running=$(fml_is_running $1)
    if [[ $is_running == "false" ]]
    then
      mlaunch start --dir "$(fml_conf_var $1 directory)"
      sleep 5
    fi
  fi
}

function fml_stop()
{
  mlaunch stop --dir "$(fml_conf_var $1 directory)"
}

function fml_upgrade()
{
  if [[ -z "$2" ]]; then
    echo "Error: New version required. Usage: fml upgrade <alias> <new_version>" >&2
    return 1
  fi

  fml_stop "$1"
  sleep 10
  local dir=$(fml_conf_var $1 directory)
  local ver=$(fml_conf_var $1 mongoVersion)

  if [[ ! -f "$dir/.mlaunch_startup" ]]; then
    echo "Error: mlaunch startup file not found: $dir/.mlaunch_startup" >&2
    return 1
  fi

  # Portable sed -i for both macOS and Linux
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/$ver/$2/g" "$dir/.mlaunch_startup"
  else
    sed -i "s/$ver/$2/g" "$dir/.mlaunch_startup"
  fi

  if ! jq --arg key "$1" --arg version "$2" '.[$key].mongoVersion = $version' "$CONFIG" > tmp.json; then
    echo "Error: Failed to update config file" >&2
    return 1
  fi
  mv tmp.json "$CONFIG"
  echo "Upgraded $1 from $ver to $2"
}

# param is cluster alias, e.g. myproject
function fml_delete_dir()
{
  local dir=$(fml_conf_var $1 directory)
  if [[ -z "$dir" ]]; then
    echo "Error: No directory configured for alias '$1'" >&2
    return 1
  fi
  if [[ -d "$dir" ]]; then
    echo "Deleting directory: $dir"
    rm -rf "$dir"
  fi
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

function fml_oldsh()
{
  fml_start $1
  local arg1="$1"
  shift 1
  local conn=$(fml_to_connection_string $arg1)
  mongo $conn "$@"
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

function fml_oldeval()
{
  fml_start $1
  local arg1="$1"
  local ev="$2"
  shift 2
  local conn=$(fml_to_connection_string $arg1)
  mongo --quiet --norc --eval "$ev" $conn "$@"
}

function fml_dump()
{
  fml_start $1
  local arg1="$1"
  shift
  local conn=$(fml_to_connection_string $arg1)
  mongodump $conn "$@"
}

function fml_restore()
{
  fml_start $1
  local arg1="$1"
  shift 1
  local conn=$(fml_to_connection_string $arg1)
  mongorestore $conn "$@"
}

function fml_dump_restore()
{
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

function fml_sync()
{
  fml_start $1
  fml_start $2

  local arg1="$1"
  local arg2="$2"
  shift 2

  local connstr0=$(fml_to_connection_string $arg1)
  local connstr1=$(fml_to_connection_string $arg2)

  local logfile="mongosync.log"
  rm -rf $logfile
  echo "Mongosync log file: $logfile"

  local ver0="$(fml_eval $arg1 'db.version()')"
  local ver1="$(fml_eval $arg2 'db.version()')"

  local extra_msync_args=''
  local extra_start_json=''
  if [[ "$ver0" =~ ^[45] ]] || [[ "$ver1" =~ ^[45]  ]] 
  then
    extra_msync_args='--enableFeatures supportOlderVersions'
    extra_start_json=', "supportOlderVersions": true'
  fi

  echo "extra_msync_args: $extra_msync_args"
  echo "extra_start_json: $extra_start_json"

  fml_sh $arg1 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'
  fml_sh $arg2 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'

  local pause_fn="$1"
  shift 1

  mongosync $extra_msync_args --cluster0 "$connstr0" --cluster1 "$connstr1" "$@" >$logfile 2>&1 &
  msync_pid=$(psmsync | grep "$connstr0" | awk '{ print $2; }')
  echo "Started mongosync with pid $msync_pid"

  msync_wait_until '.progress.state=="IDLE"'
  msync_start "$extra_start_json"
  msync_wait_until '.progress.state=="RUNNING" and .progress.info=="change event application"'
  msync_commit
  echo "Killing mongosync with pid $msync_pid"
  if [[ -n "$msync_pid" ]]; then
    kill $msync_pid 2>/dev/null
    sleep 2
    kill -9 $msync_pid 2>/dev/null
  fi
  echo "Killed mongosync"

  fml_sh $arg1 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'
}

function fml_export()
{
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
  mlaunch
  mongosh
  mongo
  mongosync
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
      Lists currently running local instances by alias and mlaunchdata subdirectory
  config                  
      Displays the configuration file
  init <alias>                    
      Calls m to ensure that the configured version is installed, then calls mlaunch init 
      to create a new cluster
  start <alias>                   
      Calls mlaunch start for an alias
  stop <alias>                    
      Calls mlaunch stop for an alias
  upgrade <alias> <new version>
      Updates the mlaunch config file and fml config file for a patch version upgrade
  cleanup <alias>                 
      Stops the cluster for an alias and deletes its data directory
  reinit <alias>                 
      Stops the cluster for an alias, deletes its data directory, then calls mlaunch init
  sh <alias>                      
      Starts a mongosh session for an alias
  oldsh <alias>                   
      Starts a mongo legacy shell session for an alias
  eval <alias> <command to eval>                   
      Evals a command in the mongosh shell.
      Example:
      fml eval myalias 'db.version'
  oldeval <alias> <command to eval>                   
      Evals a command in the mongo shell.
  dump <alias>               
      Calls mongodump with no parameters except the connection string
  restore <alias> <dbName> <gz file or directory>                
      Calls mongorestore to restore the data to the specified database
  dump_restore <alias1> <alias2>               
      Calls mongodump to dump all databases from alias1 cluster to a temporary directory, 
      mongorestore of dump to alias2 cluster, deletes temp directory.
  sync <alias1> <alias2>                    
      Copies the data from alias1 cluster to alias2 cluster with mongosync.
      (Work in progress. Does not work with all version combinations and can only 
      copy all databases and collections)
  export <alias> <db> <collection> <file>
      Calls mongoexport to export JSON data to file.
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

  if [ "$cmd" = "list" ]
  then
    fml_list_running_json
  elif [ "$cmd" = "init" ]
  then
    fml_init "$@"
  elif [ "$cmd" = "start" ]
  then
    fml_start "$@"
  elif [ "$cmd" = "stop" ]
  then
    fml_stop "$@"
  elif [ "$cmd" = "upgrade" ]
  then
    fml_upgrade "$@"
  elif [ "$cmd" = "cleanup" ]
  then
    fml_cleanup "$@"
  elif [ "$cmd" = "reinit" ]
  then
    fml_reinit "$@"
  elif [ "$cmd" = "sh" ]
  then
    fml_sh "$@"
  elif [ "$cmd" = "mongosh" ]
  then
    fml_sh "$@"
  elif [ "$cmd" = "oldsh" ]
  then
    fml_oldsh "$@"
  elif [ "$cmd" = "mongo" ]
  then
    fml_oldsh "$@"
  elif [ "$cmd" = "eval" ]
  then
    fml_eval "$@"
  elif [ "$cmd" = "oldeval" ]
  then
    fml_oldeval "$@"
  elif [ "$cmd" = "dump" ]
  then
    fml_dump "$@"
  elif [ "$cmd" = "restore" ]
  then
    fml_restore "$@"
  elif [ "$cmd" = "dump_restore" ]
  then
    fml_dump_restore "$@"
  elif [ "$cmd" = "config" ]
  then
    fml_config "$@"
  elif [ "$cmd" = "sync" ]
  then
    fml_sync "$@"
  elif [ "$cmd" = "export" ]
  then
    fml_export "$@"
  elif [ "$cmd" = "help" ]
  then
    fml_help
  else
    fml_help
  fi
}


takes_no_dir_alias=("init")
takes_alias_any_state=("sh" "oldsh" "eval" "restore" "dump" "dump_restore" "sync")
takes_alias_already_init=("cleanup" "reinit")
takes_running_alias=("stop")
takes_stopped_alias=("start")
takes_second_alias=("dump_restore" "sync")


function fml_autocomplete()
{
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    prevprev="${COMP_WORDS[COMP_CWORD-2]}"
    opts="help list config init start stop upgrade cleanup reinit sh oldsh eval oldeval dump restore dump_restore sync export"

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
    elif [[ ${takes_second_alias[@]} =~ $prevprev ]] ; then
      local aliases=$(fml_list_all_aliases)
      COMPREPLY=( $(compgen -W "${aliases}" -- ${cur}) )
      return 0
    fi
}

complete -F fml_autocomplete fml


function msync_wait_until() 
{
  echo "Waiting for condition: $1"
  while true
  do
    PROGRESS=$(curl -H "Content-Type: application/json" -X GET http://localhost:27182/api/v1/progress 2>/dev/null)
    RESULT=$(echo $PROGRESS | jq "$1")
    if [[ $RESULT == "true" ]]; then
      break
    fi
    sleep 1
  done
  echo "Condition met"
}

function msync_start() 
{
  echo "Sending start command to mongosync"
  local start_json='{"source": "cluster0", "destination": "cluster1"'
  start_json+="$1"
  start_json+='}'
  curl http://localhost:27182/api/v1/start -X POST --data "$start_json"
  echo ""
}

function msync_commit() 
{
  echo "Sending commit command to mongosync"
  curl http://localhost:27182/api/v1/commit -X POST --data '{ }'
  echo ""
}

function killmongod()
{
  local pids=$(psgmd | awk '{ print $2; }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    sleep 2
    kill -9 $pids 2>/dev/null
  fi
}

function killmongos()
{
  local pids=$(psgms | awk '{ print $2; }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    sleep 2
    kill -9 $pids 2>/dev/null
  fi
}

function killmongo()
{
  local pids=$(psgm | awk '{ print $2; }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    sleep 2
    kill -9 $pids 2>/dev/null
  fi
}

function psmsync()
{
  ps -ef | grep mongosync-macos | grep -v grep
}

function killmongosync()
{
  local pids=$(ps -ef | grep mongosync-macos | grep -v grep | awk '{ print $2 }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null
    sleep 2
    kill -9 $pids 2>/dev/null
  fi
}




# ------------ retired below here ---------------------------

# old impl. The "fml list" with config output is more useful.
function fml_list_alias_and_directory()
{
  echo "cluster alias, subdirectory (under mlaunchdata)"
  echo "--------------------------------------"
  dirs=$(psgm | grep dbpath | awk '{ split($14, p, "/"); print p[5] }' | uniq | sort)
  for dir in $dirs
  do
    alias=$(jq -r "to_entries[] | select(.value.directory == \"mlaunchdata/$dir\") | .key" "$CONFIG")
    echo "$alias, $dir" 
  done
  echo ""
}




