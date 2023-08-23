
CONFIG=${FML_CONFIG:-~/fml/fml_config.json}




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
  cat $CONFIG | jq -r ".$1.$2"
}

# Returns full config for all running instances
function fml_list()
{
  ports=`psgm | grep dbpath | awk '{ print $16 }' | uniq | sort`
  for port in $ports
  do
    cat $CONFIG | jq -r "with_entries(select(.value.startPort == $(echo $port))) | select(length > 0)"
  done
  echo ""
}

function fml_init()
{
  local INIT_ARGS=$(fml_conf_var $1 initArgs)
  local DIR=$(fml_conf_var $1 directory)
  local MONGO_VER=$(fml_conf_var $1 mongoVersion)
  local START_PORT=$(fml_conf_var $1 startPort)
  # suppress confirmation prompt in m
  export M_CONFIRM=0
  # install specified version of MongoDB with m
  m $MONGO_VER
  mlaunch init $INIT_ARGS --dir $DIR --binarypath `m bin $MONGO_VER` --port $START_PORT
}

function fml_start()
{
  mlaunch start --dir "$(fml_conf_var $1 directory)"
}

function fml_stop()
{
  mlaunch stop --dir "$(fml_conf_var $1 directory)"
}

# param is cluster alias, e.g. myproject
function fml_delete_dir()
{
  rm -rf $(fml_conf_var $1 directory) 
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
  local alias1="$1"
  shift 1
  mongosh "$(fml_conf_var $alias1 connectionString)" "$@"
}

function fml_oldsh()
{
  local alias1="$1"
  shift 1
  mongo "$(fml_conf_var $alias1 connectionString)" "$@"
}

function fml_eval()
{
  local alias1="$1"
  local ev="$2"
  shift 2
  local conn="$(fml_conf_var $alias1 connectionString)"
  mongosh --quiet --norc --eval "$ev" $conn "$@"
}

function fml_oldeval()
{
  local alias1="$1"
  local ev="$2"
  shift 2
  local conn="$(fml_conf_var $alias1 connectionString)"
  mongo --quiet --norc --eval "$ev" $conn "$@"
}

function fml_dump()
{
  local alias1="$1"
  shift
  mongodump "$(fml_conf_var $alias1 connectionString)" "$@"
}

function fml_restore()
{
  local alias1="$1"
  shift 1
  mongorestore "$(fml_conf_var $alias1 connectionString)" "$@"
}

function fml_dump_restore()
{
  local alias0="$1"
  local alias1="$2"
  dumpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'dump_')
  mongodump "$(fml_conf_var $alias0 connectionString)" --out="$dumpdir"
  mongorestore "$(fml_conf_var $alias1 connectionString)" --dir="$dumpdir"
  rm -rf $dumpdir
}

function fml_restore()
{
  local alias1="$1"
  shift 1
  mongorestore "$(fml_conf_var $alias1 connectionString)" "$@"
}

function fml_config()
{
  cat $CONFIG
}

function fml_sync()
{
  local alias0="$1"
  local alias1="$2"
  shift 2
  
  local connstr0="$(fml_conf_var $alias0 connectionString)"
  local connstr1="$(fml_conf_var $alias1 connectionString)"
  
  local logfile="mongosync_log_${alias0}_${alias1}.log"
  rm -rf $logfile
  echo "Mongosync log file: $logfile"

  local ver0="$(fml_eval $alias0 'db.version()')"
  local ver1="$(fml_eval $alias1 'db.version()')"

  local extra_msync_args=''
  local extra_start_json=''
  if [[ "$ver0" =~ ^[45] ]] || [[ "$ver1" =~ ^[45]  ]] 
  then
    extra_msync_args='--enableFeatures supportOlderVersions'
    extra_start_json=', "supportOlderVersions": true'
  fi

  echo "extra_msync_args: $extra_msync_args"
  echo "extra_start_json: $extra_start_json"

  fml_sh $alias0 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'
  fml_sh $alias1 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'

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
  kill -9 $msync_pid
  echo "Killed mongosync"

  fml_sh $alias1 --quiet --norc --eval 'db.getSiblingDB("mongosync_reserved_for_internal_use").dropDatabase()'
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
EndOfHELP
}

function fml()
{
  CONFIG=${FML_CONFIG:-~/fml/fml_config.json}
  
  local cmd="$1"
  shift 1

  if [ $cmd = "list" ]
  then
    fml_list
  elif [ $cmd = "init" ]
  then
    fml_init "$@"
  elif [ $cmd = "start" ]
  then
    fml_start "$@"
  elif [ $cmd = "stop" ]
  then
    fml_stop "$@"
  elif [ $cmd = "cleanup" ]
  then
    fml_cleanup "$@"
  elif [ $cmd = "reinit" ]
  then
    fml_reinit "$@"
  elif [ $cmd = "sh" ]
  then
    fml_sh "$@"
  elif [ $cmd = "mongosh" ]
  then
    fml_sh "$@"
  elif [ $cmd = "oldsh" ]
  then
    fml_oldsh "$@"
  elif [ $cmd = "mongo" ]
  then
    fml_oldsh "$@"
  elif [ $cmd = "eval" ]
  then
    fml_eval "$@"
  elif [ $cmd = "oldeval" ]
  then
    fml_oldeval "$@"
  elif [ $cmd = "dump" ]
  then
    fml_dump "$@"
  elif [ $cmd = "restore" ]
  then
    fml_restore "$@"
  elif [ $cmd = "dump_restore" ]
  then
    fml_dump_restore "$@"
  elif [ $cmd = "config" ]
  then
    fml_config "$@"
  elif [ $cmd = "sync" ]
  then
    fml_sync "$@"
  elif [ $cmd = "help" ]
  then
    fml_help
  else
    fml_help
  fi
}

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
  kill -9 `psgmd | awk '{ print $2; }'`
}

function killmongo() 
{
  kill -9 `psgm | awk '{ print $2; }'`
}

function psmsync()
{
  ps -ef | grep mongosync-macos | grep -v grep
}

function killmongosync() 
{
  kill -9 `ps -ef | grep mongosync-macos | grep -v grep | awk '{ print $2 }'`
}



# ------------ retired below here ---------------------------

# old impl. The full config is more useful.
function fml_list_alias_and_directory()
{
  echo "cluster alias, subdirectory (under mlaunchdata)"
  echo "--------------------------------------"
  DIRS=`psgm | grep dbpath | awk '{ split($14, p, "/"); print p[5] }' | uniq | sort`
  for DIR in $DIRS
  do
    NAME=$(cat $CONFIG | jq -r "to_entries[] | select(.value.directory == \"mlaunchdata/$(echo $DIR)\") | .key")
    echo "$NAME, $DIR" 
  done
  echo ""
}




