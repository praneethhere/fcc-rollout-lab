#!/usr/bin/env bash
set -eEuo pipefail

LAB_ROOT="$1"
RUN_DIR="$2"
CLUSTER='fcc-rollout-lab'
CONTEXT='kind-fcc-rollout-lab'
NAMESPACE='rollout-lab'
KCFG="$LAB_ROOT/kubeconfig"
NODE_IMAGE='kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
PYTHON_IMAGE='python@sha256:6438599575cca0d1df94aeee0d2ae088d4d8846eab554b2ee7784a3a6df0d516'
CREATION_STARTED=0

# These variables apply only to this process and its children.
export DOCKER_CONTEXT=colima
export KIND_EXPERIMENTAL_PROVIDER=docker
K=(kubectl --kubeconfig "$KCFG" --context "$CONTEXT" --namespace "$NAMESPACE")

show_command() {
    printf '\n[%s] $' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf ' %q' "$@"
    printf '\n'
}

run() {
    show_command "$@"
    local rc=0
    "$@" || rc=$?
    printf '[exit=%s]\n' "$rc"
    return "$rc"
}

capture() {
    local file="$1"
    shift
    show_command "$@"
    local rc=0
    "$@" > "$RUN_DIR/$file" 2> "$RUN_DIR/$file.stderr" || rc=$?
    printf '[exit=%s; output=%s]\n' "$rc" "$file"
    if [ "$rc" -ne 0 ]; then cat "$RUN_DIR/$file.stderr" >&2; fi
    return "$rc"
}

finish() {
    local rc=$?
    trap - EXIT
    set +e
    if [ "$rc" -ne 0 ]; then
        printf '\nSetup failed; collecting bounded diagnostics.\n'
        if [ "$CREATION_STARTED" -eq 1 ]; then
            # Only the explicitly named new node is inspected.
            capture failed-node-state.txt docker inspect --format '{{json .State}}' "$CLUSTER-control-plane"
            if [ -s "$KCFG" ]; then
                capture failed-nodes.json "${K[@]}" get nodes -o json --request-timeout=10s
                capture failed-pods.json "${K[@]}" get pods -o json --request-timeout=10s
                capture failed-events.yaml "${K[@]}" get events -o yaml --request-timeout=10s
                capture failed-deployment.yaml "${K[@]}" get deployment rollout-demo -o yaml --request-timeout=10s
            fi
        fi
    fi
    if command -v docker >/dev/null 2>&1; then
        capture docker-stats-after.txt docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
    fi
    printf '\nBootstrap exit: %s\n' "$rc"
    exit "$rc"
}
trap finish EXIT

for tool in docker colima kind kubectl shasum sed grep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$tool" >&2
        exit 1
    fi
done
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf 'This lab supports the tested macOS ARM64 environment with Colima.\n' >&2
    exit 1
fi
if [ -e "$KCFG" ]; then
    printf 'This directory already contains a kubeconfig. Preserve your evidence and use a fresh extraction after deleting the lab cluster.\n' >&2
    exit 1
fi

capture host.txt sw_vers
capture host-capacity.txt sysctl hw.memsize hw.logicalcpu
capture colima-version.txt colima version
capture colima-status.txt colima status
capture docker-version.txt docker version
capture docker-capacity.txt docker info --format 'CPUs={{.NCPU}} MemoryBytes={{.MemTotal}} Architecture={{.Architecture}}'
capture docker-containers-before.txt docker ps --format 'table {{.Names}}\t{{.Status}}'
capture docker-stats-before.txt docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
capture kind-version.txt kind version
capture kubectl-client.yaml kubectl version --client -o yaml
capture kind-clusters-before.txt kind get clusters

if grep -Fxq "$CLUSTER" "$RUN_DIR/kind-clusters-before.txt"; then
    printf 'Cluster %s already exists. Stopping before any cluster changes.\n' "$CLUSTER" >&2
    exit 1
fi
if ! grep -q '^kind v0\.33\.0 ' "$RUN_DIR/kind-version.txt"; then
    printf 'This lab requires kind v0.33.0. See kind-version.txt for the installed version.\n' >&2
    exit 1
fi

mkdir -p "$RUN_DIR/source/app" "$RUN_DIR/source/manifests" "$RUN_DIR/source/scripts" "$RUN_DIR/manifests"
cp "$LAB_ROOT/setup.sh" "$LAB_ROOT/README.md" "$RUN_DIR/source/"
cp "$LAB_ROOT/scripts/bootstrap.sh" "$RUN_DIR/source/scripts/"
cp "$LAB_ROOT/app/server.py" "$LAB_ROOT/app/probe.py" "$RUN_DIR/source/app/"
cp "$LAB_ROOT/manifests/"*.yaml "$RUN_DIR/source/manifests/"
(
    cd "$RUN_DIR/source"
    shasum -a 256 setup.sh README.md scripts/bootstrap.sh app/server.py app/probe.py manifests/*.yaml
) > "$RUN_DIR/source-sha256.txt"

run docker pull "$PYTHON_IMAGE"
capture python-image-repodigests.json docker image inspect "$PYTHON_IMAGE" --format '{{json .RepoDigests}}'
capture python-image-digest.txt printf '%s\n' "$PYTHON_IMAGE"
capture python-image-platform.txt docker image inspect "$PYTHON_IMAGE" --format '{{.Os}}/{{.Architecture}}'
APP_IMAGE="$(cat "$RUN_DIR/python-image-digest.txt")"
if [[ ! "$APP_IMAGE" =~ ^(docker\.io/library/)?python@sha256:[a-f0-9]{64}$ ]]; then
    printf 'Unexpected image reference. See python-image-digest.txt.\n' >&2
    exit 1
fi
if [ "$(cat "$RUN_DIR/python-image-platform.txt")" != linux/arm64 ]; then
    printf 'The resolved Python image is not linux/arm64. Stopping before cluster creation.\n' >&2
    exit 1
fi
printf '%s\n' "$NODE_IMAGE" > "$RUN_DIR/node-image.txt"

CREATION_STARTED=1
run kind create cluster --name "$CLUSTER" --config "$LAB_ROOT/manifests/kind.yaml" --image "$NODE_IMAGE" --kubeconfig "$KCFG" --wait 180s --retain
chmod 600 "$KCFG"
capture cluster-context.txt kubectl --kubeconfig "$KCFG" config current-context
if [ "$(cat "$RUN_DIR/cluster-context.txt")" != "$CONTEXT" ]; then
    printf 'Unexpected cluster context. No workload will be applied.\n' >&2
    exit 1
fi
run "${K[@]}" wait --for=condition=Ready nodes --all --timeout=180s
capture kubernetes-version.yaml "${K[@]}" version -o yaml
capture nodes.json "${K[@]}" get nodes -o json
capture system-pods.txt "${K[@]}" get pods -n kube-system -o wide
run "${K[@]}" create namespace "$NAMESPACE"

capture manifests/configmap.yaml "${K[@]}" create configmap rollout-code --from-file="server.py=$LAB_ROOT/app/server.py" --from-file="probe.py=$LAB_ROOT/app/probe.py" --dry-run=client -o yaml
printf '\nimmutable: true\n' >> "$RUN_DIR/manifests/configmap.yaml"
run "${K[@]}" apply -f "$RUN_DIR/manifests/configmap.yaml"
cp "$LAB_ROOT/manifests/service.yaml" "$RUN_DIR/manifests/service.yaml"
run "${K[@]}" apply -f "$RUN_DIR/manifests/service.yaml"
sed "s|__APP_IMAGE__|$APP_IMAGE|g" "$LAB_ROOT/manifests/client.yaml" > "$RUN_DIR/manifests/client.yaml"
run "${K[@]}" apply -f "$RUN_DIR/manifests/client.yaml"

snapshot() {
    local phase="$1"
    capture "$phase-deployment.json" "${K[@]}" get deployment rollout-demo -o json
    capture "$phase-replicasets.json" "${K[@]}" get replicasets -l app=rollout-demo -o json
    capture "$phase-pods.json" "${K[@]}" get pods -o json
    capture "$phase-events.yaml" "${K[@]}" get events --sort-by=.metadata.creationTimestamp -o yaml
    capture "$phase-endpointslices.json" "${K[@]}" get endpointslices -l kubernetes.io/service-name=rollout-demo -o json
    capture "$phase-revision.txt" "${K[@]}" get deployment rollout-demo -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}'
}

for version in v1 v2; do
    sed -e "s|__APP_IMAGE__|$APP_IMAGE|g" -e "s|__APP_VERSION__|$version|g" "$LAB_ROOT/manifests/deployment.yaml" > "$RUN_DIR/manifests/deployment-$version.yaml"
    run "${K[@]}" apply -f "$RUN_DIR/manifests/deployment-$version.yaml"
    run "${K[@]}" rollout status deployment/rollout-demo --timeout=300s
    run "${K[@]}" wait --for=condition=Ready pod/http-client --timeout=180s
    capture "$version-http.jsonl" "${K[@]}" exec http-client -- python -u /app/probe.py --url http://rollout-demo:8080/ --expected-version "$version" --count 10 --interval 0.2
    cat "$RUN_DIR/$version-http.jsonl"
    snapshot "$version"
done

capture final-summary.txt "${K[@]}" get deployment,replicasets,pods,service -o wide
cat "$RUN_DIR/final-summary.txt"
mkdir -p "$LAB_ROOT/state"
cp "$RUN_DIR/manifests/deployment-v2.yaml" "$LAB_ROOT/state/healthy-deployment.yaml"
cp "$RUN_DIR/v2-revision.txt" "$LAB_ROOT/state/healthy-revision.txt"
cp "$RUN_DIR/python-image-digest.txt" "$LAB_ROOT/state/app-image.txt"
printf '%s\n' "${RUN_DIR##*/}" > "$LAB_ROOT/state/healthy-run.txt"
printf '\nHealthy control finished. The Deployment is at v2.\n'
