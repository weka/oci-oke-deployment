# WEKA layer, installed in the same apply as the cluster (module.oke).
#
# depends_on = [module.oke] on the first k8s resource + the Helm release makes the
# whole WEKA layer wait until the cluster AND its worker node pool AND the
# data-plane security-list fix are done — otherwise the operator pods would have no
# nodes to schedule on. gavinbunney/kubectl resolves the CR kinds at apply time, so
# the CRs tolerate the CRDs having just been installed by the Helm chart.
#
# NOTE: the CR manifests live in crds/ alongside this config so the stack is
# self-contained — a standalone zip (ORM upload / publish / Deploy-to-Oracle-Cloud)
# includes them. 03-wekacluster.yaml is a templatefile whose sizing placeholders are
# filled from the selected tier, so the WEKA layout matches the provisioned hardware.

locals {
  operator_namespace     = "weka-operator-system"
  pull_secret_namespaces = toset([local.operator_namespace, "default"])

  # Values injected into the WekaCluster CR (crds/03-wekacluster.yaml) via
  # templatefile(), so the WEKA software layout matches the provisioned hardware:
  # one compute + one drive container per node, drives/node and protection scheme
  # from the sizing locals in main.tf. driveCores defaults to one core per drive
  # (matches the historical 1:1); revisit for perf tuning on the largest tiers.
  # Non-production keeps 1 drive (block volume) / 1 drive core.
  weka_cr_vars = {
    compute_containers = local.effective_node_count
    drive_containers   = local.effective_node_count
    num_drives         = local.is_production ? local.selected_tier.drives_per_node : 1
    drive_cores        = local.is_production ? local.selected_tier.drives_per_node : 1
    redundancy_level   = local.weka_redundancy
    stripe_width       = local.weka_stripe_width
    hot_spare          = local.weka_hot_spare
  }

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

# OKE reports the cluster ACTIVE before its public API endpoint IP is actually
# routable. The kubernetes/helm providers do NOT retry a connection timeout, so
# a single-apply run can race the endpoint and fail the very first API call with
# "Kubernetes cluster unreachable: ... dial tcp <ip>:6443: i/o timeout". Block
# until the API answers before any provider call. This local-exec runs on the
# same host that will run the providers (the ORM runner, or the laptop for local
# applies), so if it can reach the endpoint, the providers can too. curl is used
# (present on both the OL ORM runner and macOS) with --max-time instead of the
# non-portable `timeout` binary; any HTTP response — even 401 — proves the TCP
# path is up, which is all the race is about.
resource "null_resource" "wait_for_kube_api" {
  depends_on = [module.oke]

  triggers = {
    host = local.cluster_host
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      host="${local.cluster_host}"
      for i in $(seq 1 60); do
        if curl -sk --max-time 6 "$${host}/version" >/dev/null 2>&1; then
          echo "kube API reachable at $${host} (attempt $i)"; exit 0
        fi
        echo "waiting for kube API at $${host} ($i/60)..."; sleep 10
      done
      echo "kube API never became reachable at $${host} after ~10m"; exit 1
    EOT
  }
}

resource "kubernetes_namespace_v1" "operator" {
  metadata {
    name = local.operator_namespace
  }

  # Wait for the full cluster (control plane + node pool + network fix) AND for
  # the API endpoint to actually answer (null_resource.wait_for_kube_api).
  depends_on = [module.oke, null_resource.wait_for_kube_api]
}

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

  # Chart-bundled CRDs install automatically; wait=true blocks until the release
  # is ready before the CRs apply.
  depends_on = [kubernetes_secret_v1.quay, module.oke, null_resource.wait_for_kube_api]

  # Fail loudly (on this always-present resource) if the bundled CR manifests are
  # missing, instead of silently applying zero custom resources via an empty
  # fileset on kubectl_manifest.weka_cr.
  lifecycle {
    precondition {
      condition     = length(fileset("${path.module}/crds", "*.yaml")) > 0
      error_message = "No CR manifests in ${path.module}/crds — the stack zip must bundle crds/*.yaml."
    }
  }
}

resource "kubectl_manifest" "weka_cr" {
  for_each = fileset("${path.module}/crds", "*.yaml")

  # templatefile renders the sizing placeholders in 03-wekacluster.yaml; the other
  # CRs contain no ${...} placeholders, so they pass through unchanged.
  yaml_body = templatefile("${path.module}/crds/${each.value}", local.weka_cr_vars)

  depends_on = [helm_release.weka_operator, kubernetes_secret_v1.quay]
}

# Graceful WEKA teardown, to avoid a destroy DEADLOCK.
#
# The operator creates wekacontainers.weka.weka.io CRs carrying
# weka.weka.io/finalizer. If `destroy` removes the operator (helm_release) before
# those finalizers clear, the operator namespace hangs Terminating forever and the
# whole destroy times out ("context deadline exceeded" on the namespace).
#
# depends_on the operator + CRs, so on DESTROY this resource is torn down FIRST —
# i.e. while the operator is still running. Its destroy-time provisioner deletes
# the top-level WEKA CRs, lets the operator drain its wekacontainers (clearing
# finalizers), then force-clears any stragglers. All connection details are frozen
# into triggers because destroy-time provisioners cannot reference other
# resources/vars. Entirely best-effort: it exits 0 on any problem so it can never
# block teardown, and if kubectl/token are unavailable it simply no-ops.
resource "null_resource" "weka_teardown" {
  depends_on = [helm_release.weka_operator, kubectl_manifest.weka_cr]

  triggers = {
    host      = terraform_data.kube_connect.output.host
    ca        = terraform_data.kube_connect.output.ca
    op_ns     = local.operator_namespace
    token_cmd = "oci ce cluster generate-token --cluster-id ${module.oke.cluster_id} --region ${var.region} ${join(" ", local.k8s_oci_auth_args)}"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set +e
      command -v kubectl >/dev/null 2>&1 || { echo "weka-teardown: kubectl not found; skipping"; exit 0; }
      CA=$(mktemp); printf '%s' "${self.triggers.ca}" | base64 --decode > "$CA" 2>/dev/null
      TOKEN=$(${self.triggers.token_cmd} 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"]["token"])' 2>/dev/null)
      [ -z "$TOKEN" ] && { echo "weka-teardown: no token; skipping graceful drain"; exit 0; }
      kc(){ kubectl --server "${self.triggers.host}" --certificate-authority "$CA" --token "$TOKEN" "$@"; }
      NS="${self.triggers.op_ns}"
      echo "weka-teardown: deleting WEKA CRs and draining wekacontainers"
      kc delete wekacluster,wekaclient --all -A --ignore-not-found --wait=false >/dev/null 2>&1
      for i in $(seq 1 18); do
        n=$(kc get wekacontainers -n "$NS" --no-headers 2>/dev/null | grep -c . )
        [ "$n" = "0" ] && break
        sleep 10
      done
      for c in $(kc get wekacontainers -n "$NS" -o name 2>/dev/null); do
        kc patch -n "$NS" "$c" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
      done
      echo "weka-teardown: drain complete"
      exit 0
    EOT
  }
}
