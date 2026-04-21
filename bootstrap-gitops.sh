#!/usr/bin/env bash
# Bootstrap OpenShift GitOps for this repo: operator → cluster Argo CD instance → app-of-apps.
# Requires cluster-admin and the OpenShift CLI (oc). Run from any directory.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "${SCRIPT_DIR}" && pwd)

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-gitops-operator}"
CLUSTER_GITOPS_NAMESPACE="${CLUSTER_GITOPS_NAMESPACE:-openshift-gitops-cluster}"
ARGOCD_INSTANCE_NAME="${ARGOCD_INSTANCE_NAME:-cluster-argocd}"
CSV_TIMEOUT_SEC="${CSV_TIMEOUT_SEC:-600}"
ARGOCD_TIMEOUT_SEC="${ARGOCD_TIMEOUT_SEC:-600}"

log() {
  printf '[bootstrap-gitops] %s\n' "$*"
}

if command -v oc >/dev/null 2>&1; then
  KUBECTL=(oc)
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
else
  log "error: need oc (OpenShift) or kubectl in PATH" >&2
  exit 1
fi

wait_csv_succeeded() {
  local ns=$1
  local timeout=$2
  local start now
  start=$(date +%s)
  log "waiting for openshift-gitops-operator ClusterServiceVersion in ${ns} (timeout ${timeout}s)"
  while true; do
    now=$(date +%s)
    if (( now - start > timeout )); then
      log "error: timeout waiting for ClusterServiceVersion" >&2
      "${KUBECTL[@]}" get csv -n "${ns}" -o wide || true
      return 1
    fi
    local csv_name phase
    csv_name=$("${KUBECTL[@]}" get csv -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^openshift-gitops-operator' | head -1 || true)
    if [[ -n "${csv_name}" ]]; then
      phase=$("${KUBECTL[@]}" get csv -n "${ns}" "${csv_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "${phase}" == "Succeeded" ]]; then
        log "ClusterServiceVersion ${csv_name} is Succeeded"
        return 0
      fi
      log "ClusterServiceVersion ${csv_name} phase: ${phase:-'(pending)'}"
    else
      log "ClusterServiceVersion for openshift-gitops-operator not found yet"
    fi
    sleep 5
  done
}

wait_argocd_available() {
  local ns=$1
  local name=$2
  local timeout=$3
  local start now
  start=$(date +%s)
  log "waiting for ArgoCD ${name} in ${ns} to reach phase Available (timeout ${timeout}s)"
  while true; do
    now=$(date +%s)
    if (( now - start > timeout )); then
      log "error: timeout waiting for ArgoCD instance" >&2
      "${KUBECTL[@]}" get argocd "${name}" -n "${ns}" -o yaml || true
      return 1
    fi
    if ! "${KUBECTL[@]}" get argocd "${name}" -n "${ns}" >/dev/null 2>&1; then
      log "ArgoCD ${name} not found yet"
      sleep 5
      continue
    fi
    local phase
    phase=$("${KUBECTL[@]}" get argocd "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Available" ]]; then
      log "ArgoCD ${name} is Available"
      return 0
    fi
    log "ArgoCD phase: ${phase:-'(pending)'}"
    sleep 5
  done
}

log "applying OpenShift GitOps operator manifests (${ROOT}/openshift-gitops-operator)"
"${KUBECTL[@]}" apply -k "${ROOT}/openshift-gitops-operator"

wait_csv_succeeded "${OPERATOR_NAMESPACE}" "${CSV_TIMEOUT_SEC}"

log "applying cluster GitOps instance (${ROOT}/openshift-gitops-cluster)"
"${KUBECTL[@]}" apply -k "${ROOT}/openshift-gitops-cluster"

wait_argocd_available "${CLUSTER_GITOPS_NAMESPACE}" "${ARGOCD_INSTANCE_NAME}" "${ARGOCD_TIMEOUT_SEC}"

log "applying app-of-apps (${ROOT}/app-of-apps.yaml)"
"${KUBECTL[@]}" apply -f "${ROOT}/app-of-apps.yaml"

log "done"
