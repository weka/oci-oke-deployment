#!/usr/bin/env bash
#
# Follow a deployed stack all the way to a usable WEKA cluster.
#
# `terraform apply` finishing means almost nothing here: kubectl_manifest.weka_cr
# sets no wait, so the apply completes as soon as the API server ACCEPTS the CRs,
# with .status.status still "Init". helm_release waits only on the operator's own
# Deployment. Everything from there to a working filesystem — nodes joining, the
# policies running, drive and compute containers forming a cluster — happens
# after Terraform has already reported success.
#
# Standalone: needs only KUBECONFIG. Exits 0 only when every selected phase is
# ready; on timeout it dumps diagnostics and exits 1.
#
# Adapted from the provision-oke-cluster skill's wait-ready.sh (cloud-plugins),
# which lives in another repo and so cannot be sourced.
#
# No `set -e` on purpose: the phase predicates below return non-zero to mean
# "not ready yet", and a transient kubectl failure mid-poll must not kill a
# 40-minute watch.
set -uo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig path}"

# CR names come from crds/, which hardcodes dev / client-dev regardless of the
# OKE cluster name or flavor.
: "${WEKA_CLUSTER_NAME:=dev}"
: "${WEKA_CLIENT_NAME:=client-dev}"
: "${CLUSTER_NS:=default}"
: "${OPERATOR_NS:=weka-operator-system}"

# Budget for ALL phases combined, not per phase — a per-phase timeout multiplies
# into hours once one phase stalls.
: "${READY_TIMEOUT:=2400}"
: "${READY_INTERVAL:=15}"

# Worker count to expect. 0 = accept any node, which defeats the point of this
# phase; reserve-deploy.sh always sets it.
: "${EXPECTED_NODES:=0}"

# Terminal values, all read from .status.status. These differ per kind and the
# CRD publishes no roll-up "Ready" condition, so there is no generic predicate:
#   WekaPolicy    Running      -> Done
#   WekaCluster   Init -> WaitForDrives -> StartingIO -> Ready
#   WekaClient    Init         -> Running   (Running, NOT Ready)
#   WekaContainer ...          -> Running
# Not environment-overridable: these are CRD facts, and letting a caller
# redefine "ready" turns a stuck wait into a green one.
POLICY_OK=Done
CLUSTER_OK=Ready
CLIENT_OK=Running
CONTAINER_OK='^(Running|Completed)$'

# Only states that never recover. Degraded/Unhealthy are deliberately absent:
# both show up transiently while a cluster forms, and a false early exit costs
# more than waiting out the timeout.
CONTAINER_FATAL='^Error$'
POLICY_FATAL='^Failed$'

fatal_seen=""
now() { date +%s; }
DEADLINE=$(( $(now) + READY_TIMEOUT ))

hms() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

poll() {
  local desc="$1" fn="$2" started
  started=$(now)
  echo
  echo ">> $desc"
  while true; do
    if "$fn"; then
      echo "   OK after $(hms $(( $(now) - started )))"
      return 0
    fi
    if [ -n "$fatal_seen" ]; then
      echo "   FATAL: $fatal_seen — this state does not recover on its own."
      return 1
    fi
    if [ "$(now)" -ge "$DEADLINE" ]; then
      echo "   TIMEOUT after $(hms $(( $(now) - started ))) — overall budget of $(hms "$READY_TIMEOUT") exhausted"
      return 1
    fi
    sleep "$READY_INTERVAL"
  done
}

# --- phases ----------------------------------------------------------------

nodes_ready() {
  local rows counts
  rows=$(kubectl get nodes --no-headers 2>/dev/null)
  counts=$(awk 'NF {t++} $2 == "Ready" {r++} END {print r+0, t+0}' <<<"$rows")
  echo "   nodes Ready: ${counts% *}/$EXPECTED_NODES (registered: ${counts#* })"
  [ "${counts% *}" -ge "$EXPECTED_NODES" ] && [ "${counts% *}" -gt 0 ]
}

# readyReplicas == replicas rather than `kubectl wait --for=condition=Available`:
# the wait blocks for its whole timeout on every tick, which silently spends
# minutes of the shared budget, and these are the numbers it would check anyway.
# readyReplicas renders <none> at zero.
operator_ready() {
  local rows
  rows=$(kubectl -n "$OPERATOR_NS" get deploy \
    -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas \
    --no-headers 2>/dev/null)
  [ -n "$rows" ] || { echo "   no deployments in $OPERATOR_NS yet"; return 1; }
  sed 's/^/     /' <<<"$rows"
  ! awk '$2 != $3 {bad=1} END {exit !bad}' <<<"$rows"
}

# Which policies exist depends on the flavor: ensure-nics-policy is applied only
# when the workers are VMs (local.ensure_nics_policy in weka.tf), so bare metal
# has one policy and non-production has two. Enumerate rather than assume.
policies_done() {
  local rows bad
  rows=$(kubectl get wekapolicy -n "$CLUSTER_NS" \
    -o custom-columns=NAME:.metadata.name,STATUS:.status.status --no-headers 2>/dev/null)
  [ -n "$rows" ] || { echo "   no wekapolicy objects yet"; return 1; }
  printf '%s\n' "$rows" | sed 's/^/     /'
  bad=$(printf '%s\n' "$rows" | awk -v re="$POLICY_FATAL" '$2 ~ re {print $1}')
  [ -n "$bad" ] && { fatal_seen="wekapolicy $POLICY_FATAL: $(tr '\n' ' ' <<<"$bad")"; return 1; }
  ! printf '%s\n' "$rows" | awk -v ok="$POLICY_OK" '$2 != ok' | grep -q .
}

# $3 is the container's owning cluster; adhoc rows are one-shot helper containers
# that legitimately come and go and must not gate readiness.
containers_running() {
  local rows real bad
  rows=$(kubectl get wekacontainers -n "$CLUSTER_NS" --no-headers 2>/dev/null)
  [ -n "$rows" ] || { echo "   no wekacontainers yet (operator has not built the cluster)"; return 1; }
  awk '{printf "     %-44s %s\n", $1, $2}' <<<"$rows"
  real=$(printf '%s\n' "$rows" | awk 'NF && $3 !~ /adhoc/ {print $2}')
  [ -n "$real" ] || return 1
  bad=$(printf '%s\n' "$real" | grep -E "$CONTAINER_FATAL")
  [ -n "$bad" ] && { fatal_seen="wekacontainer matching $CONTAINER_FATAL"; return 1; }
  ! printf '%s\n' "$real" | grep -vqE "$CONTAINER_OK"
}

cluster_ready() {
  local json line
  json=$(kubectl get wekacluster "$WEKA_CLUSTER_NAME" -n "$CLUSTER_NS" -o json 2>/dev/null)
  [ -n "$json" ] || { echo "   wekacluster/$WEKA_CLUSTER_NAME not created yet"; return 1; }
  line=$(jq -r '"\(.status.status // "-") | drives \(.status.printer.drives // "-")
                 dct \(.status.printer.driveContainers // "-")
                 cct \(.status.printer.computeContainers // "-") (active/created/desired)"
               | gsub("\\s+"; " ")' <<<"$json")
  echo "   wekacluster/$WEKA_CLUSTER_NAME: $line"
  [ "${line%% *}" = "$CLUSTER_OK" ]
}

client_ready() {
  local status
  status=$(kubectl get wekaclient "$WEKA_CLIENT_NAME" -n "$CLUSTER_NS" \
    -o jsonpath='{.status.status}' 2>/dev/null)
  echo "   wekaclient/$WEKA_CLIENT_NAME: ${status:--}"
  [ "$status" = "$CLIENT_OK" ]
}

diagnostics() {
  echo
  echo "===== DIAGNOSTICS ====="
  echo "--- nodes ---";            kubectl get nodes -o wide 2>&1 | sed 's/^/  /'
  echo "--- weka CRs ---";         kubectl get wekacluster,wekaclient,wekapolicy -A -o wide 2>&1 | sed 's/^/  /'
  echo "--- weka containers ---";  kubectl get wekacontainers -A 2>&1 | sed 's/^/  /'
  echo "--- operator pods ---";    kubectl -n "$OPERATOR_NS" get pods 2>&1 | sed 's/^/  /'
  echo "--- pending pods ---";     kubectl get pods -A --field-selector=status.phase=Pending 2>&1 | sed 's/^/  /'
  echo "--- recent events ---";    kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -25 | sed 's/^/  /'
  echo
  echo "See TROUBLESHOOTING.md — 0 nodes is a worker bootstrap problem (§1),"
  echo "a cluster stuck in Init with no drives is usually the data-path seclist."
}

# --- run -------------------------------------------------------------------

echo "waiting for WEKA readiness (budget $(hms "$READY_TIMEOUT"), poll ${READY_INTERVAL}s)"
echo "  operator ns: $OPERATOR_NS | CR ns: $CLUSTER_NS | cluster: $WEKA_CLUSTER_NAME | client: $WEKA_CLIENT_NAME"

phase() { poll "$1" "$2" || { diagnostics; exit 1; }; }

started=$(now)
phase "worker nodes Ready (expect $EXPECTED_NODES)"   nodes_ready
phase "operator deployments Available"                operator_ready
phase "WekaPolicy objects $POLICY_OK"                 policies_done
phase "weka containers Running"                       containers_running
phase "wekacluster/$WEKA_CLUSTER_NAME $CLUSTER_OK"    cluster_ready
phase "wekaclient/$WEKA_CLIENT_NAME $CLIENT_OK"       client_ready

echo
echo "WEKA is ready (total $(hms $(( $(now) - started ))))"
kubectl get wekacluster,wekaclient -n "$CLUSTER_NS" 2>&1 | sed 's/^/  /'
