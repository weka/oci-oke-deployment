# OKE cluster for running WEKA, provisioned with the upstream terraform-oci-oke
# module: a converged OKE node pool on OCI that the WEKA operator + WEKA CRs get
# layered onto afterwards.
#
# The WEKA layer (operator install, image pull secret, WekaPolicy/WekaCluster/
# WekaClient manifests) is intentionally NOT managed here — apply it after the
# cluster is up (see README), keeping cluster infra separate from the WEKA stack.

locals {
  # ---------------------------------------------------------------------------
  # Flavor → shape / mode / drive topology
  #
  # production:
  #   shape = VM.DenseIO.E5.Flex   mode = node-pool (managed OKE)
  #   Default 8 OCPU / 96 GB. OCI allows 1–48 GB/OCPU for DenseIO.E5.Flex;
  #   only NVMe count is fixed at 1 per 8 OCPU.
  #   WEKA operator's sign-drives WekaPolicy discovers NVMe as weka.io/drives.
  #   No block volume needed or attached.
  #   Trade-off: DenseIO quota is limited; check AD capacity before provisioning
  #   (oci compute compute-capacity-report).
  #
  # non-production:
  #   shape = VM.Standard.E5.Flex  mode = instance-pool (self-managed)
  #   10 OCPU / 80 GB. No local NVMe.
  #   WEKA drives come from a paravirtualized block volume (var.data_volume_gb, ≥50 GB).
  #   Standard shapes have abundant quota; ideal for operator/CSI integration
  #   testing where raw IO throughput is not the goal.
  # ---------------------------------------------------------------------------
  is_production = var.flavor == "production"

  # Shape / sizing — flavor-derived by default; optional var overrides win when set.
  # worker_mode stays flavor-locked (pool mode must match drive topology).
  # Note: set node_ocpus = 16 for a 2-NVMe DenseIO node under production flavor.
  node_shape     = coalesce(var.node_shape, local.is_production ? "VM.DenseIO.E5.Flex" : "VM.Standard.E5.Flex")
  node_ocpus     = var.node_ocpus     != null ? var.node_ocpus     : (local.is_production ? 8  : 10)
  node_memory_gb = var.node_memory_gb != null ? var.node_memory_gb : (local.is_production ? 96 : 80)
  worker_mode    = local.is_production ? "node-pool" : "instance-pool"

  # ---------------------------------------------------------------------------
  # Cloud-init — shared for BOTH flavors.
  #
  # We set disable_default_cloud_init = true and supply this fully self-contained
  # script that (1) fetches and runs the stock OKE init from IMDS, then (2)
  # configures hugepages + kubelet static-CPU policy. This approach is verified
  # for node-pool (production/DenseIO) and is intentionally kept for instance-pool
  # (non-production/Standard) as well: the oke-init.sh bootstrap works regardless
  # of pool mode — the node joins via the same IMDS script whether the pool is
  # managed (node-pool) or self-managed (instance-pool).
  # ---------------------------------------------------------------------------
  worker_cloud_init = <<-EOT
    #!/bin/bash
    curl -fH "Authorization: Bearer Oracle" -L0 169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 -d > /var/run/oke-init.sh
    bash /var/run/oke-init.sh

    # extend root disk
    bash /usr/libexec/oci-growfs -y

    # wait for kubelet before touching its config
    for i in $(seq 1 60); do
      systemctl is-active kubelet && break
      sleep 5
    done
    systemctl is-active kubelet && systemctl stop kubelet

    # hugepages (WEKA requirement)
    echo ${var.node_hugepages} > /proc/sys/vm/nr_hugepages
    sysctl -w vm.nr_hugepages=${var.node_hugepages}
    grep -q hugetlbfs /proc/mounts || { mkdir -p /mnt/huge && mount -t hugetlbfs none /mnt/huge; }

    # kubelet static CPU manager policy
    CONFIG_PATH="/etc/kubernetes/kubelet/kubelet-config.json"
    cat <<< $(jq '.systemReserved.cpu = "1"' "$CONFIG_PATH") > "$CONFIG_PATH"
    cat <<< $(jq '.cpuManagerPolicy = "static"' "$CONFIG_PATH") > "$CONFIG_PATH"
    systemctl start kubelet
  EOT

  # The module's own default subnet/NSG maps. We pass these when building a
  # fresh VCN so that a null `subnets`/`nsgs` var keeps the module defaults,
  # while still letting callers override for existing-network reuse.
  default_subnets = {
    bastion  = { newbits = 13 }
    operator = { newbits = 13 }
    cp       = { newbits = 13 }
    int_lb   = { newbits = 11 }
    pub_lb   = { newbits = 11 }
    workers  = { newbits = 4 }
    pods     = { newbits = 2 }
  }

  default_nsgs = {
    bastion  = {}
    operator = {}
    cp       = {}
    int_lb   = {}
    pub_lb   = {}
    workers  = {}
    pods     = {}
  }

  # ---------------------------------------------------------------------------
  # Single converged node pool (WEKA backends + clients).
  #
  # merge() layer 1 (base): shape/sizing/labels/cloud-init — same for both flavors.
  # merge() layer 2 (placement): optionally pin ADs via placement_ads when
  #   var.worker_placement_ads is set (e.g. to steer DenseIO around out-of-capacity
  #   ADs). Empty => module default (all ADs).
  # merge() layer 3 (block volume): non-production only — attach a paravirtualized
  #   block volume as WEKA drives. Production (DenseIO) has local NVMe presented
  #   automatically by the hypervisor; no block volume is needed or attached.
  # ---------------------------------------------------------------------------
  worker_pools = {
    (var.node_pool_name) = merge(
      {
        description      = "WEKA converged node pool (flavor=${var.flavor})"
        mode             = local.worker_mode
        size             = var.node_count
        shape            = local.node_shape
        ocpus            = local.node_ocpus
        memory           = local.node_memory_gb
        boot_volume_size = var.node_boot_volume_gb
        # WEKA converged node labels (backends + clients).
        node_labels = {
          "weka.io/tool"              = "terraform-oci-oke"
          "weka.io/supports-backends" = "true"
          "weka.io/supports-clients"  = "true"
        }
        # Own the node bring-up so we can add the WEKA hugepages/kubelet prep.
        # Works for both node-pool and instance-pool (see cloud-init comment above).
        disable_default_cloud_init = true
        cloud_init = [{
          content      = local.worker_cloud_init
          content_type = "text/x-shellscript"
        }]
      },
      # AD pinning — preserved from the original stack.
      var.worker_placement_ads != "" ? {
        placement_ads = [for n in split(",", var.worker_placement_ads) : tonumber(trimspace(n))]
      } : {},
      # Non-production only: attach a paravirtualized block volume as WEKA drives.
      # Production (DenseIO node-pool) uses local NVMe — no block volume attached.
      local.is_production ? {} : {
        disable_block_volume     = false
        block_volume_size_in_gbs = var.data_volume_gb
        block_volume_type        = "paravirtualized"
      }
    )
  }
}

module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  version = "5.5.0"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # Tenancy / region
  tenancy_id     = var.tenancy_ocid
  compartment_id = var.compartment_ocid
  region         = var.region
  home_region    = coalesce(var.home_region, var.region)

  # SSH access to nodes. The module prefers ssh_public_key (content) and only
  # reads ssh_public_key_path when content is null (see module variables-common.tf),
  # so both can be passed safely — content wins for ORM, path for local.
  ssh_public_key      = var.ssh_public_key
  ssh_public_key_path = var.ssh_public_key_path

  # Networking — fresh VCN by default; reuse existing when create_vcn = false.
  create_vcn = var.create_vcn
  vcn_id     = var.vcn_id
  vcn_cidrs  = var.vcn_cidrs
  subnets    = coalesce(var.subnets, local.default_subnets)
  nsgs       = coalesce(var.nsgs, local.default_nsgs)

  # Cluster
  create_cluster              = true
  cluster_name                = var.cluster_name
  cluster_type                = var.cluster_type
  kubernetes_version          = var.kubernetes_version
  cni_type                    = var.cni_type
  control_plane_is_public     = var.control_plane_is_public
  control_plane_allowed_cidrs = var.control_plane_allowed_cidrs
  # v5.x splits "public endpoint" (subnet placement) from "assign a public IP to
  # the API endpoint"; we need both true so kubectl reaches the cluster directly.
  assign_public_ip_to_control_plane = var.control_plane_is_public

  # We drive kubectl/wekakube from the laptop against the public API endpoint,
  # so the private bastion + operator hosts aren't needed. Skipping the IAM
  # dynamic groups/policies keeps this a minimal, low-permission dev cluster.
  create_bastion       = false
  create_operator      = false
  create_iam_resources = false

  # Workers — pool mode driven by flavor: node-pool (production/DenseIO) or
  # instance-pool (non-production/Standard). See locals above for details.
  worker_pool_mode        = local.worker_mode
  worker_image_type       = "oke"
  worker_image_os         = "Oracle Linux"
  worker_image_os_version = var.worker_image_os_version
  worker_pools            = local.worker_pools

  # Emit cluster_kubeconfig in outputs as a fallback (we normally generate the
  # kubeconfig with `oci ce cluster create-kubeconfig` in the skill).
  output_detail = true
}
