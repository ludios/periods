#!/usr/bin/env bash
# Model-output: Claude Fable 5
#
# A/B benchmark driver for the periods extension's DML hot paths.
#
# Arguments:
#   $1  output directory; receives results.csv (raw per-run numbers) and
#       summary.txt (median-latency comparison from summarize.py).
#
# Environment (A = baseline side, B = candidate side):
#   A_BIN, B_BIN     bin/ directory of each PostgreSQL install; each install
#                    must already contain its side's periods extension build
#   A_PORT, B_PORT   port of each side's running cluster
#   A_LABEL, B_LABEL display names (default: A, B)
#   PGHOST           unix socket directory both clusters listen on
#   ITERS            iterations per side (default 5); each iteration runs the
#                    whole scenario list, sides alternating A/B then B/A to
#                    cancel machine drift
#   DB               database name to (re)create on both sides (default bench)
#   TXN_SCALE        percent of the per-scenario transaction counts to run
#                    (default 100; use e.g. 5 for a smoke test)
set -euo pipefail

# No apostrophes in these messages: inside ${...:?word} bash pairs a quote
# with the next one it sees, even across lines, silently swallowing the
# checks in between.
: "${A_BIN:?bin/ of the side A PostgreSQL install}"
: "${B_BIN:?bin/ of the side B PostgreSQL install}"
: "${A_PORT:?port of the side A cluster}"
: "${B_PORT:?port of the side B cluster}"
: "${PGHOST:?unix socket directory of both clusters}"
A_LABEL=${A_LABEL:-A}
B_LABEL=${B_LABEL:-B}
for label in "$A_LABEL" "$B_LABEL"; do
    case $label in
        *,* | *'"'* | *"'"* | *$'\n'*)
            echo "labels must not contain commas, quotes, or newlines: they go into results.csv unescaped" >&2
            exit 1
            ;;
    esac
done
ITERS=${ITERS:-5}
DB=${DB:-bench}
TXN_SCALE=${TXN_SCALE:-100}
OUTDIR=${1:?usage: run.sh <output directory>}

# Optional command prefix for every pgbench invocation, e.g. "taskset -c 14"
# to pin the client to one CPU on a busy machine (pin the servers by starting
# them under taskset too).
read -r -a PIN <<< "${PIN_CMD:-}"

BENCHDIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUTDIR"
CSV="$OUTDIR/results.csv"
echo "scenario,side,label,iter,txns,tps,latency_ms" > "$CSV"

# name  transactions-at-TXN_SCALE=100
SCENARIOS='
plain_insert 5000
plain_update 5000
v_insert_single 3000
v_insert_batch1k 20
v_update_single 2000
v_update_batch1k 20
v_delete_batch1k 20
v_update_excl 3000
fk_delete_c1 1500
fk_delete_c10 1000
fk_delete_c100 300
fk_update_c1 1500
fk_update_c10 1000
fk_update_c100 300
portion_update 400
'

# Drop and recreate a side's database, install all scenario schemas into it,
# and print what extension version that side actually runs.
# Arguments: bin-dir, port, label.
setup_side() {
    local bin=$1 port=$2 label=$3
    "$bin/dropdb" -h "$PGHOST" -p "$port" --if-exists "$DB"
    "$bin/createdb" -h "$PGHOST" -p "$port" "$DB"
    local -a psql=("$bin/psql" -h "$PGHOST" -p "$port" -d "$DB" -qX -v ON_ERROR_STOP=1)
    "${psql[@]}" -f "$BENCHDIR/setup/00_common.sql" > /dev/null
    "${psql[@]}" -f "$BENCHDIR/setup/10_versioned.sql" > /dev/null
    local spec
    for spec in 'c1 1' 'c10 10' 'c100 100'; do
        # shellcheck disable=SC2086  # word-splitting the pair is the point
        set -- $spec
        "${psql[@]}" -v "suffix=$1" -v "children=$2" -v keys=200 -f "$BENCHDIR/setup/20_fk.sql" > /dev/null
    done
    "${psql[@]}" -f "$BENCHDIR/setup/30_portion.sql" > /dev/null
    local ver pin
    ver=$("${psql[@]}" -tAc "SELECT extversion FROM pg_extension WHERE extname = 'periods'")
    pin=$("${psql[@]}" -tAc "SELECT coalesce(p.proconfig::text, 'none')
                             FROM pg_proc AS p
                             JOIN pg_namespace AS n ON n.oid = p.pronamespace
                             WHERE n.nspname = 'periods' AND p.proname = 'write_history'")
    echo "side $label: periods $ver, write_history proconfig: $pin"
}

# Run one pgbench scenario and append a CSV row.
# Arguments: bin-dir, port, label, side (A|B), iteration, scenario, transactions.
run_one() {
    local bin=$1 port=$2 label=$3 side=$4 iter=$5 name=$6 txns=$7
    local out tps lat
    out=$("${PIN[@]}" "$bin/pgbench" -h "$PGHOST" -p "$port" -n -M prepared -c 1 -j 1 \
            -t "$txns" --random-seed=$((42 + iter)) \
            -f "$BENCHDIR/t/$name.sql" "$DB" 2>&1) || {
        echo "pgbench failed for $name on side $label:" >&2
        echo "$out" >&2
        exit 1
    }
    tps=$(awk '/^tps/ { print $3; exit }' <<< "$out")
    lat=$(awk '/^latency average/ { print $4; exit }' <<< "$out")
    if [ -z "$tps" ] || [ -z "$lat" ] || grep -q 'aborted' <<< "$out"; then
        echo "could not parse pgbench output for $name on side $label:" >&2
        echo "$out" >&2
        exit 1
    fi
    echo "$name,$side,$label,$iter,$txns,$tps,$lat" >> "$CSV"
}

setup_side "$A_BIN" "$A_PORT" "$A_LABEL"
setup_side "$B_BIN" "$B_PORT" "$B_LABEL"

# Warm both sides before measuring.  This can only warm state shared across
# backends — shared_buffers, the filesystem cache, page pruning; per-backend
# state (the extension .so, its static SPI plans, catalog caches) dies with
# each pgbench run's connection, so every measured run pays those once on its
# first transaction, equally on both sides, amortized over the run's
# transaction count.
for side in A B; do
    if [ "$side" = A ]; then
        bin=$A_BIN port=$A_PORT label=$A_LABEL
    else
        bin=$B_BIN port=$B_PORT label=$B_LABEL
    fi
    while read -r name txns; do
        if [ -z "$name" ]; then
            continue
        fi
        warm=$(( txns * 2 / 100 ))
        if (( warm < 5 )); then
            warm=5
        fi
        "${PIN[@]}" "$bin/pgbench" -h "$PGHOST" -p "$port" -n -M prepared -c 1 -j 1 \
            -t "$warm" -f "$BENCHDIR/t/$name.sql" "$DB" > /dev/null 2>&1
    done <<< "$SCENARIOS"
done
echo "warm-up done"

for iter in $(seq 1 "$ITERS"); do
    if (( iter % 2 == 1 )); then
        order='A B'
    else
        order='B A'
    fi
    for side in $order; do
        if [ "$side" = A ]; then
            bin=$A_BIN port=$A_PORT label=$A_LABEL
        else
            bin=$B_BIN port=$B_PORT label=$B_LABEL
        fi
        while read -r name txns; do
            if [ -z "$name" ]; then
                continue
            fi
            scaled=$(( txns * TXN_SCALE / 100 ))
            if (( scaled < 2 )); then
                scaled=2
            fi
            run_one "$bin" "$port" "$label" "$side" "$iter" "$name" "$scaled"
        done <<< "$SCENARIOS"
    done
    # Reset bloat and statistics so every iteration starts from the same
    # place on both sides.
    "$A_BIN/psql" -h "$PGHOST" -p "$A_PORT" -d "$DB" -qXc 'VACUUM ANALYZE;'
    "$B_BIN/psql" -h "$PGHOST" -p "$B_PORT" -d "$DB" -qXc 'VACUUM ANALYZE;'
    echo "iteration $iter/$ITERS done"
done

python3 "$BENCHDIR/summarize.py" "$CSV" | tee "$OUTDIR/summary.txt"
