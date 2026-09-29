# Kubernetes rollout debugging lab

Companion code for **How to Debug a Stuck Kubernetes Rollout with a Hands-On Lab**.

The lab establishes healthy v1 and v2 Deployments, then isolates three blocked rollouts: a missing image tag, a readiness URL that returns 404, and an unmatched node selector. All three failures keep the application version at v2. Ownership, conditions, Events, ready endpoints, and actual HTTP responses distinguish the revisions and failure causes.

## Requirements

The recorded environment is macOS 15.7.4 on Apple silicon, Colima 0.10.3, Docker client 29.4.3/server 29.2.1, kind 0.33.0, kubectl 1.36.0, and Kubernetes 1.37.0. The Mac had 16 GiB RAM; Colima used 4 CPUs and about 5.77 GiB of Docker-visible memory. These are observations, not minimum requirements.

The scripts require macOS ARM64, Colima with its Docker runtime running, and kind 0.33.0. Install Docker CLI, Colima, kind, and kubectl beforehand. Internet access to Docker Hub is required. Other platforms are untested. No host Python or jq is required.

## Run the lab

Extract or clone the code into a fresh directory. Setup refuses to overwrite a local `kubeconfig` or an existing cluster named `fcc-rollout-lab`.

```bash
bash setup.sh
```

Setup pins both images, creates one kind node, writes a separate kubeconfig, mounts the Python source through an immutable ConfigMap, and checks healthy v1 and v2 rollouts with ten Service requests each. The final state is v2. It prints an evidence archive path.

For the article's manual walkthrough, use its commands after setup. Alternatively, reproduce the cases and the reader inspection commands automatically:

```bash
bash failures.sh
```

Run failures only after setup succeeds. Allow several minutes: the image case waits for the configured 180-second progress deadline. Each case records diagnostics and HTTP responses, restores the complete healthy specification, and verifies recovery before the next case. It also records the article's table views, individual object JSON, UID-filtered Events, JSONPath deadline wait, and Pod-deletion waits. Compact custom-column alternatives are intentionally omitted.

The failure runner verifies the live Deployment UID against this setup's baseline before every mutation. All kubectl commands use this directory's kubeconfig, context `kind-fcc-rollout-lab`, and namespace `rollout-lab`.

If a check fails, preserve the printed archive. The runner captures the unexpected state and attempts recovery if the Deployment identity still matches. A successful emergency recovery does not turn an incomplete run into a pass. Do not rerun setup over the existing directory.

## Clean up

This deletes the named disposable lab and all its workloads:

```bash
bash cleanup.sh
```

The cleanup script uses Colima's Docker context and the lab kubeconfig. It checks that the lab disappears and other kind cluster names are unchanged, then prints a cleanup evidence archive. Your evidence files remain on the host. To start again, use a fresh extraction after cleanup; setup deliberately refuses to reuse the old kubeconfig.

## Files and evidence

- `app/`: a small standard-library Python HTTP server and an in-cluster HTTP client.
- `manifests/`: cluster, Deployment, Service, and client Pod configuration.
- `scripts/bootstrap.sh`: healthy controls and evidence collection.
- `failure-lab/manifests/`: healthy v2 plus three full-spec manifests with one changed field each.
- `failure-lab/runner.sh`: fault, inspection, traffic, and recovery sequence.
- `failure-lab/inspect.py`: strict checks on captured Kubernetes objects and HTTP responses.
- `setup.sh`, `failures.sh`, `cleanup.sh`: entry points that retain evidence archives.

Evidence is saved in `evidence/` and `fcc-rollout-evidence-*.tar.gz`. Archives exclude the kubeconfig. The included `.gitignore` excludes runtime state and credentials from Git commits. Upload source from a clean extraction, not from a directory containing runtime data.

## Interpretation

An available Deployment need not have finished its update. In the original run, each blocked rollout retained two ready Pods from the previous revision while one new Pod was blocked. Service checks identified the responding Pods by name. Successful finite samples do not establish uninterrupted service or a production availability guarantee.

Only the image case waits for `ProgressDeadlineExceeded`. The controller reports that condition; the script explicitly restores the healthy manifest. It does not rely on automatic rollback or a fixed revision number.

## Validation record

The original two-stage experiment passed on 28 September 2026: healthy v1/v2, all three intended faults, the image deadline, and all recoveries.

A fresh run of this consolidated revision on the same Mac also passed on 28 September 2026. The evidence archives verify the healthy controls, three fault cases and recoveries, reader inspection commands, 100 successful sampled Service requests across ten batches, and scoped cleanup. These finite samples do not establish uninterrupted availability.

## Pinned images

```text
kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
python@sha256:6438599575cca0d1df94aeee0d2ae088d4d8846eab554b2ee7784a3a6df0d516
```

## References

- [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [kubectl rollout status](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_status/)
- [kubectl wait](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_wait/)
- [Probe behavior](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [Node selection](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)

AI assistance was used to develop and review the code. Execution claims refer to recorded runs, separately from local source checks.
