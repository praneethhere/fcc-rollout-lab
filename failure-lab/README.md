# Three controlled rollout failures

Run `bash failures.sh` from the companion root after a successful `bash setup.sh` in the same directory. Keep `state/`, `evidence/`, and `kubeconfig` in place. The lab ends at healthy v2 if all checks pass.

| Case | Single changed field | Required evidence |
| --- | --- | --- |
| Image | `web.image` uses a missing tag in the public Python repository | Scheduled, Pending Pod; missing-tag Event; container waiting with ErrImagePull or ImagePullBackOff. |
| Readiness | `web.readinessProbe.httpGet.path` is `/not-ready` | Running Pod, Ready=False, zero restarts, its own HTTP 404 readiness Event. |
| Scheduling | An unmatched `nodeSelector` | Pending Pod, PodScheduled=False/Unschedulable, selector-related FailedScheduling Event. |

The checker follows controller owner references by UID and checks the complete desired spec, observed generation, current ReplicaSet, old healthy Pods, and ready Service endpoints. Ten HTTP requests in each checked state must return v2 from the expected healthy Pods. Image authentication, throttling, or network errors do not count as the intended missing-tag failure.

Each case records a ten-second client watch timeout. Only the image case additionally waits for the Deployment's progress deadline, then samples traffic again. Recovery applies `healthy.json`, waits for the failed Pod to disappear, checks the full healthy state, and samples traffic before the next fault.

Reader commands are captured in `*-reader-*` files, alongside the original raw snapshots and check reports. The runner uses the article's Bash `k` wrapper for reader views, dynamically selects names from verified ownership, and checks the UID returned by the reader command against the verified Pod UID.

Every mutation checks that the current Deployment UID matches the baseline recorded by this setup. If an error follows an injection, the runner captures the state before attempting recovery. Any incomplete case keeps a failing exit code even when emergency recovery succeeds. Preserve the evidence archive for diagnosis.

The checker runs in the already-pulled pinned Python image with no network and no host mounts. No host Python or jq installation is required. Kubernetes operations and HTTP traffic run in the local kind lab.
