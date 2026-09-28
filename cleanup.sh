#!/usr/bin/env bash
# Delete only this lab, and retain an evidence record. macOS Bash 3.2 compatible.
set -uo pipefail
LAB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
export DOCKER_CONTEXT=colima
export KIND_EXPERIMENTAL_PROVIDER=docker
umask 077
mkdir -p "$LAB_ROOT/evidence" || exit 1
RUN_DIR="$(mktemp -d "$LAB_ROOT/evidence/cleanup-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || exit 1
RUN_ID="${RUN_DIR##*/}"
RESULT=0

capture() {
    local file="$1" rc=0
    shift
    "$@" > "$RUN_DIR/$file" 2> "$RUN_DIR/$file.stderr" || rc=$?
    cat "$RUN_DIR/$file"
    cat "$RUN_DIR/$file.stderr" >&2
    return "$rc"
}

cp "$LAB_ROOT/cleanup.sh" "$RUN_DIR/cleanup.sh" || exit 1
if [ ! -s "$LAB_ROOT/kubeconfig" ]; then
    printf 'No lab kubeconfig in this directory. No cluster was deleted.\n' >&2
    RESULT=1
elif ! capture clusters-before.txt kind get clusters; then
    RESULT=1
elif ! grep -Fxq fcc-rollout-lab "$RUN_DIR/clusters-before.txt"; then
    printf 'The named lab is absent. No cluster was deleted.\n' >&2
    RESULT=1
else
    printf 'Deleting the disposable cluster fcc-rollout-lab and its workloads.\n'
    capture delete.txt kind delete cluster --name fcc-rollout-lab --kubeconfig "$LAB_ROOT/kubeconfig" || RESULT=$?
    if [ "$RESULT" -eq 0 ]; then
        capture clusters-after.txt kind get clusters || RESULT=$?
    fi
    if [ "$RESULT" -eq 0 ]; then
        if grep -Fxq fcc-rollout-lab "$RUN_DIR/clusters-after.txt"; then
            printf 'The lab is still listed after cleanup.\n' >&2
            RESULT=1
        fi
        sed '/^fcc-rollout-lab$/d' "$RUN_DIR/clusters-before.txt" | LC_ALL=C sort > "$RUN_DIR/other-clusters-before.txt"
        LC_ALL=C sort "$RUN_DIR/clusters-after.txt" > "$RUN_DIR/other-clusters-after.txt"
        capture other-clusters-diff.txt diff -u "$RUN_DIR/other-clusters-before.txt" "$RUN_DIR/other-clusters-after.txt" || RESULT=1
    fi
fi
printf '%s\n' "$RESULT" > "$RUN_DIR/cleanup-exit-code.txt"
ARCHIVE="$LAB_ROOT/fcc-rollout-evidence-$RUN_ID.tar.gz"
if ! COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$LAB_ROOT/evidence" "$RUN_ID"; then
    printf 'Could not archive cleanup evidence. Raw files remain in %s\n' "$RUN_DIR" >&2
    exit 1
fi
if [ "$RESULT" -eq 0 ]; then
    printf 'CLEANUP COMPLETE: the lab is absent; the other cluster names are unchanged.\n'
else
    printf 'CLEANUP INCOMPLETE (exit %s). Inspect the evidence.\n' "$RESULT" >&2
fi
printf 'Evidence archive:\n%s\n' "$ARCHIVE"
exit "$RESULT"
