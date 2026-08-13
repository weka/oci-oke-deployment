# Inputs for the OKE cluster. Sizing/topology have sensible defaults; the
# account-specific values (compartment_ocid, tenancy_ocid) are required — set them
# in terraform.tfvars (see terraform.tfvars.example) or via -var / TF_VAR_*.

# ---------------------------------------------------------------------------
# Auth / tenancy
# ---------------------------------------------------------------------------
variable "config_file_profile" {
  description = <<-EOT
    Profile in ~/.oci/config to authenticate with for LOCAL / Cloud Shell runs
    (e.g. "DEFAULT"). Leave null when running in OCI Resource Manager: ORM injects
    resource-principal credentials automatically, and a null profile also switches
    the weka-data security-list attach (weka_data_network.tf) to
    `--auth resource_principal` instead of `--profile`.
  EOT
  type        = string
  default     = null
}

variable "oci_cli_auth" {
  description = <<-EOT
    Auth mode for the out-of-band `oci` CLI call (the worker-subnet security-list
    attach in weka_data_network.tf), passed as `--auth <mode>`. Only used when
    config_file_profile is null:
      - ""  (empty, default) — no --auth flag; the environment is pre-authenticated.
        Correct for BOTH the OCI Resource Manager runner (delegation/OBO token) and
        OCI Cloud Shell (session token) — verified: the ORM runner has the oci CLI
        and works with no flag, but NOT with --auth resource_principal.
      - "instance_principal"  — an operator/compute host in a dynamic group.
      - "resource_principal"  — only where OCI_RESOURCE_PRINCIPAL_* is set (NOT the ORM runner).
    Ignored when config_file_profile is set (local runs use --profile).
  EOT
  type        = string
  default     = ""
}

variable "region" {
  # No default ON PURPOSE. In the ORM console `region` is a reserved Resource
  # Manager variable auto-populated with the region the stack runs in, so leaving
  # it unset makes the stack deploy WHERE IT IS CREATED instead of silently
  # defaulting to some other region. For local/CLI runs, set it in your tfvars.
  description = "OCI region for the OKE cluster (e.g. us-phoenix-1, us-ashburn-1, eu-frankfurt-1). ORM auto-populates this with the stack's region; set it in tfvars for local runs."
  type        = string
}

variable "home_region" {
  description = "Tenancy home region (identity ops). Defaults to var.region when null."
  type        = string
  default     = null
}

variable "tenancy_ocid" {
  description = "Tenancy OCID. OCI Resource Manager auto-populates this reserved variable; for local/CLI runs set it in terraform.tfvars."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment for all resources. Auto-populated by OCI Resource Manager (reserved variable); defaults to the compartment the stack is created in."
  type        = string
}

# ---------------------------------------------------------------------------
# SSH — provide the key as CONTENT (ssh_public_key) or as a file PATH
# (ssh_public_key_path). The module prefers content when set and only reads the
# path otherwise, so use ssh_public_key in the ORM runner (no local files there)
# and ssh_public_key_path for local convenience.
# ---------------------------------------------------------------------------
variable "ssh_public_key" {
  description = "SSH public key CONTENT injected into worker nodes (use in the ORM runner). Takes precedence over ssh_public_key_path when set."
  type        = string
  default     = null
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file injected into worker nodes (local/Cloud Shell). Used only when ssh_public_key is null. Leave null in the ORM runner (no local files there); set a path for local runs, e.g. \"~/.ssh/id_rsa.pub\"."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the OKE cluster."
  type        = string
  default     = "weka-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the OKE control plane and node pool."
  type        = string
  default     = "v1.36.1"
}

variable "cluster_type" {
  description = "OKE cluster type: basic or enhanced."
  type        = string
  default     = "basic"
}

variable "cni_type" {
  description = "Pod networking CNI: flannel or npn."
  type        = string
  default     = "flannel"
}

variable "control_plane_is_public" {
  description = "Give the Kubernetes API endpoint a public IP so kubectl works directly from your laptop."
  type        = bool
  default     = true
}

variable "control_plane_allowed_cidrs" {
  description = "CIDRs allowed to reach the public control plane. The default is open; tighten to your IP for anything real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# Flavor — the single dial that determines drive topology and pool mode.
#
# production:     BM.DenseIO.E5.128, node-pool (managed OKE).
#                 Local NVMe (12 x 6.8 TB/node) is discovered as weka.io/drives —
#                 no block volume. OCPU/memory are fixed by the bare-metal shape;
#                 node count comes from var.production_tier.
#                 Use for real WEKA testing with best drive performance.
#                 DenseIO quota is limited; check AD capacity before provisioning.
#
# non-production: VM.Standard.E5.Flex, instance-pool (self-managed).
#                 No local NVMe; WEKA drives come from an attached block volume
#                 (paravirtualized, size = var.data_volume_gb, default 100 GB).
#                 Standard shapes are widely available. Good for operator/CSI
#                 integration testing where IO performance is not the focus.
#
# Shape, OCPU, and memory are fully determined by the flavor (see locals in
# main.tf). node_count, node_boot_volume_gb, and node_hugepages remain as
# explicit overrides because they are independent of drive topology.
# ---------------------------------------------------------------------------
variable "flavor" {
  description = <<-EOT
    Cluster flavor — controls drive topology, node shape, and pool mode. It is
    hidden from the ORM form in both zips, so it is effectively an internal
    constant. The default below is what the PRODUCTION zip uses; the release
    workflow rewrites it to non-production when building the dev zip. Do not
    move that pin into schema-dev.yaml — ORM does not submit hidden variables,
    so a schema default silently never reaches Terraform.
      "production": DenseIO shape from production_tier, node-pool (managed OKE),
        local NVMe as WEKA drives. Best drive performance. DenseIO quota is limited
        — the capacity.tf preflight checks AD capacity before provisioning.
      "non-production": VM.Standard.E5.Flex, instance-pool, paravirtualized block
        volume as WEKA drives. Standard shapes have abundant quota; ideal for
        operator/CSI integration testing where raw IO throughput is not the goal.
  EOT
  type        = string
  default     = "production"
  validation {
    condition     = contains(["production", "non-production"], var.flavor)
    error_message = "flavor must be one of: production, non-production"
  }
}

variable "data_volume_gb" {
  description = "Size (GB) of the paravirtualized block-volume data disk attached per worker node in non-production flavor. Ignored for production (local NVMe is used instead). Minimum 50, default 100."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------
# Production sizing — a single fixed choice that pins worker SHAPE and node COUNT.
#
# The allowed values NAME the usable capacity and the instance type, because ORM
# renders enum values verbatim in the dropdown (no separate label/value in schema
# 1.1.0). Each value maps (main.tf local.tier_specs) to shape + OCPU + drives/node
# + count. Shape AND count are frozen after first apply by guard.tf (a resize would
# destroy nodes). Only used when flavor = production; non-production sizing uses
# var.node_count directly.
#
# BM.DenseIO.E5.128 (128 core, 12 x 6.8 TB = 81.6 TB raw/node) is the only
# supported production shape, so capacity scales by node count alone:
#
#   367 TB usable   8   x BM.DenseIO.E5.128   single prot. 5+2+1
#   661 TB usable   12  x BM.DenseIO.E5.128   single prot. 9+2+1
#   955 TB usable   16  x BM.DenseIO.E5.128   single prot. 13+2+1
#   1.2 PB usable   21  x BM.DenseIO.E5.128   double prot. 16+4+1
#   2 PB usable     35  x BM.DenseIO.E5.128   double prot. 16+4+1
#   3 PB usable     52  x BM.DenseIO.E5.128   (+17 nodes ~= +1 PB usable from here)
#   4 PB usable     69  x BM.DenseIO.E5.128
#   5 PB usable     86  x BM.DenseIO.E5.128
#   6 PB usable     103 x BM.DenseIO.E5.128
#   7 PB usable     120 x BM.DenseIO.E5.128
#   8 PB usable     137 x BM.DenseIO.E5.128
#   9 PB usable     154 x BM.DenseIO.E5.128
#   10 PB usable    171 x BM.DenseIO.E5.128
# ---------------------------------------------------------------------------
variable "production_tier" {
  description = <<-EOT
    Production cluster capacity (production flavor only). Every option is a
    bare-metal BM.DenseIO.E5.128 cluster (12 x 6.8 TB local NVMe per node); the
    value fixes the node count, which is frozen after first apply. 367/661/955 TB
    usable are 8/12/16-node clusters with single protection (x+2+1); 1.2 PB and up
    are 21-node-and-larger clusters with double protection (16+4+1), scaling to
    10 PB usable at 171 nodes. For more capacity, deploy a separate cluster.
    Keep this list in sync with local.tier_specs (main.tf) and the schema enums.
  EOT
  type        = string
  default     = "367 TB usable - 8 x BM.DenseIO.E5.128 (12 NVMe)"
  validation {
    condition = contains([
      "367 TB usable - 8 x BM.DenseIO.E5.128 (12 NVMe)",
      "661 TB usable - 12 x BM.DenseIO.E5.128 (12 NVMe)",
      "955 TB usable - 16 x BM.DenseIO.E5.128 (12 NVMe)",
      "1.2 PB usable - 21 x BM.DenseIO.E5.128 (12 NVMe)",
      "2 PB usable - 35 x BM.DenseIO.E5.128 (12 NVMe)",
      "3 PB usable - 52 x BM.DenseIO.E5.128 (12 NVMe)",
      "4 PB usable - 69 x BM.DenseIO.E5.128 (12 NVMe)",
      "5 PB usable - 86 x BM.DenseIO.E5.128 (12 NVMe)",
      "6 PB usable - 103 x BM.DenseIO.E5.128 (12 NVMe)",
      "7 PB usable - 120 x BM.DenseIO.E5.128 (12 NVMe)",
      "8 PB usable - 137 x BM.DenseIO.E5.128 (12 NVMe)",
      "9 PB usable - 154 x BM.DenseIO.E5.128 (12 NVMe)",
      "10 PB usable - 171 x BM.DenseIO.E5.128 (12 NVMe)",
    ], var.production_tier)
    error_message = "production_tier must be one of the listed capacity options, e.g. \"367 TB usable - 8 x BM.DenseIO.E5.128 (12 NVMe)\" — see local.tier_specs in main.tf."
  }
}

# ---------------------------------------------------------------------------
# Advanced sizing overrides (optional).
#
# When null (default), each value is derived from var.flavor (see locals in
# main.tf). Set any of these to override the flavor default — for example,
# node_ocpus = 16 to get a 2-NVMe DenseIO node under the production flavor.
#
# NOTE: worker_mode (node-pool vs instance-pool) remains tied to flavor and
# cannot be overridden here. Choosing a shape that mismatches the flavor-driven
# pool mode (e.g. a DenseIO shape with non-production/instance-pool) is a
# documented foot-gun — it is not prevented but also not recommended.
# ---------------------------------------------------------------------------
variable "node_shape" {
  description = "Optional override for the worker node shape. When null, derived from production_tier (production) or VM.Standard.E5.Flex (non-production)."
  type        = string
  default     = null
}

variable "node_ocpus" {
  description = "Optional override for OCPUs per worker node. When null, derived from production_tier (production) or 10 (non-production). Ignored for the bare-metal options (BM shapes have fixed OCPU)."
  type        = number
  default     = null
}

variable "node_memory_gb" {
  description = "Optional override for memory (GB) per worker node. When null, derived from production_tier (production, 12 GB/OCPU) or 80 (non-production). Ignored for the bare-metal options (BM shapes have fixed memory)."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Worker node pool (converged WEKA nodes).
#
# node_count, node_boot_volume_gb, and node_hugepages remain explicit because
# they are independent of flavor. Shape, OCPU, and memory are derived from
# var.flavor by default but can be overridden with the variables above.
# ---------------------------------------------------------------------------
variable "node_pool_name" {
  description = "Name of the worker node pool."
  type        = string
  default     = "converged"
}

variable "node_count" {
  description = "Number of worker nodes (non-production flavor). Ignored for production, where the count is fixed by production_tier. Minimum 6."
  type        = number
  default     = 6
  validation {
    condition     = var.node_count >= 6
    error_message = "node_count must be at least 6 (WEKA needs enough nodes to form a cluster)."
  }
}

variable "skip_capacity_preflight" {
  description = <<-EOT
    Skip the production NVMe host-capacity preflight (see capacity.tf). The
    preflight hard-fails early when no availability domain has free DenseIO
    capacity for the worker shape; set this true to bypass it — e.g. if the
    capacity report is wrong for your tenancy, or your tenancy lacks the
    "inspect compute-capacity-reports" permission. Ignored for non-production.
  EOT
  type        = bool
  default     = false
}

variable "worker_placement_ads" {
  description = <<-EOT
    Comma-separated availability-domain NUMBERS to place worker nodes in (e.g. "1,2").
    Empty (default) uses all ADs. Use it to steer the DenseIO node pool away from ADs
    that are out of host capacity (check with `oci compute compute-capacity-report`).
  EOT
  type        = string
  default     = ""
}

variable "node_boot_volume_gb" {
  description = "Boot volume size (GB) per worker node."
  type        = number
  default     = 200
}

variable "node_hugepages" {
  description = <<-EOT
    Optional override for the number of 2Mi hugepages reserved per worker node
    (WEKA DPDK requirement). When null (default), it is derived in main.tf: 1000
    pages per OCPU for production (8000 ~= 15.6 GB at 8 OCPU, scaling up so larger
    tiers keep headroom) and 8000 for non-production. The operator sizes each WEKA
    container's hugepages itself; the node only needs enough total reserved.
    Written to /etc/sysctl.d/99-weka-hugepages.conf on each worker, so the
    reservation survives a reboot.
  EOT
  type        = number
  default     = null
}

variable "worker_image_os_version" {
  description = "OKE worker image OS version. Oracle Linux 8 avoids the broken Ubuntu-OKE python3-venv that blocks the node init."
  type        = string
  default     = "8"
}

# ---------------------------------------------------------------------------
# Networking
#   Default: module builds a fresh VCN (create_vcn = true).
#   To reuse an existing VCN instead, set create_vcn = false and provide
#   vcn_id + subnets + nsgs (see terraform.tfvars.example).
# ---------------------------------------------------------------------------
variable "create_vcn" {
  description = "Create a fresh VCN (true) or reuse an existing one via vcn_id/subnets/nsgs (false)."
  type        = bool
  default     = true
}

variable "vcn_cidrs" {
  description = "IPv4 CIDR blocks for a freshly created VCN."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "vcn_id" {
  description = "Existing VCN OCID to reuse. Only used when create_vcn = false."
  type        = string
  default     = null
}

variable "subnets" {
  description = "Override the module subnets map. null => module defaults (fresh subnets). When reusing existing network, set { cp = { id = ... }, workers = { id = ... }, pub_lb = { id = ... } }."
  type        = any
  default     = null
}

variable "nsgs" {
  description = "Override the module NSG map. null => module defaults. When reusing existing network, set e.g. { cp = { id = ... }, workers = { id = ... } }."
  type        = any
  default     = null
}

# ---------------------------------------------------------------------------
# WEKA layer (operator + custom resources) — this stack installs it in the SAME
# apply as the cluster. quay.io robot creds from https://get.weka.io.
# ---------------------------------------------------------------------------
variable "quay_username" {
  description = "quay.io robot username (image pull secret)."
  type        = string
  sensitive   = true
}

variable "quay_password" {
  description = "quay.io robot password (image pull secret)."
  type        = string
  sensitive   = true
}

variable "operator_version" {
  description = "WEKA operator Helm chart version."
  type        = string
  default     = "v1.14.1"
}

# ---------------------------------------------------------------------------
# WEKA data-plane networking.
#
# On BARE METAL the data NICs are already attached, so WEKA selects them BY SUBNET
# (WekaCluster/WekaClient spec.network.selectors) and must NOT go through
# ensure-nics, which asks the Core API to create secondary VNICs: that path fails
# with a GetVnic authorization error and is the wrong mechanism on BM regardless —
# granting the permission would only let it succeed at something unnecessary.
#
# The subnet comes from the worker subnet the stack itself builds or reuses, so
# there is nothing shape-specific to configure and nothing to detect on a node.
# ---------------------------------------------------------------------------

variable "is_bare_metal" {
  description = <<-EOT
    Whether the worker nodes are bare metal. Bare metal selects data NICs by subnet
    and skips the ensure-nics policy; VMs do the opposite. When null (default), it is
    derived from the flavor: true for production (BM.DenseIO shapes) and false for
    non-production (VM.Standard.E5.Flex). Set it explicitly only if you pair a flavor
    with a shape it does not normally use — e.g. a VM shape in the production zip via
    node_shape, which needs is_bare_metal = false.
  EOT
  type        = bool
  default     = null
}

variable "create_ensure_nics_policy" {
  description = <<-EOT
    Whether to apply the ensure-nics WekaPolicy (crds/02-ensure-nics-policy.yaml).
    When null, it is derived as the inverse of is_bare_metal: DISABLED on bare metal
    (NICs are pre-attached and selected by subnet; the policy crash-loops there on a
    GetVnic authorization error) and ENABLED on VMs, which have no pre-attached data
    NICs so secondary VNICs remain the path. The VM default is unverified — see the
    note in weka.tf.
  EOT
  type        = bool
  default     = null
}
