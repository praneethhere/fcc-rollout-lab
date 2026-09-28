#!/usr/bin/env bash
set -eEuo pipefail

LAB_ROOT="$1"
RUN_DIR="$2"
KCFG="$LAB_ROOT/kubeconfig"
BASELINE_UID=''
NEED_RECOVERY=0
HELPER_CODE=''
APP_IMAGE=''
BASELINE=''
BAD_POD=''
EXPECTED_IMAGE='python@sha256:6438599575cca0d1df94aeee0d2ae088d4d8846eab554b2ee7784a3a6df0d516'
export DOCKER_CONTEXT=colima
K=(kubectl --kubeconfig "$KCFG" --context kind-fcc-rollout-lab --namespace rollout-lab)
MANIFESTS="$LAB_ROOT/failure-lab/manifests"
cd "$LAB_ROOT"

# The article uses this same Bash function. Reader views below exercise it.
k() {
    kubectl --kubeconfig "$LAB_ROOT/kubeconfig" \
        --context kind-fcc-rollout-lab \
        --namespace rollout-lab "$@"
}

show_command() {
    printf '\n[%s] $' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf ' %q' "$@"
    printf '\n'
}

capture() {
    local file="$1" rc=0
    shift
    show_command "$@"
    "$@" > "$RUN_DIR/$file" 2> "$RUN_DIR/$file.stderr" || rc=$?
    printf '[exit=%s; output=%s]\n' "$rc" "$file"
    if [ "$rc" -ne 0 ]; then cat "$RUN_DIR/$file.stderr" >&2; fi
    return "$rc"
}

python_helper() {
    # Reuse the already-pulled image. No host mount, network, or credentials.
    docker run --rm -i --pull never --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges "$APP_IMAGE" python -c "$HELPER_CODE" "$@"
}

assert_identity() {
    "${K[@]}" get deployment rollout-demo -o json --request-timeout=15s > "$RUN_DIR/identity-latest.json" || return 1
    local live_uid
    live_uid="$(python_helper uid < "$RUN_DIR/identity-latest.json")" || return 1
    if [ -z "$BASELINE_UID" ] || [ "$live_uid" != "$BASELINE_UID" ]; then
        printf 'Deployment identity differs from the recorded baseline. No mutation is allowed.\n' >&2
        return 1
    fi
}

snapshot() {
    local destination="$1" rc=0
    "${K[@]}" get deployment,replicasets,pods,services,endpointslices,events -o json \
        --request-timeout=15s > "$destination" 2> "$destination.stderr" || rc=$?
    if [ "$rc" -ne 0 ]; then cat "$destination.stderr" >&2; fi
    return "$rc"
}

check_snapshot() {
    local path="$1" case_name="$2" deadline="$3"
    {
        printf '{"baseline":'
        cat "$BASELINE"
        printf ',"objects":'
        cat "$path"
        printf '}\n'
    } | python_helper check "$case_name" "$deadline"
}

wait_for() {
    local case_name="$1" prefix="$2" limit="$3" deadline="${4:-no}"
    local started=$SECONDS attempt=0 rc=0 sample
    mkdir -p "$RUN_DIR/$prefix" || return 1
    printf '\nWaiting for %s (%ss bound, deadline check=%s).\n' "$case_name" "$limit" "$deadline"
    while [ "$((SECONDS - started))" -le "$limit" ]; do
        attempt=$((attempt + 1))
        sample="$(printf '%03d' "$attempt")"
        snapshot "$RUN_DIR/$prefix/$sample-objects.json" || return 1
        rc=0
        check_snapshot "$RUN_DIR/$prefix/$sample-objects.json" "$case_name" "$deadline" \
            > "$RUN_DIR/$prefix/$sample-check.json" || rc=$?
        if [ "$rc" -eq 0 ]; then
            cp "$RUN_DIR/$prefix/$sample-objects.json" "$RUN_DIR/$prefix/verified-objects.json" || return 1
            cp "$RUN_DIR/$prefix/$sample-check.json" "$RUN_DIR/$prefix/verified-check.json" || return 1
            cat "$RUN_DIR/$prefix/verified-check.json"
            return 0
        fi
        if [ "$rc" -ne 3 ]; then
            cat "$RUN_DIR/$prefix/$sample-check.json" >&2
            return 1
        fi
        if [ "$attempt" -eq 1 ] || [ "$((attempt % 8))" -eq 0 ]; then
            printf 'Still waiting; elapsed %ss. Latest detail: %s/%s-check.json\n' "$((SECONDS - started))" "$prefix" "$sample"
        fi
        sleep 3
    done
    printf 'The expected state was not reached within %ss.\n' "$limit" >&2
    cat "$RUN_DIR/$prefix/$sample-check.json" >&2
    return 1
}

check_nodes() {
    local prefix="$1"
    capture "$prefix-nodes.json" "${K[@]}" get nodes -o json --request-timeout=15s || return 1
    python_helper nodes < "$RUN_DIR/$prefix-nodes.json" > "$RUN_DIR/$prefix-nodes-check.json" || return 1
    cat "$RUN_DIR/$prefix-nodes-check.json"
}

probe_service() {
    local prefix="$1" report="$2" allowed
    allowed="$(python_helper allowed-pods < "$report")" || return 1
    if [ -z "$allowed" ]; then return 1; fi
    capture "$prefix-http.jsonl" "${K[@]}" exec --pod-running-timeout=30s --request-timeout=60s http-client -- \
        python -u /app/probe.py --url http://rollout-demo:8080/ --expected-version v2 --count 10 --interval 0.2 || return 1
    python_helper http "$allowed" < "$RUN_DIR/$prefix-http.jsonl" > "$RUN_DIR/$prefix-http-check.json" || return 1
    cat "$RUN_DIR/$prefix-http-check.json"
}

reader_views() {
    local prefix="$1" report="$2" case_name NEW_RS POD_UID EXPECTED_UID
    case_name="$(python_helper field case < "$report")" || return 1
    NEW_RS="$(python_helper field new_replicaset < "$report")" || return 1
    capture "$prefix-reader-deployment.txt" k get deployment rollout-demo || return 1
    capture "$prefix-reader-deployment.json" k get deployment rollout-demo -o json || return 1
    capture "$prefix-reader-describe-deployment.txt" k describe deployment rollout-demo || return 1
    capture "$prefix-reader-replicasets.txt" k get replicasets -l app=rollout-demo -o wide || return 1
    capture "$prefix-reader-pods.txt" k get pods -l app=rollout-demo -o wide || return 1
    capture "$prefix-reader-replicaset.json" k get replicaset "$NEW_RS" -o json || return 1
    capture "$prefix-reader-endpointslices.json" k get endpointslices -l kubernetes.io/service-name=rollout-demo -o json || return 1
    if [ "$case_name" != healthy ]; then
        BAD_POD="$(python_helper field bad_pod < "$report")" || return 1
        capture "$prefix-reader-pod.json" k get pod "$BAD_POD" -o json || return 1
        capture "$prefix-reader-describe-pod.txt" k describe pod "$BAD_POD" || return 1
        capture "$prefix-reader-pod-uid.txt" k get pod "$BAD_POD" -o jsonpath='{.metadata.uid}' || return 1
        POD_UID="$(cat "$RUN_DIR/$prefix-reader-pod-uid.txt")"
        EXPECTED_UID="$(python_helper field bad_pod_uid < "$report")" || return 1
        if [ -z "$POD_UID" ] || [ "$POD_UID" != "$EXPECTED_UID" ]; then
            printf 'Reader Pod UID differs from the verified fault snapshot.\n' >&2
            return 1
        fi
        capture "$prefix-reader-events.yaml" k get events --field-selector "involvedObject.uid=$POD_UID" \
            --sort-by=.metadata.creationTimestamp -o yaml || return 1
    fi
}

recover() {
    local prefix="$1"
    printf '\nRestoring the complete recorded healthy specification.\n'
    assert_identity || return 1
    capture "$prefix-apply.txt" "${K[@]}" apply -f "$MANIFESTS/healthy.json" --request-timeout=30s || return 1
    capture "$prefix-rollout.txt" "${K[@]}" rollout status deployment/rollout-demo --timeout=300s --request-timeout=30s || return 1
    if [ -n "$BAD_POD" ]; then
        capture "$prefix-reader-delete-wait.txt" k wait --for=delete "pod/$BAD_POD" --timeout=120s || return 1
    fi
    wait_for healthy "$prefix-state" 120 || return 1
    reader_views "$prefix" "$RUN_DIR/$prefix-state/verified-check.json" || return 1
    probe_service "$prefix" "$RUN_DIR/$prefix-state/verified-check.json" || return 1
    NEED_RECOVERY=0
}

finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [ "$rc" -ne 0 ]; then
        printf '\nRun stopped. Capturing the actual state before any recovery.\n'
        if [ -s "$KCFG" ]; then
            snapshot "$RUN_DIR/stopped-objects.json"
            capture stopped-nodes.json "${K[@]}" get nodes -o json --request-timeout=10s
        fi
        if [ "$NEED_RECOVERY" -eq 1 ]; then
            if recover emergency-recovery; then
                printf 'Emergency recovery passed. The experiment still remains incomplete.\n'
            else
                printf 'Automatic recovery could not be verified. Inspect the captured state before making more changes.\n' >&2
            fi
        fi
    fi
    if command -v docker >/dev/null 2>&1; then
        capture docker-stats-after.txt docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
    fi
    printf '\nFailure runner exit: %s\n' "$rc"
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in docker kubectl shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$tool" >&2
        exit 1
    fi
done
for path in "$KCFG" "$LAB_ROOT/state/healthy-run.txt" "$LAB_ROOT/state/app-image.txt" "$LAB_ROOT/failure-lab/inspect.py"; do
    if [ ! -s "$path" ]; then printf 'Missing baseline or add-on file: %s\n' "$path" >&2; exit 1; fi
done
BASELINE_RUN="$(cat "$LAB_ROOT/state/healthy-run.txt")"
if [[ ! "$BASELINE_RUN" =~ ^run-[A-Za-z0-9-]+$ ]]; then
    printf 'Invalid baseline run identifier.\n' >&2
    exit 1
fi
BASELINE="$LAB_ROOT/evidence/$BASELINE_RUN/v2-deployment.json"
if [ ! -s "$BASELINE" ]; then printf 'Missing original baseline snapshot: %s\n' "$BASELINE" >&2; exit 1; fi
APP_IMAGE="$(cat "$LAB_ROOT/state/app-image.txt")"
if [ "$APP_IMAGE" != "$EXPECTED_IMAGE" ]; then
    printf 'The image differs from the pinned baseline. Inspect state/app-image.txt.\n' >&2
    exit 1
fi
HELPER_CODE="$(cat "$LAB_ROOT/failure-lab/inspect.py")"
capture python-image-platform.txt docker image inspect "$APP_IMAGE" --format '{{.Os}}/{{.Architecture}}'
if [ "$(cat "$RUN_DIR/python-image-platform.txt")" != linux/arm64 ]; then
    printf 'Expected the already-pulled ARM64 image.\n' >&2
    exit 1
fi
BASELINE_UID="$(python_helper uid < "$BASELINE")"
# A fresh setup has its own UID. Every mutation still requires a live match
# against the original v2 snapshot recorded by that setup.
assert_identity
mkdir -p "$RUN_DIR/source/failure-lab/manifests"
cp "$LAB_ROOT/failures.sh" "$RUN_DIR/source/"
cp "$LAB_ROOT/failure-lab/runner.sh" "$LAB_ROOT/failure-lab/inspect.py" "$LAB_ROOT/failure-lab/README.md" "$RUN_DIR/source/failure-lab/"
cp "$MANIFESTS/"*.json "$RUN_DIR/source/failure-lab/manifests/"
cp "$BASELINE" "$RUN_DIR/original-v2-deployment.json"
printf '%s\n' "$BASELINE_RUN" > "$RUN_DIR/original-run.txt"
(
    cd "$RUN_DIR/source"
    shasum -a 256 failures.sh failure-lab/runner.sh failure-lab/inspect.py failure-lab/README.md failure-lab/manifests/*.json
) > "$RUN_DIR/source-sha256.txt"
capture kubernetes-version.yaml "${K[@]}" version -o yaml --request-timeout=15s
capture docker-stats-before.txt docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
check_nodes initial
wait_for healthy initial-state 120
reader_views initial "$RUN_DIR/initial-state/verified-check.json"
probe_service initial "$RUN_DIR/initial-state/verified-check.json"
printf 'case\told_revision\tfailed_revision\trecovered_revision\n' > "$RUN_DIR/results.tsv"

for CASE_NAME in image readiness scheduling; do
    printf '\n========== CASE: %s ==========\n' "$CASE_NAME"
    check_nodes "$CASE_NAME-before"
    wait_for healthy "$CASE_NAME-before" 90
    OLD_REVISION="$(python_helper field revision < "$RUN_DIR/$CASE_NAME-before/verified-check.json")"
    BAD_POD=''
    if [ "$CASE_NAME" = scheduling ]; then
        capture scheduling-reader-node-selector.txt k get nodes -l rollout-lab.example.com/placement=no-matching-node
    fi
    assert_identity
    NEED_RECOVERY=1
    capture "$CASE_NAME-apply.txt" "${K[@]}" apply -f "$MANIFESTS/$CASE_NAME.json" --request-timeout=30s

    # A client watch timeout is recorded separately from the controller deadline.
    WATCH_RC=0
    capture "$CASE_NAME-watch.txt" "${K[@]}" rollout status deployment/rollout-demo --timeout=10s --request-timeout=30s || WATCH_RC=$?
    printf '%s\n' "$WATCH_RC" > "$RUN_DIR/$CASE_NAME-watch-exit-code.txt"
    if [ "$WATCH_RC" -eq 0 ] || ! grep -Fq 'timed out waiting for the condition' "$RUN_DIR/$CASE_NAME-watch.txt.stderr"; then
        printf 'The short rollout watch did not produce the expected client timeout.\n' >&2
        exit 1
    fi

    wait_for "$CASE_NAME" "$CASE_NAME-fault" 90
    reader_views "$CASE_NAME-fault" "$RUN_DIR/$CASE_NAME-fault/verified-check.json"
    probe_service "$CASE_NAME-fault" "$RUN_DIR/$CASE_NAME-fault/verified-check.json"
    capture "$CASE_NAME-describe-deployment.txt" "${K[@]}" describe deployment rollout-demo --request-timeout=15s
    BAD_POD="$(python_helper field bad_pod < "$RUN_DIR/$CASE_NAME-fault/verified-check.json")"
    capture "$CASE_NAME-describe-pod.txt" "${K[@]}" describe pod "$BAD_POD" --request-timeout=15s
    if [ "$CASE_NAME" = image ]; then
        printf '\nThe image case intentionally waits for ProgressDeadlineExceeded (configured deadline: 180 seconds).\n'
        capture image-reader-deadline-wait.txt k wait --for=jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'=ProgressDeadlineExceeded \
            deployment/rollout-demo --timeout=240s
        wait_for image image-deadline 30 deadline
        capture image-reader-deadline-deployment.json k get deployment rollout-demo -o json
        probe_service image-deadline "$RUN_DIR/image-deadline/verified-check.json"
    fi
    FAILED_REVISION="$(python_helper field revision < "$RUN_DIR/$CASE_NAME-fault/verified-check.json")"
    recover "$CASE_NAME-recovery"
    RECOVERED_REVISION="$(python_helper field revision < "$RUN_DIR/$CASE_NAME-recovery-state/verified-check.json")"
    printf '%s\t%s\t%s\t%s\n' "$CASE_NAME" "$OLD_REVISION" "$FAILED_REVISION" "$RECOVERED_REVISION" >> "$RUN_DIR/results.tsv"
done

check_nodes final
capture final-summary.txt "${K[@]}" get deployment,replicasets,pods,service -o wide --request-timeout=15s
cat "$RUN_DIR/results.tsv"
printf '\nAll three intended faults, sampled Service responses, and recoveries were verified.\n'
