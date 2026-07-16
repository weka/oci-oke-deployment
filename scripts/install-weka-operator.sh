#!/usr/bin/env bash
set -euo pipefail

# Requires the quay.io robot credentials as env vars. Fetch them from https://get.weka.io.
if [[ -z "${QUAY_USERNAME:-}" || -z "${QUAY_PASSWORD:-}" ]]; then
  echo "ERROR: QUAY_USERNAME and QUAY_PASSWORD must be set." >&2
  echo "Fetch them from https://get.weka.io and export them, e.g.:" >&2
  echo "  export QUAY_USERNAME=... QUAY_PASSWORD=..." >&2
  exit 1
fi

kubectl create namespace weka-operator-system
kubectl create secret docker-registry quay-io-robot-secret \
  --docker-server=quay.io \
  --docker-username=$QUAY_USERNAME \
  --docker-password=$QUAY_PASSWORD \
  --docker-email=$QUAY_USERNAME \
  --namespace=weka-operator-system # operator will be scheduling some containers in own namespace

kubectl create secret docker-registry quay-io-robot-secret \
  --docker-server=quay.io \
  --docker-username=$QUAY_USERNAME \
  --docker-password=$QUAY_PASSWORD \
  --docker-email=$QUAY_USERNAME \
  --namespace=default # wekacluster/wekaclient namespaces, that can be different from operator itself, each namespace needs a copy of secret

helm show crds oci://quay.io/weka.io/helm/weka-operator --version v1.14.1 | kubectl apply --server-side -f -
helm upgrade \
--install weka-operator oci://quay.io/weka.io/helm/weka-operator \
--namespace weka-operator-system \
--create-namespace --version v1.14.1
