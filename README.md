# Immich diagnostic toolkit

[Overview](#overview) | [How to use](#how-to-use) | [Getting help](#getting-help) | [Output](#output) | [Caveats](#caveats)

## Overview

A set of tools which can be chained together to assist in Immich troubleshooting.

Use case: collecting various supporting info while troubleshooting Immich.
What immich-diag can do in this scenario:
1. Enable detailed logging
2. Capture the current state (records from datastores - Postgres, Redis)
3. Prompt a user to reproduce an issue and wait for key press to continue
4. Collect logs and diagnostic data afterwards, including recent records from datastores
5. Save all collected data to an output directory for sharing with support on Github/Discord.

Also immich-diag can be used in "one-shot mode" to perform specific action(s) or dump interesting records from datastores, non-interactively.

## How to use

1. Clone the repo.
2. Make the script executable: `chmod +x path/to/diag.sh`
3. Specify tasks (tools/probes) to be executed and run it.

Examples:

```sh
# run default diagnostic workflow
./diag.sh

# enable verbose logging with function tracing, wait for user action, then collect logs
./diag.sh ena_immich_log ena_immich_func_tracing wait_user get_immich_log

# monitor Redis activity while reproducing an issue
./diag.sh ena_redis_monitor wait_user dis_redis_monitor get_redis_monitor get_redis_all_records
cat diag_*/redis_records.log    # view its output
```

## Getting help

Check the usage instructions by providing `--help / -h`:

```sh
/path/to/diag.sh --help

Immich diagnostic toolkit

Usage:
  ./diag.sh                     # Run default diagnostic tasks
  ./diag.sh [<task>...]         # Run specific diagnostic tasks in given order
  ./diag.sh <task> [args...]    # Run specific task with optional args
  ./diag.sh [<preset>]          # Run specific preset (predefined list of tasks)
  ./diag.sh --help              # Show this help
  ./diag.sh <task> --help       # Show help for task

Multiple tasks can be provided, each task can be followed by its arguments. Examples:
  ./diag.sh get_redis_jobs thumbnailGeneration
  ./diag.sh get_redis_jobs backgroundTask get_redis_events

Available tasks:
  dis_redis_monitor
  ena_immich_func_tracing
  ena_immich_log
  ena_redis_monitor
  get_db_schema_drift
  get_immich_log
  get_ml_clip_distance
  get_postgres_records
  get_redis_all_records
  get_redis_events
  get_redis_job_counters
  get_redis_jobs
  get_redis_monitor
  get_redis_rdb
  proc_rdb_to_json
  wait_intro
  wait_user

Available presets
  default:   wait_intro ena_immich_log ena_redis_monitor wait_user dis_redis_monitor get_immich_log get_redis_monitor get_redis_events get_redis_jobs
  redis:     ena_redis_monitor user_wait dis_redis_monitor get_redis_monitor get_redis_all_records
```

Show help for a specific task:

```sh
./diag.sh ena_redis_monitor --help
```

## Output

Results will be saved in a directory named `diag_YYYYMMDD_HHMMSS`. This directory contains: 
- outputs from each task, e.g. `immich_server.log`
- the toolkit's own execution log - `script.log`

## Caveats

- This is an early version (v0.1).
- It assumes default container names (`immich_server`, `immich_redis`, `immich_postgres`)
  - If you use custom container names, set these environment variables:
    ```sh
    export IMMICH_CONTAINER=your_immich_container
    export REDIS_CONTAINER=your_redis_container
    export POSTGRES_CONTAINER=your_postgres_container
    ```
- These operations modify Immich configuration:
  - `ena_immich_log` adds `IMMICH_LOG_LEVEL=verbose` to `.env` file
  - `ena_immich_func_tracing` modifies javascript files in the container (these changes are lost when the container is recreated)
- These operations must be run from the Immich installation directory (where docker-compose.yml is located); `cd` there first before running diag:
  - `ena_immich_log`
- The toolkit may capture potentially sensitive information from logs and datastores (e.g. file names and paths). Review its output before sharing diagnostic data.
