# WEKA layer, installed in the same apply as the cluster (module.oke).
#
# depends_on = [module.oke] on the first k8s resource + the Helm release makes the
# whole WEKA layer wait until the cluster AND its worker node pool AND the
# data-plane security-list fix are done — otherwise the operator pods would have no
# nodes to schedule on. gavinbunney/kubectl resolves the CR kinds at apply time, so
# the CRs tolerate the CRDs having just been installed by kubectl_manifest.weka_crd.
#
# NOTE: the CR manifests live in crds/ alongside this config so the stack is
# self-contained — a standalone zip (ORM upload / publish / Deploy-to-Oracle-Cloud)
# includes them. 03-wekacluster.yaml is a templatefile whose sizing placeholders are
# filled from the selected tier, so the WEKA layout matches the provisioned hardware.

locals {
  operator_namespace     = "weka-operator-system"
  pull_secret_namespaces = toset([local.operator_namespace, "default"])

  # Null overrides are dropped, so an unset field never reaches the CR and the
  # empty default map omits the dynamicTemplate block altogether (the template
  # guards on length). See variables.tf for what that leaves to the operator.
  weka_dynamic_template = {
    for field, value in {
      computeContainers = var.weka_compute_containers
      computeCores      = var.weka_compute_cores
      driveContainers   = var.weka_drive_containers
      driveCores        = var.weka_drive_cores
      numDrives         = var.weka_num_drives
    } : field => value if value != null
  }

  # Values injected into the WekaCluster CR (crds/03-wekacluster.yaml) via
  # templatefile(). The protection scheme stays Terraform-derived (it follows from
  # the node count, which the stack fixes) while the container/core layout is left
  # to the operator unless explicitly overridden.
  weka_cr_vars = {
    dynamic_template = local.weka_dynamic_template
    redundancy_level = local.weka_redundancy
    stripe_width     = local.weka_stripe_width
    hot_spare        = local.weka_hot_spare

    # Data plane. An EMPTY list omits the whole network block from the CR (both
    # templates guard on it), which is the non-bare-metal default.
    network_subnets = local.weka_network_subnets

    traces_free_space_gb            = local.weka_traces_free_space_gb
    traces_max_capacity_per_io_node = local.weka_traces_max_capacity_per_io_node
  }

  # WEKA traces live under /opt/k8s-weka on the boot volume, which on the bare-metal
  # flavor is the only storage not handed to WEKA as a drive (sign-drives takes
  # all-not-root). Two things have to hold at once:
  #
  #   maxCapacityPerIoNode is multiplied by (cores + 1) PER CONTAINER, so the
  #   operator default of 10 GB becomes ~70 GB per container on a 128-OCPU node —
  #   two containers then exceed a 200 GB boot volume on their own.
  #
  #   ensureFreeSpace is an absolute GB floor, while kubelet evicts at
  #   imagefs.available < 15%. A fixed floor therefore sits BELOW the eviction line
  #   and sinks further as the volume grows, so WEKA fills the disk until kubelet
  #   declares DiskPressure and evicts every pod on the node. Deriving it from the
  #   volume keeps the floor above the threshold at any size.
  weka_traces_free_space_gb            = ceil(var.node_boot_volume_gb * 0.25)
  weka_traces_max_capacity_per_io_node = 2

  # ---------------------------------------------------------------------------
  # Data-plane path: bare metal vs VM.
  #
  # BARE METAL: the NICs are already attached, so WEKA selects them BY SUBNET and
  # ensure-nics is NOT applied. ensure-nics asks the Core API to create secondary
  # VNICs, which on BM fails with "authorization error ... operation: GetVnic" and
  # crash-loops every pod. That is not a missing IAM policy to add: the
  # secondary-VNIC mechanism is simply the wrong one here — Weka's own OCI module
  # skips it too ("Bare metal instance detected ... NICs pre-attached").
  #
  # Selecting by subnet rather than by interface NAME is deliberate. An ethDevice
  # ("ens300np0") is a systemd predictable name derived from PCI topology, so it is
  # shape-specific, unverifiable at plan time (the OCI VNIC API exposes MAC,
  # nic-index and subnet — never the guest device name), and silently wrong the
  # moment the shape changes. The data-path SUBNET, by contrast, is our own
  # configuration: WEKA matches the NICs holding an address in it, per node.
  #
  # VM (non-production instance pools): no selectors, ensure-nics still applied.
  # VMs have no pre-attached data NICs, so secondary VNICs remain the path. NOT
  # retested since the BM change — if dev fails the same way, set is_bare_metal
  # and create_ensure_nics_policy explicitly.
  #
  # NOTE: weka_data_network.tf exists only to give the NSG-less ensure-nics VNICs
  # security coverage. With ensure-nics off the data path rides the primary VNIC,
  # which IS an NSG member and already covered — so that workaround is probably
  # redundant on bare metal now. Left in place pending confirmation; it is harmless
  # if unnecessary.
  # ---------------------------------------------------------------------------
  # Derived, not defaulted to a literal true: BOTH zips are built from this same
  # Terraform, and the dev zip is VM.Standard.E5.Flex. A blanket `true` would emit
  # a bare-metal network block for VM workers.
  is_bare_metal = var.is_bare_metal != null ? var.is_bare_metal : local.is_production

  # The data-path subnet the workers sit in. Read from the subnet the module built
  # (or reused), so it is correct for create_vcn true AND false, and needs no
  # hardcoded CIDR. Empty on VMs, which omits the network block entirely.
  weka_network_subnets = local.is_bare_metal ? [data.oci_core_subnet.workers[0].cidr_block] : []

  ensure_nics_policy = coalesce(var.create_ensure_nics_policy, !local.is_bare_metal)

  # Same filenames as the fileset they replace, so for_each keys (and therefore
  # resource addresses) are unchanged — dropping ensure-nics DELETES that one CR
  # instead of recreating the others.
  weka_cr_files = toset([
    for f in fileset("${path.module}/crds", "*.yaml") : f
    if f != "02-ensure-nics-policy.yaml" || local.ensure_nics_policy
  ])

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
# The worker (data-path) subnet, for the WEKA network selectors above. Keyed on the
# module's own output so it resolves whether the VCN was created or reused. Only read
# on bare metal — VMs emit no selectors and must not depend on this.
data "oci_core_subnet" "workers" {
  count     = local.is_bare_metal ? 1 : 0
  subnet_id = module.oke.worker_subnet_id
}

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

# Apply the selected chart version's CRDs ourselves, because Helm will not.
#
# Helm 3 applies a chart's crds/ directory on INSTALL ONLY — `helm upgrade` never
# updates it. The weka-operator chart ships its CRDs there, so raising
# operator_version on an existing stack upgrades the operator Deployment against
# the schema the cluster was FIRST built with, and nothing fails loudly: the API
# server silently prunes the fields the new operator sets, and the damage surfaces
# nowhere near the Helm release.
#
# helm_template only renders — it needs no cluster, and reads at plan time, so a
# bad operator_version or bad quay credentials fail the PLAN rather than an apply
# that has already built a cluster. It must use the unconfigured helm.render
# alias; providers.tf explains why.
data "helm_template" "weka_operator" {
  provider = helm.render

  name                = "weka-operator"
  chart               = "weka-operator"
  repository          = "oci://quay.io/weka.io/helm"
  version             = var.operator_version
  namespace           = local.operator_namespace
  repository_username = var.quay_username
  repository_password = var.quay_password
  include_crds        = true
}

# Keyed by CRD name, so the resource addresses stay stable and readable as the
# chart's CRD set changes. Server-side apply with force_conflicts because on an
# upgrade these fields are owned by Helm's field manager from the original install.
resource "kubectl_manifest" "weka_crd" {
  for_each = { for c in data.helm_template.weka_operator.crds : yamldecode(c).metadata.name => c }

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  # Never delete these. Deleting a CRD cascades to every CR of that kind, so a
  # destroy would race null_resource.weka_teardown's finalizer drain for the right
  # to remove the wekacontainers — and losing that race is the namespace-stuck-
  # Terminating deadlock the teardown exists to prevent. The cluster is destroyed
  # in the same run anyway, which takes the CRDs with it.
  apply_only = true

  depends_on = [module.oke, null_resource.wait_for_kube_api]
}

resource "helm_release" "weka_operator" {
  name       = "weka-operator"
  repository = "oci://quay.io/weka.io/helm"
  chart      = "weka-operator"
  version    = var.operator_version
  namespace  = kubernetes_namespace_v1.operator.metadata[0].name

  set = [{
    name  = "cleanupRemovedNodes"
    value = "true"
    }, {
    # Global default for the operator's pod execs; the chart ships 5m. Raised
    # because a timed-out exec surfaces only as "Exec failed to stream: context
    # deadline exceeded", leaving the containers in STEM mode while the step
    # retries. Must stay under the chart's reconcileTimeout (30m), which bounds
    # the whole reconcile and is not pinned here.
    name  = "kubeExecTimeout"
    value = "20m"
  }]

  # wait=true blocks until the release is ready before the CRs apply.
  depends_on = [kubernetes_secret_v1.quay, module.oke, null_resource.wait_for_kube_api, kubectl_manifest.weka_crd]

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
  for_each = local.weka_cr_files

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
