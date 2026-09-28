#!/usr/bin/env bash
# Run from the existing baseline directory. Compatible with macOS Bash 3.2.
set -uo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
umask 077
mkdir -p "$LAB_ROOT/evidence" || exit 1
RUN_DIR="$(mktemp -d "$LAB_ROOT/evidence/failures-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || exit 1
RUN_ID="${RUN_DIR##*/}"

printf 'Starting the three failure cases. Evidence: %s\n' "$RUN_DIR"
bash "$LAB_ROOT/failure-lab/runner.sh" "$LAB_ROOT" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/transcript.log"
PIPE_RESULTS=("${PIPESTATUS[@]}")
RESULT="${PIPE_RESULTS[0]}"
if [ "${PIPE_RESULTS[1]}" -ne 0 ]; then
    printf 'Transcript recording failed. Treat this run as incomplete.\n' >&2
    RESULT=1
fi
printf '%s\n' "$RESULT" > "$RUN_DIR/failures-exit-code.txt"

ARCHIVE="$LAB_ROOT/fcc-rollout-evidence-$RUN_ID.tar.gz"
if ! COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$LAB_ROOT/evidence" "$RUN_ID"; then
    printf 'Could not archive evidence. Raw files remain in %s\n' "$RUN_DIR" >&2
    exit 1
fi

if [ "$RESULT" -eq 0 ]; then
    printf '\nFAILURE LAB COMPLETE: all three cases and recoveries passed. The lab is healthy at v2.\n'
else
    printf '\nRUN INCOMPLETE (exit %s). Inspect the evidence archive; do not rerun setup.sh.\n' "$RESULT"
fi
printf 'Evidence archive:\n%s\n' "$ARCHIVE"
exit "$RESULT"
