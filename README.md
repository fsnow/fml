# fml

**Fast MongoDB Launcher** - A convenience interface for managing multiple local MongoDB instances. Uses aliases and a configuration file to manage instances.

## Dependencies

### Core (required)
- [jq](https://jqlang.github.io/jq/) - JSON processor
- [m](https://github.com/aheckmann/m) - MongoDB version manager
- [mlaunch](http://blog.rueckstiess.com/mtools/mlaunch.html) - MongoDB cluster launcher (part of mtools)
- [mongosh](https://www.mongodb.com/docs/mongodb-shell/) - MongoDB shell

### Optional
- `mongo` - Legacy MongoDB shell (for `oldsh` and `oldeval` commands)
- `mongosync` - For the `sync` command
- `mongodump` / `mongorestore` - For `dump`, `restore`, and `dump_restore` commands
- `mongoexport` - For the `export` command

## Configuration

fml uses a JSON configuration file located at `~/fml/fml_config.json` by default. You can override this by setting the `FML_CONFIG` environment variable.

### Example Configuration

```json
{
  "test7": {
    "directory": "mlaunchdata/test7",
    "startPort": 27000,
    "mongoVersion": "7.0.9",
    "initArgs": "--replicaset",
    "connectionString": "mongodb://localhost:27000,localhost:27001,localhost:27002",
    "comment": "Test replica set on MongoDB 7.0"
  },
  "standalone": {
    "directory": "mlaunchdata/standalone",
    "startPort": 27017,
    "mongoVersion": "6.0.15",
    "initArgs": "--single",
    "connectionString": "mongodb://localhost:27017",
    "comment": "Single node for quick tests"
  },
  "sharded": {
    "directory": "mlaunchdata/sharded",
    "startPort": 27100,
    "mongoVersion": "7.0.9",
    "initArgs": "--replicaset --sharded 2",
    "connectionString": "mongodb://localhost:27100",
    "comment": "Sharded cluster with 2 shards"
  }
}
```

### Configuration Fields

| Field | Description |
|-------|-------------|
| `directory` | Data directory for mlaunch (relative or absolute path) |
| `startPort` | Starting port number for the cluster |
| `mongoVersion` | MongoDB version to install and use |
| `initArgs` | Arguments passed to `mlaunch init` (e.g., `--replicaset`, `--single`, `--sharded N`) |
| `connectionString` | MongoDB connection string for the cluster |
| `comment` | Optional description of the instance |

## Installation

1. Install the core dependencies (jq, m, mlaunch, mongosh)
2. Source the script in your shell profile:

```bash
# Add to ~/.bashrc or ~/.zshrc
source /path/to/fml.sh
```

3. Create your configuration file at `~/fml/fml_config.json`

## Usage Examples

### Initialize and Start a Cluster

```bash
# Initialize a new cluster (installs MongoDB version if needed)
fml init myproject

# Start an existing cluster
fml start myproject

# Stop a running cluster
fml stop myproject
```

### Connect to MongoDB

```bash
# Open a mongosh session
fml sh myproject

# Run a quick eval command
fml eval myproject 'db.version()'

# Use legacy mongo shell
fml oldsh myproject
```

### Manage Cluster Lifecycle

```bash
# Stop and delete data directory
fml cleanup myproject

# Stop, delete, and reinitialize
fml reinit myproject

# Upgrade MongoDB version (e.g., 7.0.9 to 7.0.12)
fml upgrade myproject 7.0.12
```

### Data Operations

```bash
# Dump all databases
fml dump myproject

# Dump with additional mongodump options
fml dump myproject --db=testdb --out=/tmp/backup

# Restore data
fml restore myproject --dir=/tmp/backup

# Copy all data from one cluster to another
fml dump_restore source_alias target_alias

# Sync clusters using mongosync
fml sync source_alias target_alias

# Export a collection to JSON
fml export myproject mydb mycollection /tmp/data.json
```

### List and Inspect

```bash
# List all running instances
fml list

# Show full configuration
fml config

# Show help
fml help
```

### Using Connection Strings Directly

Many commands accept either an alias or a connection string:

```bash
# Connect to a remote cluster
fml sh mongodb://user:pass@remote-host:27017

# Dump from remote, restore to local
fml dump_restore mongodb://remote:27017 local_alias
```

## Available Commands

| Command | Description |
|---------|-------------|
| `help` | Display help message |
| `list` | List currently running local instances |
| `config` | Display the configuration file |
| `init <alias>` | Install MongoDB version and create cluster with mlaunch |
| `start <alias>` | Start an existing cluster |
| `stop <alias>` | Stop a running cluster |
| `upgrade <alias> <version>` | Upgrade MongoDB version in-place |
| `cleanup <alias>` | Stop cluster and delete data directory |
| `reinit <alias>` | Cleanup and reinitialize cluster |
| `sh <alias>` | Open mongosh session (auto-starts cluster) |
| `oldsh <alias>` | Open legacy mongo shell session |
| `eval <alias> <cmd>` | Evaluate command in mongosh |
| `oldeval <alias> <cmd>` | Evaluate command in legacy shell |
| `dump <alias> [args]` | Run mongodump |
| `restore <alias> [args]` | Run mongorestore |
| `dump_restore <src> <dst>` | Dump from source, restore to destination |
| `sync <src> <dst>` | Sync clusters using mongosync |
| `export <alias> <db> <coll> <file>` | Export collection to JSON |

## Shell Autocompletion

fml includes bash autocompletion support. After sourcing the script, tab completion will suggest:
- Commands after `fml`
- Appropriate aliases based on context (running, stopped, initialized, etc.)

## Helper Functions

The script also provides standalone helper functions:

```bash
# List MongoDB processes
psgm    # All MongoDB processes
psgmd   # mongod processes only
psgms   # mongos processes only

# Kill MongoDB processes
killmongod    # Kill all mongod processes
killmongos    # Kill all mongos processes
killmongo     # Kill all MongoDB processes
killmongosync # Kill mongosync process
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FML_CONFIG` | `~/fml/fml_config.json` | Path to configuration file |
