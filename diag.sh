#!/usr/bin/env bash

# set -x

script_dir=$(dirname "$0")

# conf
immich_container="${IMMICH_CONTAINER:-immich_server}"
redis_container="${REDIS_CONTAINER:-immich_redis}"
postgres_container="${POSTGRES_CONTAINER:-immich_postgres}"
postgres_user="${POSTGRES_USER:-postgres}"

# output relative to the current working dir
output_dir="diag_$(date +%Y%m%d_%H%M%S)"
script_log="$output_dir/diag.log"

# global vars
# requested tasks with their args, each element is "task_name arg1 arg2 ..."
declare -a tasks
# all available tasks as associative array to quickly validate task existence by name
declare -A all_tasks_set
# all available tasks as indexed/ordered array to show in help messages
declare -a all_tasks_list

# presets: ordered tasks to execute during a troubleshooting session
declare -A presets
presets["default"]="wait_intro ena_immich_log ena_redis_monitor wait_user dis_redis_monitor get_immich_log get_redis_monitor get_redis_events get_redis_jobs"
presets["redis"]="ena_redis_monitor wait_user dis_redis_monitor get_redis_monitor get_redis_all_records"

task_prefix_pattern='^(ena|dis|get|proc|wait)_'
redis_monitor_pid=""
num_tasks=0
current_step=0

#
# aux functions
#
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_task() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$((++current_step))/$num_tasks]: $*"
}

err() {
    echo "Error: $*" >&2
}

debug() {
    if [[ -n "$DEBUG" ]] ; then
        echo "debug:" "${FUNCNAME[1]}:" "$@"
    fi
}

#
# preparation/"enable" tasks
#
ena_immich_log() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: ena_immich_log [<level>]"
        echo "  <level>    An optional log level to set."
        echo "             Default: verbose"
        echo "Example: $0 ena_immich_log"
        echo
        echo "Configures log level through IMMICH_LOG_LEVEL in .env file."
        echo "Should be run from Immich docker compose directory."
        echo "Immich container is recreated afterwards to apply changes."
        echo
        exit 0
    fi

    log_task "Enable Immich verbose logging (through .env)"
    if [[ -f .env ]] ; then
        if ! grep -q "IMMICH_LOG_LEVEL=verbose" .env; then
            echo "IMMICH_LOG_LEVEL=verbose" >> .env
        fi
        docker compose up -d immich-server
    else
        err ".env not found. Is it present and are you running from the Immich docker compose directory?"
        exit 1
    fi
}

ena_immich_func_tracing() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: ena_immich_func_tracing [<files>]"
        echo "  <files>    A space separated list of files to patch with function tracing. [WIP]"
        echo "             Paths can be relative to the project root or absolute (in container)."
        echo "             Paths should be specified as seen inside the container,"
        echo "             either relative to the app root (/usr/src/app) or absolute."
        echo "             Default: server/dist/services/job.service.js server/dist/repositories/job.repository.js"
        echo "Example: $0 ena_immich_func_tracing"
        echo
        echo "Adds logging statements to js files to trace function calls."
        echo "Container restart is required afterwards to load/apply these changes."
        echo "If container is _recreated_ (down or rm) it reverts to original js files. To re-apply the patch run this task again."
        echo "To disable/revert the patch: recreate the container with docker/compose down or rm."
        echo
        exit 0
    fi

    log_task "Enable function call tracing"

    local diag_loader_code
    diag_loader_code=$(cat "$script_dir/src/diag-loader.js")
    local dist_path="/usr/src/app/server/dist"
    local files_to_patch="server/dist/services/job.service.js server/dist/repositories/job.repository.js"

    if [[ $# -ge 1 ]] ; then
        files_to_patch="$*"
    fi

    log "Put diag*.js into the container"
    docker cp "$script_dir/src/diag.js" immich_server:"$dist_path/utils/"
    docker cp "$script_dir/src/diag-add-logging.js" immich_server:"$dist_path/bin/"

    log "Patch app.module.js to load diag.js"
    docker exec -i "$immich_container" bash << EOF
        grep 'diag\.js' "$dist_path/app.module.js" && exit 0
        echo '$diag_loader_code' >> "$dist_path/app.module.js"
EOF

    log "Patch source files with additional logging statements"
    docker exec "$immich_container" node "$dist_path/bin/diag-add-logging.js" $files_to_patch
}

# WIP
ena_postgres_query_log() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: ena_postgres_query_log"
        echo
        echo "Example: $0 ena_postgres_query_log"
        echo "         POSTGRES_CONTAINER=ImmichPostgresVEC POSTGRES_USER=immichpguser $0 ena_postgres_query_log"
        echo
        exit 0
    fi

    log_task "Enable logging of all queries in Postgres"

    ENABLE_LOG="ALTER SYSTEM SET log_statement = 'all';
    ALTER SYSTEM SET log_destination = 'stderr';
    ALTER SYSTEM SET log_temp_files = 0;
    SELECT pg_reload_conf();"
    docker exec -i --user "$postgres_user" "$postgres_container" psql <<< "$ENABLE_LOG"
}

ena_redis_monitor() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: ena_redis_monitor [<filter>]"
        echo "  <filter>    An extended grep pattern (grep -vE) to exclude matching lines."
        echo "              Default filter: remove noise from BullMQ and Immich polling (warn: this noise can be useful in some cases)."
        echo "Example: $0 ena_redis_monitor '^$'                 # undo default filter, watch everything"
        echo "         $0 ena_redis_monitor thumbnailGeneration  # grep output by 'thumbnailGeneration'"
        echo
        exit 0
    fi

    REDIS_MONITOR_FILE="$output_dir/redis_monitor.log"

    log_task "Enable (start) Redis monitoring. You can watch it with: tail -f $REDIS_MONITOR_FILE"

    # default filter if not provided
    # removed from patterns:
    #   .bzpopmin. ..*:marker.    # https://bullmq.io/news/231204/better-queue-markers/
    # shellcheck disable=SC2155
    local filter=$(cat <<'EOF'
"hmget" "immich_bull:[^"]*:meta"
"zrangebyscore" "immich_bull:[^"]*:delayed"
"rpoplpush" "immich_bull:[^"]*:wait"
"zpopmin" "immich_bull:[^"]*:prioritized"
"del" "immich_bull:[^"]*:pc"
"zrange" "immich_bull:[^"]*:delayed"
"exists" "immich_bull:[^"]*:stalled-check"
"set" "immich_bull:[^"]*:stalled-check"
"hget" "immich_bull:[^"]*:meta" "opts\.maxlenevents"
"xtrim" "immich_bull:[^"]*:events"
"smembers" "immich_bull:[^"]*:stalled"
"lrange" "immich_bull:[^"]*:active"
.evalsha..*( .immich_bull:\S+){8}
.hmget. ..*:meta. .paused. .concurrency.
.zrangebyscore. ..*:delayed. .0. .[0-9]+. .limit. .0. .1000.
.rpoplpush. ..*:wait. ..*:active.
.zpopmin. ..*:prioritized.
.del. ..*:pc.
.zrange. ..*:delayed. .0. .0. .withscores.
EOF
) 
    if [[ -n "$1" ]]; then
        filter="$1"
        echo "Filter in use: $filter"
    fi

    docker exec -i "$redis_container" redis-cli monitor | grep -v -iE -f <(echo "$filter") >"$REDIS_MONITOR_FILE" &
    redis_monitor_pid=$!
}

#
# teardown/"disable" tasks
#
dis_redis_monitor() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: dis_redis_monitor"
        echo "Example: $0 dis_redis_monitor"
        echo
        echo "Stops existing Redis monitor which was started before using ena_redis_monitor."
        echo
        exit 0
    fi

    log_task "Disable (stop) Redis monitoring"
    if [[ -n "$redis_monitor_pid" ]]; then
        kill "$redis_monitor_pid"
        wait "$redis_monitor_pid" 2>/dev/null
    fi
}

#
# log collection tasks
#
get_immich_log() {
    log_task "Get (save) Immich server logs"
    IMMICH_script_log="$output_dir/immich_server.log"
    # docker logs -t "$immich_container" > "$IMMICH_script_log" 2>&1
    docker logs -t --tail 10000 "$immich_container" > "$IMMICH_script_log" 2>&1
}

get_redis_monitor() {
    log_task "Get (save) Redis monitor output: done by 'dis_redis_monitor'"
}

#
# DB schema tasks
#
get_db_schema_drift() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_db_schema_drift"
        echo
        echo "Example: $0 get_db_schema_drift"
        echo
        echo "Checks for database schema drift (differences between the expected schema from code and actual schema in Postgres) as reported by bin/migration.js from Immich."
        echo "Outputs SQL commands to fix the drift"
        echo
        exit 0
    fi

    log_task "Get database schema drift"

    local schema_drift_output="$output_dir/db_schema_drift.log"

    # one-liner
    # docker exec immich_server sh -c 'DB_URL=postgres://$DB_USERNAME:$DB_PASSWORD@database:5432/$DB_DATABASE_NAME node ./server/dist/bin/migrations.js debug && cat migrations.sql'
    docker exec -i --user root "$immich_container" sh << 'EOF' > "$schema_drift_output"
        export DB_URL=postgres://$DB_USERNAME:$DB_PASSWORD@database:5432/$DB_DATABASE_NAME
        node ./server/dist/bin/migrations.js debug
        cat migrations.sql
EOF
    if [[ $(tr -d '\n' <"$schema_drift_output") == 'Wrote migrations.sql-- UP' ]] ; then
        log "No schema drift detected"
    else
        log "⚠️ Schema drift detected. Check the output in file: $schema_drift_output"
    fi
}

#
# data fetching tasks
#
get_ml_clip_distance() {
    if [[ $# -eq 0 ]] || [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_ml_clip_distance <search_term> [filenames...]"
        echo "  <search_term>   Search keyword or phrase (quoted if contains spaces). Required."
        echo "  <filenames>     A space separated list of asset file names."
        echo "             "
        echo "Example: $0 get_ml_clip_distance "'"brick road"'
        echo "         $0 get_ml_clip_distance motorcycle IMG_3952.jpg motorcycle.webp"
        echo
        echo "Returns cosine distance between the search query and (a) top 10 search results by closest distance, (b) assets having specified file names."
        echo
        exit 0
    fi

    local search="$1"
    shift
    local filenames=''
    if [[ $# -ge 1 ]] ; then
        filenames="$*"
    fi

    if [[ -n $filenames ]]; then
        log_task "Get ML CLIP distances for top search results and for files: $filenames"
    else
        log_task "Get ML CLIP distances for top search results"
    fi

    local ml_clip_output="$output_dir/ml_clip_distance.log"

    # TODO: autodiscover or pass as args
    local model='ViT-B-16-SigLIP2__webli'
    local url='http://immich-machine-learning:3003'

    local clip
    clip=$(docker exec "$immich_container" curl -sS -F 'entries={"clip":{"textual":{"modelName":"'$model'"}}}' -F "text=$search" "$url"/predict)
    # CLIP response looks like {"clip":"[0.01392003,0.003079181,...]"}
    debug CLIP response: "${clip:0:62} ... ${clip: -16}"

    SQL=$(cat <<-'EOF'
		SELECT '--- Query 1: Top matches ---' AS section;
		SELECT cast( (:'clip'::json->>'clip')::vector <=> ss.embedding AS DECIMAL(7,6) ) AS cosine_distance,
		  a."originalFileName", a."originalPath"
		FROM asset a
		JOIN smart_search ss ON a.id = ss."assetId"
		ORDER BY cosine_distance ASC
        LIMIT 10;
		SELECT '--- Query 2: Files ---' AS section;
		SELECT cast( (:'clip'::json->>'clip')::vector <=> ss.embedding AS DECIMAL(7,6) ) AS cosine_distance,
		  a."originalFileName", a."originalPath"
		FROM asset a
		JOIN smart_search ss ON a.id = ss."assetId"
		WHERE a."originalFileName" = ANY(
		  SELECT unnest(string_to_array(:'filenames', ' '))
		)
		ORDER BY cosine_distance ASC;
		EOF
    )

    # echo "$SQL" | docker exec -i --user postgres "$postgres_container" psql -q -v clip="$clip" -d immich > "$ml_clip_output" 2>&1
    echo "$SQL" | docker exec -i --user postgres "$postgres_container" \
      psql -q -Pfooter=off -v clip="$clip" -v clip="$clip" -v filenames="$filenames" -d immich 2>&1 | tee "$ml_clip_output"
    #   psql -q -v clip="$clip" -v clip="$clip" -v filenames="$filenames" -d immich > "$ml_clip_output" 2>&1 
}

get_postgres_records() {
    log_task "Get Postgres records"
    POSTGRES_OUTPUT="$output_dir/postgres_records.log"
    
    # shellcheck disable=SC2155
    local sql_queries=$(cat << 'EOF'
SELECT '--- Query 1: Missing thumbnailAt ---' AS section;
SELECT * FROM asset_job_status ajs
JOIN asset a ON a.id = ajs."assetId"
WHERE "thumbnailAt" IS NULL
ORDER BY "metadataExtractedAt" DESC LIMIT 4;

SELECT '--- Query 2: With thumbnailAt ---' AS section;
SELECT * FROM asset_job_status ajs
JOIN asset a ON a.id = ajs."assetId"
JOIN asset_file af ON a.id = af."assetId"
ORDER BY "thumbnailAt" DESC, "metadataExtractedAt" DESC LIMIT 4;

SELECT '--- Query 3: Recent by createdAt ---' AS section;
SELECT * FROM asset a
LEFT JOIN asset_file af ON a.id = af."assetId" 
LEFT JOIN asset_job_status ajs ON a.id = ajs."assetId" 
ORDER BY a."createdAt" DESC LIMIT 4;
EOF
    )

    echo "$sql_queries" | docker exec -i --user postgres "$postgres_container" psql -Ppager=no --expanded -d immich > "$POSTGRES_OUTPUT" 2>&1
}

get_redis_all_records() {
    log_task "Get all Redis records"

    local redis_output="$output_dir/redis_records.log"

    cat "$script_dir/src/redis2txt.sh" | docker exec -i "$redis_container" bash > "$redis_output"
}

get_redis_events() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_redis_events [<queues>]"
        echo "  <queues>   A space separated list of queues to fetch events for."
        echo "             Default: thumbnailGeneration"
        echo "Example: $0 get_redis_events"
        echo "         $0 get_redis_events thumbnailGeneration backgroundTask metadataExtraction"
        echo
        echo "Fetches 'queue:events' from Redis."
        echo
        exit 0
    fi

    local queues="thumbnailGeneration"
    if [[ $# -ge 1 ]] ; then
        queues="$*"
    fi

    log_task "Get recent events for Redis queue(s): $queues"

    local redis_output="$output_dir/redis_events.log"
    local prefix="immich_bull"

    for queue in $queues; do
        echo "=== $queue ==="
        docker exec "$redis_container" redis-cli --raw XREVRANGE "$prefix:$queue:events" + - COUNT 100 | \
            awk '/^[0-9]+-[0-9]+$/ { if (NR > 1) print output ; output = "ID=" $0 ; next }
            { if (!key) { key = $0 } else { output = output ", " key "=" $0 ; key = "" } }
            END { print output }'
    done >> "$redis_output"
}

get_redis_jobs() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_redis_jobs [<queue>]"
        echo "  <queue>    A queue to fetch jobs from."
        echo "             Default: thumbnailGeneration"
        echo "Example: $0 get_redis_jobs library"
        echo "         $0 get_redis_jobs backgroundTask"
        echo
        echo "Fetches jobs from a Redis queue."
        echo
        exit 0
    fi

    local queue="${1:-thumbnailGeneration}"

    log_task "Get jobs from Redis queues: $queue:*"

    local redis_output="$output_dir/redis_jobs.log"
    local prefix="immich_bull"
    # TODO: more states?
    local states_list=("active" "wait" "paused") # LRANGE
    local states_zset=("failed")            # ZRANGE

    echo "=== $queue ===" > "$redis_output"

    # shellcheck disable=SC2048
    for state in ${states_list[*]} ${states_zset[*]}; do
        local redis_key="${prefix}:${queue}:${state}"

        # fetch job IDs for the current state
        case $state in
            active|wait|paused) op=LRANGE ;;
            failed) op=ZRANGE ;;
            *) op='undefined' ;;
        esac
        local job_ids
        job_ids=$(docker exec "$redis_container" redis-cli "$op" "$redis_key" 0 -1)

        [ -z "$job_ids" ] && continue

        # iterate over the job IDs and fetch their details
        for job_id in $job_ids; do
            [ -z "$job_id" ] && continue
            echo "Job ID $job_id ($state)"
            echo "queue: $redis_key"
            docker exec "$redis_container" redis-cli --raw HGETALL "${prefix}:${queue}:${job_id}" \
              | awk '{ if (NR % 2 == 1) { key = $0; } else { printf "%s: %s\n", key, $0; } }'
            echo
        done
    done >> "$redis_output"
}

get_redis_job_counters() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_redis_jobs [<queue>]"
        echo "  <queue>    A queue to fetch jobs from."
        echo "             Default: thumbnailGeneration"
        echo "Example: $0 get_redis_jobs library"
        echo "         $0 get_redis_jobs backgroundTask"
        echo
        echo "Gets job counts per state (active, waiting, ...) for a Redis queue."
        echo
        exit 0
    fi

    local queue="${1:-thumbnailGeneration}"
    log_task "Get Redis jobs counters per state for queue: $queue"

    local prefix="immich_bull"

    for state in wait active paused failed completed delayed prioritized "waiting-children"; do
        local redis_key="$prefix:$queue:$state"
        type=$(docker exec "$redis_container" redis-cli TYPE "$redis_key")
        case $type in
            list) count=$(docker exec "$redis_container" redis-cli LLEN "$redis_key") ;;
            zset) count=$(docker exec "$redis_container" redis-cli ZCARD "$redis_key") ;;
            *) count="0 (n/a)" ;;
        esac
        echo "$state: $count"
    done
}

get_redis_rdb() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: get_redis_rdb"
        echo "Example: $0 get_redis_rdb"
        echo
        echo "[WIP] Gets Redis RDB database file."
        echo 
        exit 0
    fi

    log_task "Get Redis RDB database file"
    redis_rdb="$output_dir/redis.rdb"

    # ensure all in-memory state is saved to disk
    docker exec "$redis_container" redis-cli save
    docker cp "$redis_container":/data/dump.rdb "$redis_rdb"
}

# user action tasks
wait_intro() {
    log_task "Intro with confirmation"

    echo ""
    echo "================================================"
    echo "The script will execute the following tasks:"
    for task_line in "${tasks[@]}"; do
        echo "  $task_line"
    done
    echo ""
    echo "Press any key to continue..."
    echo "================================================"
    echo ""
    read -n 1 -s -r
}

wait_user() {
    log_task "Wait for user actions"

    echo ""
    echo "================================================"
    echo "Please perform your actions to reproduce the issue"
    echo "When done, press any key to continue..."
    echo "================================================"
    echo ""
    read -n 1 -s -r
}

# post-processing tasks
proc_rdb_to_json() {
    if [[ "${1:-}" =~ --help|-h ]]; then
        echo "Usage: proc_rdb_to_json [<input>]"
        echo
        echo "Example: $0 proc_rdb_to_json"
        echo
        echo "[WIP] Reads Redis RDB file from file or stdin, converts it to json using rdb-cli, sorts while preserving formatting, writes resulting json to file or stdout."
        echo "Dependency: rdb-cli must be installed. See https://github.com/redis/librdb."
        echo "Dependency: gsed on macos."
        echo "When converting from a file, get_redis_rdb should be called first, thus ensuring that redis.rdb is present in the output directory."
        echo "When using stdin, this task should be the only task specified."
        echo
        exit 0
    fi

    log_task "Convert Redis RDB database to json"

    redis_rdb="$output_dir/redis.rdb"
    redis_json="$output_dir/redis.json"

    local input="$redis_rdb"
    if [[ "${1:-}" == "-" ]]; then
        input="-"
    fi

    SED="sed"
    command -v gsed > /dev/null && SED=gsed

    # get json with rdb-cli, then sort it while preserving its convenient formatting
    #   convert multiline blocks to single lines (with tabs), sort, then convert back
    echo '[{'
    rdb-cli "$input" json |\
        "$SED" -n '
        /^\s*"immich_bull[^"]*":{\s*$/ {
            :block
            N
            /]},\s*$/! b block
            s/\n/\t/g
        }
        p' | sort | sed 's/\t/\n/g' |\
        grep -vE '^}\]|\[{' |\
        "$SED" -E '/^\s+"[^"]*".*}$/ s/,*$/,/' | sed -E '$s/,$//' # fix json commas after sorting: add missing comma only on lines starting with " and ending with }, remove comma from the last line
    echo '}]' > "$redis_json"
}


#
# command line functions
#
cli_print_help() {
    echo "Immich diagnostic toolkit"
    echo
    echo "Usage:"
    echo "  $0                     # Run default diagnostic tasks"
    echo "  $0 [<task>...]         # Run specific diagnostic tasks in given order"
    echo "  $0 <task> [args...]    # Run specific task with optional args"
    echo "  $0 [<preset>]          # Run specific preset (predefined list of tasks)"
    echo "  $0 --help              # Show this help"
    echo "  $0 <task> --help       # Show help for task"
    echo
    echo "Multiple tasks can be provided, each task can be followed by its arguments. Examples:"
    echo "  $0 get_redis_jobs thumbnailGeneration"
    echo "  $0 get_redis_jobs backgroundTask get_redis_events"
    echo
    cli_print_available_tasks
    echo
}

cli_print_available_tasks() {
    echo "Available tasks:"
    for task in "${all_tasks_list[@]}"; do
        echo "  $task"
    done
    echo
    echo "Available presets"
    for preset in "${!presets[@]}"; do
        printf "  %-10s %s\n" "${preset}:" "${presets[$preset]}"
    done | sort
}

cli_print_help_hint() {
    echo "Immich diagnostic toolkit"
    echo "Usage info: $0 --help"
    echo
}

# auto-discover tasks defined in this script
# populate all_tasks_* from functions matching task prefixes
cli_register_tasks() {
    all_tasks_set=()
    all_tasks_list=()
    # iterate through all function names in the script
    while read -r line; do
        local func_name="${line/declare -f /}"
        if [[ "$func_name" =~ $task_prefix_pattern ]]; then
            all_tasks_set["$func_name"]="$func_name"
            all_tasks_list+=("$func_name")
        fi
    done < <(declare -F)
    debug "all_tasks_set:" "${all_tasks_set[@]}"
}

# expand a preset into task names
# note: arguments with whitespaces are not handled properly
cli_preset_to_tasks() {
    echo "${presets[$1]}"
}

# parse flat list of command line arguments into $tasks (grouped by task)
# from:
# "get_redis_jobs thumbnailGeneration get_redis_events"
# to:
# tasks[
#   "get_redis_jobs thumbnailGeneration",
#   "get_redis_events"
# ]
# also set num_tasks for logging
# note: args/parsing do not support whitespaces in args
parse_tasks() {
    debug "args:" "$@" "| num args: $#"

    tasks=()

    local task=""
    local task_args=()
    
    for item in "$@"; do
        debug "token: $item"
        if [[ -n "${all_tasks_set[$item]:-}" ]]; then
            debug "valid task: $item"
            # save previous task if exists
            if [[ -n "$task" ]]; then
                tasks+=("$task ${task_args[*]}")
            fi
            # begin parsing new task
            task="$item"
            task_args=()
        else
            debug "argument for task $task: $item"
            if [[ -z "$task" ]]; then
                err "'$item': argument provided without a preceding task or mistyped task name"
                cli_print_help
                exit 1
            fi
            task_args+=("$item")
        fi
    done
    # save final task
    if [[ -n "$task" ]]; then
        tasks+=("$task ${task_args[*]}")
    fi

    # set total number of tasks for numbering in log_task
    num_tasks=${#tasks[@]}
}

parse_args() {
    debug "args:" "$@" "| num args: $#"

    tasks_to_parse=("$@")

    if [[ $# -eq 0 ]]; then
        cli_print_help_hint
    fi

    # handle --help / -h (as first arg only)
    if [[ "${1:-}" =~ --help|-h ]]; then
        cli_print_help
        exit 0
    fi

    # handle preset
    # determine tasks or preset to run
    # when no args - default preset
    # when first arg is a known preset - use it
    # expand preset if found
    preset=""
    maybe_preset="${1:-default}"
    maybe_preset_tasks="$(cli_preset_to_tasks "$maybe_preset")"
    if [[ -n "$maybe_preset_tasks" ]]; then
        preset="$maybe_preset"

        # handle "<preset> --help / -h"
        if [[ "${2:-}" =~ --help|-h ]]; then
            echo "Preset: $preset"
            echo "Tasks: ${preset_tasks[*]}"
            exit 0
        fi

        # string to list
        read -r -a preset_tasks <<< "$maybe_preset_tasks"

        log "Run preset: $preset: ${preset_tasks[*]}"
        tasks_to_parse=("${preset_tasks[@]}")
    fi

    # handle tasks
    parse_tasks "${tasks_to_parse[@]}"
}

# execute all parsed tasks
run_tasks() {
    for task_line in "${tasks[@]}"; do
        debug "task line: $task_line"
        # split line into list, [0] - name, [1...] - args
        read -r -a task_parts <<< "$task_line"
        local task_name="${task_parts[0]}"
        local task_args=("${task_parts[@]:1}")

        # execute task
        "$task_name" "${task_args[@]}"
    done
}

#
# main
#

# init logging/output
help_pattern='\s--help|\s-h[ $]'
if [[ ! $* =~ $help_pattern ]]; then
    mkdir -p "$output_dir"
    # print to stdout and to log file
    exec &> >(tee -a "$script_log") 2>&1
fi

cli_register_tasks

# parse arguments, then execute tasks sequentially in the provided order
parse_args "$@"
run_tasks

# fin
log "Execution completed. Output files are in $output_dir"
ls -l "$output_dir"
