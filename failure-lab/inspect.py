"""Verify lab state from captured JSON. No Kubernetes calls or mutations."""

import copy
import json
import re
import sys

PLACEMENT = {"rollout-lab.example.com/placement": "no-matching-node"}
BAD_IMAGE = "docker.io/library/python:fcc-rollout-missing-20260928"


def condition(obj, name):
    return next((c for c in obj.get("status", {}).get("conditions", [])
                 if c.get("type") == name), {})


def owned(obj, uid):
    return any(r.get("uid") == uid and r.get("controller") is True
               for r in obj.get("metadata", {}).get("ownerReferences", []))


def template_without_hash(template):
    result = copy.deepcopy(template)
    result.get("metadata", {}).get("labels", {}).pop("pod-template-hash", None)
    return result


def web_container(template):
    return next(c for c in template["spec"]["containers"] if c["name"] == "web")


def emit(state, **details):
    print(json.dumps({"state": state, **details}, sort_keys=True), flush=True)
    return {"pass": 0, "wait": 3, "unexpected": 2}[state]


def check(data, case, require_deadline):
    baseline = data["baseline"]
    baseline_uid = baseline["metadata"]["uid"]
    items = data["objects"]["items"]
    deployments = [x for x in items if x["kind"] == "Deployment"
                   and x["metadata"]["name"] == "rollout-demo"]
    if len(deployments) != 1 or deployments[0]["metadata"]["uid"] != baseline_uid:
        return emit("unexpected", reason="Deployment identity does not match the recorded baseline")
    dep = deployments[0]
    expected = copy.deepcopy(baseline["spec"])
    container = web_container(expected["template"])
    if case == "image":
        container["image"] = BAD_IMAGE
    elif case == "readiness":
        container["readinessProbe"]["httpGet"]["path"] = "/not-ready"
    elif case == "scheduling":
        expected["template"]["spec"]["nodeSelector"] = PLACEMENT
    if dep["spec"] != expected:
        return emit("unexpected", reason="Live desired specification differs from the intended single-change case")
    status = dep.get("status", {})
    detail = {"case": case, "generation": dep["metadata"]["generation"],
              "observed_generation": status.get("observedGeneration"),
              "deployment_uid": baseline_uid,
              "revision": dep["metadata"].get("annotations", {}).get("deployment.kubernetes.io/revision"),
              "available_replicas": status.get("availableReplicas", 0),
              "updated_replicas": status.get("updatedReplicas", 0),
              "progressing": condition(dep, "Progressing")}
    if status.get("observedGeneration", 0) < dep["metadata"]["generation"]:
        return emit("wait", reason="Controller has not observed the current generation", **detail)

    sets = [x for x in items if x["kind"] == "ReplicaSet" and owned(x, baseline_uid)]
    target_sets = [x for x in sets if template_without_hash(x["spec"]["template"]) == expected["template"]]
    if len(target_sets) != 1:
        return emit("wait", reason="Waiting for exactly one matching ReplicaSet", **detail)
    target = target_sets[0]
    detail["new_replicaset"] = target["metadata"]["name"]
    if target["metadata"].get("annotations", {}).get("deployment.kubernetes.io/revision") != detail["revision"]:
        return emit("wait", reason="Waiting for matching Deployment and ReplicaSet revisions", **detail)
    owned_pods = [x for x in items if x["kind"] == "Pod"
                  and any(owned(x, rs["metadata"]["uid"]) for rs in sets)]
    active = [x for x in owned_pods if not x["metadata"].get("deletionTimestamp")]
    terminating = [x["metadata"]["name"] for x in owned_pods if x["metadata"].get("deletionTimestamp")]
    if terminating:
        return emit("wait", reason="Waiting for terminating application Pods to disappear", terminating=terminating, **detail)

    service = next((x for x in items if x["kind"] == "Service"
                    and x["metadata"]["name"] == "rollout-demo"), None)
    if not service or service["spec"].get("selector") != {"app": "rollout-demo"} or service["spec"].get("publishNotReadyAddresses", False):
        return emit("unexpected", reason="Unexpected Service selector/readiness configuration", **detail)
    ready_uids = set()
    for obj in items:
        if obj["kind"] != "EndpointSlice" or obj["metadata"].get("labels", {}).get("kubernetes.io/service-name") != "rollout-demo":
            continue
        for endpoint in obj.get("endpoints", []):
            if endpoint.get("conditions", {}).get("ready") is True:
                ready_uids.add(endpoint.get("targetRef", {}).get("uid"))

    if case == "healthy":
        expected_uids = {x["metadata"]["uid"] for x in active}
        counts_ok = all(status.get(key, 0) == 2 for key in
                        ["replicas", "updatedReplicas", "readyReplicas", "availableReplicas"])
        pods_ok = len(active) == 2 and all(owned(p, target["metadata"]["uid"])
                  and condition(p, "Ready").get("status") == "True" for p in active)
        if not counts_ok or not pods_ok or ready_uids != expected_uids:
            return emit("wait", reason="Waiting for two healthy current Pods and matching ready endpoints", **detail)
        return emit("pass", pods=[p["metadata"]["name"] for p in active], **detail)

    bad = [p for p in active if owned(p, target["metadata"]["uid"])]
    good_sets = [x for x in sets if template_without_hash(x["spec"]["template"]) == baseline["spec"]["template"]]
    if len(good_sets) != 1:
        return emit("unexpected", reason="The known-good ReplicaSet is not identifiable", **detail)
    good = [p for p in active if owned(p, good_sets[0]["metadata"]["uid"])]
    if len(bad) != 1 or len(good) != 2 or len(active) != 3:
        return emit("wait", reason="Waiting for two old Pods and one new Pod", **detail)
    if status.get("availableReplicas", 0) != 2 or not all(condition(p, "Ready").get("status") == "True" for p in good):
        return emit("unexpected", reason="The previous revision lost expected availability", **detail)
    pod = bad[0]
    pod_uid = pod["metadata"]["uid"]
    cstatus = next((c for c in pod.get("status", {}).get("containerStatuses", []) if c["name"] == "web"), {})
    waiting = cstatus.get("state", {}).get("waiting", {})
    events = [x for x in items if x["kind"] == "Event" and x.get("involvedObject", {}).get("uid") == pod_uid]
    messages = "\n".join(e.get("message", "") for e in events)
    detail.update({"bad_pod": pod["metadata"]["name"], "bad_pod_uid": pod_uid,
                   "phase": pod.get("status", {}).get("phase"), "ready": condition(pod, "Ready"),
                   "scheduled": condition(pod, "PodScheduled"), "waiting": waiting,
                   "restarts": cstatus.get("restartCount", 0),
                   "old_replicaset": good_sets[0]["metadata"]["name"],
                   "old_pods": [p["metadata"]["name"] for p in good],
                   "pod_events": [{"reason": e.get("reason"), "message": e.get("message"),
                                   "count": e.get("count")} for e in events]})
    if case == "image":
        unrelated = r"toomanyrequests|too many requests|unauthorized|authentication|access denied|i/o timeout|no such host|x509|tls handshake"
        if re.search(unrelated, messages, re.I):
            return emit("unexpected", reason="Image pull shows a registry/network/access issue; do not label it a missing-tag result", **detail)
        fault = (waiting.get("reason") in ["ErrImagePull", "ImagePullBackOff"]
                 and re.search(r"not found|manifest unknown|manifest_unknown", messages, re.I))
    elif case == "readiness":
        fault = (detail["phase"] == "Running" and condition(pod, "Ready").get("status") == "False"
                 and "running" in cstatus.get("state", {}) and cstatus.get("restartCount") == 0
                 and re.search(r"Readiness probe failed[^\n]*404", messages, re.I))
    else:
        scheduled = condition(pod, "PodScheduled")
        fault = (detail["phase"] == "Pending" and scheduled.get("status") == "False"
                 and scheduled.get("reason") == "Unschedulable" and not pod["spec"].get("nodeName")
                 and any(e.get("reason") == "FailedScheduling" and re.search(r"selector|affinity", e.get("message", ""), re.I) for e in events))
    if not fault or ready_uids != {p["metadata"]["uid"] for p in good}:
        return emit("wait", reason="Waiting for the intended fault and old-Pod ready endpoints", **detail)
    if require_deadline and not (condition(dep, "Progressing").get("status") == "False"
                                 and condition(dep, "Progressing").get("reason") == "ProgressDeadlineExceeded"):
        return emit("wait", reason="Fault confirmed; waiting for the controller progress deadline", **detail)
    return emit("pass", **detail)


def main():
    mode = sys.argv[1]
    if mode == "http":
        entries = [json.loads(line) for line in sys.stdin if line.strip()]
        allowed = set(sys.argv[2].split(","))
        samples = [x for x in entries if "sample" in x]
        summaries = [x for x in entries if "result" in x]
        if len(samples) != 10 or len(summaries) != 1 or summaries[0].get("result") != "HTTP_CHECK_PASS":
            return emit("unexpected", reason="Incomplete or failed Service sample")
        served_by = set()
        for sample in samples:
            payload = json.loads(sample.get("body", "{}"))
            if (sample.get("ok") is not True or sample.get("status") != 200
                    or payload.get("version") != "v2" or payload.get("pod") not in allowed):
                return emit("unexpected", reason="Service response did not come from an expected healthy Pod")
            served_by.add(payload["pod"])
        return emit("pass", samples=10, responding_pods=sorted(served_by),
                    scope="Sampled requests only; not a continuous-availability measurement")
    data = json.load(sys.stdin)
    if mode == "uid":
        print(data["metadata"]["uid"])
        return 0
    if mode == "allowed-pods":
        if data.get("state") != "pass":
            return emit("unexpected", reason="Cannot use a non-passing state report for traffic verification")
        print(",".join(data.get("old_pods", data.get("pods", []))))
        return 0
    if mode == "field":
        value = data[sys.argv[2]]
        if not isinstance(value, (str, int)):
            return emit("unexpected", reason="Requested field is not a scalar")
        print(value)
        return 0
    if mode == "nodes":
        if not data["items"]:
            return emit("unexpected", reason="No lab nodes")
        for node in data["items"]:
            if node["metadata"]["name"] != "fcc-rollout-lab-control-plane":
                return emit("unexpected", reason="Unexpected lab node")
            if all(node["metadata"].get("labels", {}).get(k) == v for k, v in PLACEMENT.items()):
                return emit("unexpected", reason="The supposedly unmatched selector matches a node")
            if condition(node, "Ready").get("status") != "True" or any(condition(node, k).get("status") == "True" for k in ["MemoryPressure", "DiskPressure", "PIDPressure"]):
                return emit("unexpected", reason="Node is unready or under resource pressure")
        return emit("pass", reason="Nodes ready; intentional selector has no match")
    return check(data, sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == "deadline")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, StopIteration) as exc:
        raise SystemExit(emit("unexpected", reason=f"Invalid or unsupported evidence: {type(exc).__name__}: {exc}"))
