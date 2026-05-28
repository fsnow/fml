# fml

**Fast MongoDB Launcher** - A convenience interface for managing multiple local MongoDB instances. Uses aliases and a configuration file to manage instances.

## Dependencies

### Core (required)
- [jq](https://jqlang.github.io/jq/) - JSON processor
- [m](https://github.com/aheckmann/m) - MongoDB version manager
- [mrun](https://mongodb.github.io/mongorun/install.html) - MongoDB cluster launcher (the standalone successor to mlaunch)
- [mongosh](https://www.mongodb.com/docs/mongodb-shell/) - MongoDB shell

### Optional
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
  },
  "test_latest": {
    "directory": "mlaunchdata/test_latest",
    "startPort": 27200,
    "mongoVersion": "8.3.2",
    "upgradePolicy": "*",
    "initArgs": "--single",
    "connectionString": "mongodb://localhost:27200",
    "comment": "Tracks the latest installed MongoDB across all majors"
  }
}
```

### Configuration Fields

| Field | Description |
|-------|-------------|
| `directory` | Data directory for mrun (relative or absolute path) |
| `startPort` | Starting port number for the cluster |
| `mongoVersion` | MongoDB version to install and use |
| `initArgs` | Arguments passed to `mrun init` (e.g., `--replicaset`, `--single`, `--sharded N`) |
| `connectionString` | MongoDB connection string for the cluster |
| `upgradePolicy` | Optional. Glob constraining `fml upgrade <alias>` (1-arg form) and `fml upgrade --all`. See below. |
| `comment` | Optional description of the instance |

### Auto-upgrade policy (`upgradePolicy`)

`fml upgrade <alias>` and `fml upgrade --all` look up the highest **installed**
MongoDB version that matches the alias's `upgradePolicy` and upgrade to it.
"Installed" means what `m` shows on this machine — fml will never pick a
version `m` doesn't have, so the binaries you maintain are the candidate set.

| Pattern | Matches |
|---------|---------|
| `"*"` | Any installed version (cross-major bumps allowed) |
| `"8.*"` | Any installed 8.x.y (cross-minor within major 8) |
| `"8.3.*"` | Any installed 8.3 patch |
| `"8.3.5"` | Exact pin (no auto-upgrade) |
| field omitted | No auto-upgrade; `fml upgrade <alias>` errors. Use the 2-arg `fml upgrade <alias> <version>` form. |

Pre-releases (versions containing `-`, e.g. `8.4.0-rc1`) are always excluded
from auto-selection. You can still pin to one with the explicit 2-arg form.

The typical flow on a machine that auto-upgrades:

```bash
# Keep the m-managed binaries fresh (your existing daily script)
m 8.2 && m 8.3 && m 9.0

# Roll fml-managed clusters forward to match
fml upgrade --all
```

## Installation

1. Install the core dependencies (jq, m, mrun, mongosh)
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
| `init <alias>` | Install MongoDB version and create cluster with mrun |
| `start <alias>` | Start an existing cluster |
| `stop <alias>` | Stop a running cluster |
| `upgrade <alias> <version>` | Upgrade MongoDB version in-place (explicit) |
| `upgrade <alias>` / `upgrade --all` | Upgrade via `upgradePolicy` (see above) |
| `cleanup <alias>` | Stop cluster and delete data directory |
| `reinit <alias>` | Cleanup and reinitialize cluster |
| `sh <alias>` | Open mongosh session (auto-starts cluster) |
| `eval <alias> <cmd>` | Evaluate command in mongosh |
| `dump <alias> [args]` | Run mongodump |
| `restore <alias> [args]` | Run mongorestore |
| `dump_restore <src> <dst>` | Dump from source, restore to destination |
| `export <alias> <db> <coll> <file>` | Export collection to JSON |
| `migrate <alias>` / `migrate --all` | Migrate an existing mlaunch-initialized data directory to mrun |

## Migrating from mlaunch

If you have data directories that were initialized by mlaunch (the predecessor to mrun), run:

```bash
# One alias at a time
fml migrate myproject

# Or every pending alias
fml migrate --all
```

This renames `.mlaunch_startup` to `.mrun_startup` in each data directory. The two tools use the same startup-file schema, so no data is touched and the migration is safe on a running cluster. After migrating, `fml start`/`stop`/etc. operate via mrun.

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
```

## Tests

A bash-only test suite lives under [tests/](tests/). It exercises the
pure-bash helpers (`fml_conf_var`, `_fml_running_ports`,
`fml_delete_dir`, `fml_migrate_one`, dispatcher exit codes, etc.) with
mocked process listings, so no real mongod is required.

```bash
bash tests/run.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FML_CONFIG` | `~/fml/fml_config.json` | Path to configuration file |

Note: `fml init` exports `M_CONFIRM=0` to suppress `m`'s install-confirmation prompt. The export persists for the rest of the shell session.
