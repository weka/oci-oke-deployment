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
  #   shape = BM.DenseIO.E5.128   mode = node-pool (managed OKE)
  #   Node count comes from var.production_tier, whose values name the usable
  #   capacity and instance type directly (see tier_specs below).
  #   Local NVMe (6.8 TB/drive) is discovered as weka.io/drives by the WEKA
  #   sign-drives policy. No block volume needed or attached.
  #   Trade-off: DenseIO quota is limited; check AD capacity before provisioning
  #   (capacity.tf preflight).
  #
  # non-production:
  #   shape = VM.Standard.E5.Flex  mode = instance-pool (self-managed)
  #   10 OCPU / 80 GB. No local NVMe.
  #   WEKA drives come from a paravirtualized block volume (var.data_volume_gb, ≥50 GB).
  #   Standard shapes have abundant quota; ideal for operator/CSI integration
  #   testing where raw IO throughput is not the goal.
  # ---------------------------------------------------------------------------
  is_production = var.flavor == "production"

  # ---------------------------------------------------------------------------
  # Production sizing options (fixed shape + count per pick).
  #
  # Each option is KEYED BY WHAT THE CUSTOMER PICKS ON — usable capacity and the
  # instance type — because ORM renders enum values verbatim in the dropdown
  # (schema 1.1.0 has no separate label/value), so the key IS the label. Keep the
  # keys here in sync with the enum in schema-prod.yaml and the validation list in
  # variables.tf.
  #
  # Every option pins the worker SHAPE and node COUNT together, so the deploy-time
  # choice fully determines the hardware — and the guard (guard.tf) freezes it
  # after first apply, since a resize would destroy/replace nodes.
  #
  # Two bare-metal DenseIO shapes are supported:
  #   BM.DenseIO.E5.128 — 12 x 6.8 TB local NVMe (81.6 TB raw/node), 1536 GB, 128 cores
  #   BM.DenseIO.E4.128 —  8 x 6.8 TB local NVMe (54.4 TB raw/node), 2048 GB, 128 cores
  # E5 is the primary ladder (8 nodes to 171); E4 exists as an 8-node option because
  # E5 DenseIO capacity is frequently unavailable, and E4 is much less contended.
  # terraform-oci-oke omits shape_config for non-Flex shapes automatically
  # (regexall("Flex", ...)), so the ocpus/memory below are informational — the
  # bare-metal shape fixes them.
  #
  # Within a shape, capacity scales purely by NODE COUNT:
  #   - 8 / 12 / 16 nodes: sub-PB entry sizes, single protection (SW = N-3, RL 2).
  #   - 21 nodes and up:   double protection (16+4+1), where each +17 nodes adds
  #     ~1 PB usable — hence the 21 -> 35 -> 52 -> ... -> 171 ladder up to 10 PB.
  # The capacity in each key is what cluster_usable_tb computes below, rounded.
  # ---------------------------------------------------------------------------
  tier_specs = {
    # E4 (previous generation): 8 x 6.8 TB NVMe and 2048 GB per node, vs E5's 12
    # NVMe and 1536 GB (both 128 OCPU) — specs from `oci compute shape list` and
    # confirmed against Weka's own shape table in terraform-oci-weka. Less capacity
    # per node, but markedly easier to get: E5 DenseIO in eu-frankfurt-1 was
    # repeatedly short through a day of testing while E4 provisioned every time.
    # Same protection scheme as the 8-node E5 tier (5+2+1) since that derives from
    # node count, and the data plane is identical — NICs are selected by subnet, not
    # by a shape-specific device name (see weka.tf).
    "245 TB usable - 8 x BM.DenseIO.E4.128 (8 NVMe)" = { shape = "BM.DenseIO.E4.128", ocpus = 128, memory = 2048, node_count = 8, drives_per_node = 8 }

    "367 TB usable - 8 x BM.DenseIO.E5.128 (12 NVMe)"  = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 8, drives_per_node = 12 }
    "661 TB usable - 12 x BM.DenseIO.E5.128 (12 NVMe)" = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 12, drives_per_node = 12 }
    "955 TB usable - 16 x BM.DenseIO.E5.128 (12 NVMe)" = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 16, drives_per_node = 12 }
    "1.2 PB usable - 21 x BM.DenseIO.E5.128 (12 NVMe)" = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 21, drives_per_node = 12 }
    "2 PB usable - 35 x BM.DenseIO.E5.128 (12 NVMe)"   = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 35, drives_per_node = 12 }
    "3 PB usable - 52 x BM.DenseIO.E5.128 (12 NVMe)"   = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 52, drives_per_node = 12 }
    "4 PB usable - 69 x BM.DenseIO.E5.128 (12 NVMe)"   = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 69, drives_per_node = 12 }
    "5 PB usable - 86 x BM.DenseIO.E5.128 (12 NVMe)"   = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 86, drives_per_node = 12 }
    "6 PB usable - 103 x BM.DenseIO.E5.128 (12 NVMe)"  = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 103, drives_per_node = 12 }
    "7 PB usable - 120 x BM.DenseIO.E5.128 (12 NVMe)"  = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 120, drives_per_node = 12 }
    "8 PB usable - 137 x BM.DenseIO.E5.128 (12 NVMe)"  = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 137, drives_per_node = 12 }
    "9 PB usable - 154 x BM.DenseIO.E5.128 (12 NVMe)"  = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 154, drives_per_node = 12 }
    "10 PB usable - 171 x BM.DenseIO.E5.128 (12 NVMe)" = { shape = "BM.DenseIO.E5.128", ocpus = 128, memory = 1536, node_count = 171, drives_per_node = 12 }
  }
  selected_tier = local.tier_specs[var.production_tier]

  # Shape / sizing — production pulls from the selected tier; non-production stays
  # VM.Standard.E5.Flex. Optional var overrides still win (advanced/local use).
  # worker_mode stays flavor-locked (pool mode must match drive topology).
  node_shape     = coalesce(var.node_shape, local.is_production ? local.selected_tier.shape : "VM.Standard.E5.Flex")
  node_ocpus     = var.node_ocpus != null ? var.node_ocpus : (local.is_production ? local.selected_tier.ocpus : 10)
  node_memory_gb = var.node_memory_gb != null ? var.node_memory_gb : (local.is_production ? local.selected_tier.memory : 80)
  worker_mode    = local.is_production ? "node-pool" : "instance-pool"

  # OS-level 2Mi hugepage reservation per node. The operator sizes each WEKA
  # container's hugepages itself; the node just needs enough total reserved. Scale
  # with OCPU to preserve the 8-OCPU ratio (8000 pages ~= 15.6 GB) and give the
  # larger VM/BM tiers headroom. var.node_hugepages overrides when set.
  node_hugepages = coalesce(var.node_hugepages, local.is_production ? local.node_ocpus * 1000 : 8000)

  # Self-managed (instance-pool) workers bootstrap themselves via the IMDS
  # oke_init_script and can ONLY register with an ENHANCED OKE cluster — a BASIC
  # cluster silently never admits them (workers boot Running but 0 nodes join,
  # leaving coredns/operator Pending until the helm wait times out). Managed
  # node-pools work on either, so force enhanced in instance-pool mode and honor
  # var.cluster_type otherwise.
  cluster_type = local.worker_mode == "instance-pool" ? "enhanced" : var.cluster_type

  # ---------------------------------------------------------------------------
  # Worker count + WEKA protection scheme.
  #
  # Production: the selected tier fixes both node COUNT and per-node raw NVMe
  # (drives_per_node x 6.8 TB). Non-production uses var.node_count directly (drives
  # come from a block volume sized by data_volume_gb, not local NVMe).
  #
  # WEKA usable = (N - HS) x rawPerNode x SW/(SW + RL) x 0.9, protection adapting
  # to cluster size:
  #   - N < 21  : RL = 2, HS = 1, SW = min(16, N - 3)   -> "x+2+1" (8-node: 5+2+1)
  #   - N >= 21 : RL = 4, HS = 1, SW = 16               -> "16+4+1" (21 nodes and up)
  # ---------------------------------------------------------------------------
  weka_fs_overhead = 0.9
  weka_hot_spare   = 1
  max_stripe_width = 16

  # Raw local-NVMe TB per production worker = drives on the selected tier x 6.8 TB.
  nvme_tb_per_node = local.is_production ? local.selected_tier.drives_per_node * 6.8 : 0

  effective_node_count = local.is_production ? local.selected_tier.node_count : var.node_count

  # Protection scheme + capacity implied by the chosen count (surfaced in outputs).
  weka_redundancy   = local.effective_node_count >= 21 ? 4 : 2
  weka_stripe_width = min(local.max_stripe_width, local.effective_node_count - local.weka_redundancy - local.weka_hot_spare)
  cluster_raw_tb    = local.effective_node_count * local.nvme_tb_per_node
  cluster_usable_tb = (local.effective_node_count - local.weka_hot_spare) * local.nvme_tb_per_node * (local.weka_stripe_width / (local.weka_stripe_width + local.weka_redundancy)) * local.weka_fs_overhead

  # ---------------------------------------------------------------------------
  # Cloud-init — supplementary WEKA node tuning, for BOTH flavors.
  #
  # We let terraform-oci-oke run its OWN node bootstrap (disable_default_cloud_init
  # = false in worker_pools). That bootstrap — the module's cloudinit-oke.sh plus
  # the /etc/oke/oke-apiserver and /etc/kubernetes/ca.crt files it writes, driven
  # by oke-init.service — is what actually joins the node, and it works for
  # SELF-MANAGED (instance-pool) workers too.
  #
  # The previous approach (disable_default_cloud_init = true + a self-contained
  # `curl .../opc/v2/instance/metadata/oke_init_script | bash`) only works on
  # MANAGED node pools: OKE serves that IMDS key to managed instances but returns
  # 404 on self-managed instance-pool workers, so the bootstrap never ran — the
  # node came up with kubelet crashlooping on a missing containerd socket (the
  # image uses CRI-O) and never registered (0 nodes, operator Pending, helm wait
  # timeout). Deferring to the module's bootstrap fixes the instance-pool path.
  #
  # This part carries ONLY the WEKA tuning, as cloud-config:
  #   - hugepages: a /etc/sysctl.d drop-in (survives reboot — `sysctl -w` alone
  #     does not, so a rebooted node would come back with the image default and
  #     WEKA containers would fail to get their hugepages) plus an immediate
  #     `sysctl --system` so the reservation is live on this boot too. Reserving
  #     early matters: hugepages need contiguous memory, and a long-running node
  #     may not be able to satisfy the request later.
  #   - a systemd ONESHOT unit for the static CPU-manager policy. It MUST be a
  #     systemd unit, not an inline/backgrounded script: the module prepends custom
  #     cloud_init parts BEFORE its bootstrap, so kubelet isn't configured yet when
  #     this runs, and cloud-init reaps backgrounded children when the part exits
  #     (a `... &` watcher silently dies before kubelet exists). The unit is ordered
  #     After=kubelet.service and self-waits for the kubelet config, then flips
  #     cpuManagerPolicy=static, locating the config dynamically (path varies by
  #     image generation; OL8/CRI-O uses /etc/kubernetes/kubelet-config.json) and
  #     auto-reverting if kubelet won't restart, so it can never strand a node.
  #     Either way it ends in exactly one kubelet restart — including when the
  #     policy is already set — because kubelet only reads hugepage capacity at
  #     startup and may have come up before the sysctl drop-in was applied.
  #
  #     CRITICAL: start it with `systemctl start --no-block`, NEVER `enable --now`.
  #     Our runcmd runs in cloud-init's scripts-user (final) stage. `enable --now`
  #     starts the oneshot SYNCHRONOUSLY, so cloud-final blocks on the unit's
  #     ExecStart — which self-waits up to ~15m for the kubelet config. That stalls
  #     cloud-final, which in turn starves the module's own oke-init.service (kicked
  #     off later in the same final stage), so kubelet never gets its CRI-O/API
  #     config, keeps crashlooping on the default containerd socket, and the node
  #     never joins (0 nodes -> operator Pending -> `helm ... context deadline
  #     exceeded`). `start --no-block` enqueues the start and returns immediately;
  #     systemd then runs the oneshot in the background, still ordered After=kubelet.
  # ---------------------------------------------------------------------------
  # Reboot-persistent hugepage reservation. systemd-sysctl.service re-applies
  # /etc/sysctl.d/* on every boot, so the node comes back with the reservation
  # intact; the 99- prefix sorts it last, after the image's own drop-ins.
  weka_hugepages_sysctl = <<-CONF
    # Managed by the WEKA OKE stack — do not edit.
    # 2Mi hugepages reserved for WEKA containers (see local.node_hugepages).
    vm.nr_hugepages = ${local.node_hugepages}
  CONF

  weka_cpu_tuning_script = <<-SCRIPT
    #!/bin/bash
    for i in $(seq 1 90); do
      cfg=""
      for p in /etc/kubernetes/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json /var/lib/kubelet/config.yaml; do
        [ -f "$p" ] && { cfg="$p"; break; }
      done
      if [ -n "$cfg" ] && systemctl is-active --quiet kubelet; then
        # Matches both the JSON ("cpuManagerPolicy":) and YAML (cpuManagerPolicy:)
        # forms, so the already-configured path is reachable for either image.
        if grep -qE '^[[:space:]]*"?cpuManagerPolicy"?[[:space:]]*:' "$cfg" 2>/dev/null; then
          # Config is already correct, so there is nothing to edit — but kubelet
          # still needs ONE restart. It reads hugepage capacity at startup, and
          # /etc/sysctl.d is applied on a boot path that can land after kubelet is
          # already up; a kubelet that started first advertises hugepages-2Mi=0 and
          # WEKA pods sit Pending forever on a request the node claims it cannot
          # meet. Restarting re-reads /sys and republishes the real capacity.
          logger -t weka-tuning "cpuManagerPolicy already set in $cfg; restarting kubelet once for hugepages ($(cat /proc/sys/vm/nr_hugepages) reserved)"
          systemctl restart kubelet; sleep 15
          if systemctl is-active --quiet kubelet; then
            logger -t weka-tuning "kubelet restarted for hugepage capacity"
          else
            # No config was touched, so there is nothing to revert — one more
            # restart is the only recovery, and leaving it down is worse.
            logger -t weka-tuning "WARNING: kubelet did not come back after hugepage restart; retrying once"
            systemctl restart kubelet
          fi
          exit 0
        fi
        cp -a "$cfg" "$cfg.wekabak"
        case "$cfg" in
          *.json) tmp=$(mktemp); jq '.systemReserved.cpu="1" | .cpuManagerPolicy="static"' "$cfg" > "$tmp" && mv "$tmp" "$cfg" ;;
          *) grep -q '^cpuManagerPolicy:' "$cfg" && sed -i 's/^cpuManagerPolicy:.*/cpuManagerPolicy: static/' "$cfg" || printf 'cpuManagerPolicy: static\n' >> "$cfg" ;;
        esac
        rm -f /var/lib/kubelet/cpu_manager_state
        systemctl restart kubelet; sleep 15
        if systemctl is-active --quiet kubelet; then
          logger -t weka-tuning "applied static CPU-manager policy to $cfg"
        else
          mv -f "$cfg.wekabak" "$cfg"; rm -f /var/lib/kubelet/cpu_manager_state; systemctl restart kubelet
          logger -t weka-tuning "reverted CPU-manager change (kubelet failed to start)"
        fi
        exit 0
      fi
      sleep 10
    done
    logger -t weka-tuning "kubelet config not found after ~15m; CPU-manager tuning skipped"
  SCRIPT

  weka_cpu_tuning_unit = <<-UNIT
    [Unit]
    Description=WEKA kubelet tuning (static CPU-manager policy + hugepage capacity)
    After=kubelet.service systemd-sysctl.service
    Wants=kubelet.service
    [Service]
    Type=oneshot
    RemainAfterExit=true
    ExecStart=/usr/local/sbin/weka-cpu-tuning.sh
    [Install]
    WantedBy=multi-user.target
  UNIT

  # Delivered as cloud-config so Terraform/jsonencode handle all escaping.
  worker_cloud_init = jsonencode({
    write_files = [
      { path = "/usr/local/sbin/weka-cpu-tuning.sh", permissions = "0755", owner = "root:root", content = local.weka_cpu_tuning_script },
      { path = "/etc/systemd/system/weka-cpu-tuning.service", permissions = "0644", owner = "root:root", content = local.weka_cpu_tuning_unit },
      { path = "/etc/sysctl.d/99-weka-hugepages.conf", permissions = "0644", owner = "root:root", content = local.weka_hugepages_sysctl },
    ]
    runcmd = [
      # Apply the drop-in now (it is what systemd-sysctl re-applies on every boot).
      "sysctl --system",
      "grep -q hugetlbfs /proc/mounts || { mkdir -p /mnt/huge && mount -t hugetlbfs none /mnt/huge; }",
      "systemctl daemon-reload",
      # enable for persistence, then start ASYNC. NEVER `enable --now` here: a
      # synchronous start blocks cloud-final on the 15m-self-waiting oneshot and
      # starves the module's oke-init.service, so workers never join (see above).
      "systemctl enable weka-cpu-tuning.service",
      "systemctl start --no-block weka-cpu-tuning.service",
    ]
  })

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
        size             = local.effective_node_count
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
        # Let terraform-oci-oke run its native node bootstrap (writes /etc/oke/*
        # and runs oke-init.service) — REQUIRED for self-managed instance-pool
        # workers to join. Our WEKA tuning rides along as a supplementary
        # cloud_init part (see cloud-init comment above).
        disable_default_cloud_init = false
        cloud_init = [{
          content      = local.worker_cloud_init
          content_type = "text/cloud-config"
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

  # NOTE: do NOT add `depends_on = [terraform_data.capacity_gate]` here. A
  # module-level depends_on defers this module's own data sources to apply time,
  # which makes ad_numbers_to_names unknown at plan and breaks a for_each inside
  # the module (data-faultdomains.tf). The capacity preflight (capacity.tf) is an
  # independent gate that fails the apply early on its own instead.

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
  cluster_type                = local.cluster_type
  kubernetes_version          = var.kubernetes_version
  cni_type                    = var.cni_type
  control_plane_is_public     = var.control_plane_is_public
  control_plane_allowed_cidrs = var.control_plane_allowed_cidrs
  # v5.x splits "public endpoint" (subnet placement) from "assign a public IP to
  # the API endpoint"; we need both true so kubectl reaches the cluster directly.
  assign_public_ip_to_control_plane = var.control_plane_is_public

  # We drive kubectl/wekakube from the laptop against the public API endpoint,
  # so the private bastion + operator hosts aren't needed.
  create_bastion  = false
  create_operator = false
  # IAM: MANAGED node-pools (production) are authorized to join by OKE itself, so
  # no IAM is needed and those deploys stay minimal / low-permission. But
  # SELF-MANAGED instance-pool workers (non-production) MUST have a worker dynamic
  # group + an "Allow dynamic-group ... to {CLUSTER_JOIN} ... where
  # target.cluster.id = <id>" policy, or the control plane rejects their bootstrap
  # with 403 "node not authorized" at :12250/workerNodeBootstrap and 0 nodes ever
  # join. create_iam_worker_policy defaults to "auto" (=true for instance-pool) and
  # the module already feeds it cluster_id, so simply enabling create_iam_resources
  # in instance-pool mode creates exactly that worker dynamic-group + CLUSTER_JOIN
  # policy — nothing else (operator/autoscaler/kms/karpenter policies stay
  # "auto"=false with this config, use_defined_tags is off).
  # NOTE: non-production therefore requires the deploying principal to be able to
  # create dynamic groups + policies in the tenancy (root compartment).
  create_iam_resources = local.worker_mode == "instance-pool"

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
