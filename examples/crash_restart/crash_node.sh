#!/bin/bash
# Crash injector for restart testing.
#
# Wraps the real command. If the host it runs on is named in $CRASH_NODE and
# the current trial matches $CRASH_ON_TRIAL, the rank exits non-zero after
# $CRASH_AFTER seconds instead of running the command. The hostname is appended
# to $CRASHED_NODES_FILE so the submission script can retire exactly that node.
#
# Usage: crash_node.sh <command> [args...]
#
# Hostname matching: on Aurora `hostname` returns the short name
# (x4602c6s7b0n0) while PBS_NODEFILE holds the high-speed-network FQDN
# (x4602c6s7b0n0.hsn.cm.aurora.alcf.anl.gov). `hostname -f` is no help either:
# it resolves to a *different* domain (.hostmgmt.cm.aurora.alcf.anl.gov).
# Compare on the short name only, but record the node using the exact string
# from the nodefile so the restart loop can match it against the pool.

HOST=$(hostname)
HOST_SHORT=${HOST%%.*}
CRASH_SHORT=${CRASH_NODE%%.*}

if [[ -n "${CRASH_NODE:-}" && "$HOST_SHORT" == "$CRASH_SHORT" && "${RUN:-}" == "${CRASH_ON_TRIAL:-}" ]]; then
    sleep ${CRASH_AFTER:-30}
    echo "CRASH-INJECT: simulating node failure on $HOST_SHORT (trial $RUN)" >&2
    # Record the nodefile spelling of the host, not `hostname`'s short form,
    # so get_healthy_nodes.sh can exclude it by exact string match.
    flock -x "$CRASHED_NODES_FILE.lock" -c "echo $CRASH_NODE >> $CRASHED_NODES_FILE"
    rm -f "$CRASHED_NODES_FILE.lock" 2>/dev/null
    exit 42
fi

exec "$@"
