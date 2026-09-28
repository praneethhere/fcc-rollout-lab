#!/usr/bin/env bash
# Compatible with the Bash 3.2 shipped with macOS.
set -uo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
umask 077
mkdir -p "$LAB_ROOT/evidence" || exit 1
RUN_DIR="$(mktemp -d "$LAB_ROOT/evidence/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || exit 1
RUN_ID="${RUN_DIR##*/}"

printf 'Starting the healthy baseline. Evidence: %s\n' "$RUN_DIR"
bash "$LAB_ROOT/scripts/bootstrap.sh" "$LAB_ROOT" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/transcript.log"
PIPE_RESULTS=("${PIPESTATUS[@]}")
RESULT="${PIPE_RESULTS[0]}"
if [ "${PIPE_RESULTS[1]}" -ne 0 ]; then
    printf 'Transcript recording failed. Treat this run as incomplete.\n' >&2
    RESULT=1
fi
printf '%s\n' "$RESULT" > "$RUN_DIR/setup-exit-code.txt"

ARCHIVE="$LAB_ROOT/fcc-rollout-evidence-$RUN_ID.tar.gz"
if ! tar -czf "$ARCHIVE" -C "$LAB_ROOT/evidence" "$RUN_ID"; then
    printf 'Could not archive evidence. The raw files remain in %s\n' "$RUN_DIR" >&2
    exit 1
fi

if [ "$RESULT" -eq 0 ]; then
    printf '\nBASELINE COMPLETE: v1 and v2 checks passed. The lab remains at v2.\n'
else
    printf '\nSETUP STOPPED (exit %s). Inspect the evidence archive for the failed step.\n' "$RESULT"
fi
printf 'Evidence archive:\n%s\n' "$ARCHIVE"
exit "$RESULT"
