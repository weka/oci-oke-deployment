# WEKA layer: operator + image pull secrets + WEKA custom resources.
#
# Terraform equivalent of scripts/install-weka-operator.sh + `kubectl apply -f crds/`:
#   1. weka-operator-system namespace
#   2. quay.io image pull secret in weka-operator-system (operator's own image) and
#      default (where the WekaCluster/WekaClient pods run) — one copy per namespace
#   3. the weka-operator Helm chart (bundled CRDs install automatically)
#   4. the WekaPolicy/WekaCluster/WekaClient manifests from ../../crds

locals {
  operator_namespace = "weka-operator-system"

  # Each namespace that needs a copy of the quay pull secret. "default" is where the
  # WekaCluster/WekaClient manifests live (namespace: default in crds/).
  pull_secret_namespaces = toset([local.operator_namespace, "default"])

  # docker-registry (dockerconfigjson) secret contents, matching the `kubectl create
  # secret docker-registry` the install script produces.
  dockerconfigjson = jsonencode({
    auths = {
      "quay.io" = {
        username = var.quay_username
        password = var.quay_password
        email    = var.quay_username
        auth     = base64encode("${var.quay_username}:${var.quay_password}")
      }
    }
  })
}

resource "kubernetes_namespace_v1" "operator" {
  metadata {
    name = local.operator_namespace
  }
}

# quay-io-robot-secret in each namespace that pulls WEKA images. "default" exists
# already; the operator namespace is created above (depends_on covers ordering).
resource "kubernetes_secret_v1" "quay" {
  for_each = local.pull_secret_namespaces

  metadata {
    name      = "quay-io-robot-secret"
    namespace = each.value
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = local.dockerconfigjson
  }

  depends_on = [kubernetes_namespace_v1.operator]
}

resource "helm_release" "weka_operator" {
  name       = "weka-operator"
  repository = "oci://quay.io/weka.io/helm"
  chart      = "weka-operator"
  version    = var.operator_version
  namespace  = kubernetes_namespace_v1.operator.metadata[0].name

  # Chart-bundled CRDs are installed automatically on first install (skip_crds
  # defaults to false), replacing the script's `helm show crds | kubectl apply`.
  # wait=true (default) blocks until the release is ready before the CRs apply.
  depends_on = [kubernetes_secret_v1.quay]
}

# WekaPolicy (sign-drives, ensure-nics) + WekaCluster + WekaClient. Reuses the
# existing manifests verbatim. gavinbunney/kubectl resolves the CRD kinds at apply
# time (not plan), so these tolerate the CRDs having just been installed by Helm.
resource "kubectl_manifest" "weka_cr" {
  for_each = fileset("${path.module}/../../crds", "*.yaml")

  yaml_body = file("${path.module}/../../crds/${each.value}")

  depends_on = [helm_release.weka_operator, kubernetes_secret_v1.quay]
}
