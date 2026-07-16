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
  description = "OCI region for the OKE cluster (e.g. us-phoenix-1, us-ashburn-1, eu-frankfurt-1)."
  type        = string
  default     = "us-phoenix-1"
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
  default     = "weka-oke"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the OKE control plane and node pool."
  type        = string
  default     = "v1.34.2"
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
# production:     VM.DenseIO.E5.Flex, node-pool (managed OKE).
#                 Local NVMe is discovered as weka.io/drives — no block volume.
#                 OCI allows 1–48 GB/OCPU for DenseIO.E5.Flex; only NVMe count
#                 is fixed at 1 per 8 OCPU. Default derives from flavor (8 OCPU / 96 GB).
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
    Cluster flavor — controls drive topology, node shape, and pool mode:
      "non-production" (default): VM.Standard.E5.Flex, instance-pool, paravirtualized
        block volume as WEKA drives. Standard shapes have abundant quota; ideal for
        operator/CSI integration testing where raw IO throughput is not the goal.
      "production": VM.DenseIO.E5.Flex, node-pool (managed OKE), local NVMe as WEKA
        drives. Best drive performance. DenseIO quota is limited — check AD capacity
        (oci compute compute-capacity-report) before provisioning.
  EOT
  type        = string
  default     = "non-production"
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
  description = "Optional override for the worker node shape. When null, derived from flavor (VM.DenseIO.E5.Flex for production, VM.Standard.E5.Flex for non-production)."
  type        = string
  default     = null
}

variable "node_ocpus" {
  description = "Optional override for OCPUs per worker node. When null, derived from flavor (8 for production, 10 for non-production). Example: set 16 to get a 2-NVMe DenseIO node under production flavor."
  type        = number
  default     = null
}

variable "node_memory_gb" {
  description = "Optional override for memory (GB) per worker node. When null, derived from flavor (96 for production, 80 for non-production). OCI allows 1–48 GB/OCPU for DenseIO.E5.Flex; only NVMe count is fixed at 1 per 8 OCPU."
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
  description = "Number of worker nodes."
  type        = number
  default     = 6
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
  description = "Number of 2Mi hugepages to reserve per worker node (WEKA requirement). 8000 x 2Mi ~= 15.6 GB."
  type        = number
  default     = 8000
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
