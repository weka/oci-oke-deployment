# ---------------------------------------------------------------------------
# Production NVMe capacity preflight.
#
# DenseIO (local-NVMe) host capacity is scarce and specific to a region + AD.
# Without this, an out-of-capacity AD only surfaces deep in the apply as a
# cryptic OCI 500 on the worker node pool — after the VCN and control plane are
# already built. This preflight asks OCI for a compute-capacity-report on the
# worker shape across every AD in the region BEFORE anything is created, and
# hard-fails with an actionable message when none of them have capacity.
#
# Caveats (all bypassable via skip_capacity_preflight):
#   - The report is a signal, not a guarantee, and it is wrong in BOTH
#     directions: it can say OUT_OF_HOST_CAPACITY for a shape that would
#     provision, and on 2026-09-25 all three eu-frankfurt-1 ADs reported
#     AVAILABLE for BM.DenseIO.E5.128 both before and two hours after an 8-node
#     apply that failed with "Out of host capacity" on 2 of the 8.
#   - It cannot be tightened into a host-COUNT gate, which is the obvious next
#     move when the above bites: OCI returns available_count = null for these
#     shapes (verified per-AD and per-fault-domain, bare metal and flex), so
#     there is no number to compare effective_node_count against.
#   - Reading it needs the "inspect compute-capacity-reports" permission; a
#     tenancy without it fails on the report itself.
#
# Non-production (Standard shapes, abundant quota) skips this entirely.
# ---------------------------------------------------------------------------

locals {
  capacity_reservation_ids = [for s in split(",", var.capacity_reservation_ids) : trimspace(s) if trimspace(s) != ""]
  has_capacity_reservation = length(local.capacity_reservation_ids) > 0

  # A reservation already holds the hosts, so an unreliable OUT_OF_HOST_CAPACITY
  # reading would block a deploy that cannot fail for capacity. The reservation
  # gate below replaces this check rather than adding to it.
  capacity_preflight = local.is_production && !var.skip_capacity_preflight && !local.has_capacity_reservation
}

# All ADs in the target region (capacity is per-AD).
data "oci_identity_availability_domains" "preflight" {
  count          = local.capacity_preflight ? 1 : 0
  compartment_id = var.tenancy_ocid
}

# One capacity report per AD for the exact worker shape/config we will request.
resource "oci_core_compute_capacity_report" "nvme" {
  for_each = local.capacity_preflight ? {
    for ad in data.oci_identity_availability_domains.preflight[0].availability_domains : ad.name => ad.name
  } : {}

  # Capacity reports must be scoped to the tenancy (root) compartment.
  compartment_id      = var.tenancy_ocid
  availability_domain = each.value

  shape_availabilities {
    instance_shape = local.node_shape
    # Bare-metal shapes have fixed OCPU/memory and REJECT instance_shape_config;
    # only send it for Flex shapes (mirrors the module's regexall("Flex", ...)).
    dynamic "instance_shape_config" {
      for_each = length(regexall("Flex", local.node_shape)) > 0 ? [1] : []
      content {
        ocpus         = local.node_ocpus
        memory_in_gbs = local.node_memory_gb
      }
    }
  }
}

locals {
  # AD name => availability_status: AVAILABLE | OUT_OF_HOST_CAPACITY | HARDWARE_NOT_SUPPORTED
  capacity_status_by_ad = {
    for name, r in oci_core_compute_capacity_report.nvme : name => r.shape_availabilities[0].availability_status
  }
  ads_with_capacity = [for name, status in local.capacity_status_by_ad : name if status == "AVAILABLE"]

  # HARDWARE_NOT_SUPPORTED everywhere means the shape is not OFFERED in this
  # region at all — a different failure from "no free hosts right now", and one
  # that waiting or pinning an AD will never fix. Reporting them the same way
  # sends people hunting for capacity that was never the problem.
  shape_unsupported = (
    length(local.capacity_status_by_ad) > 0 &&
    alltrue([for st in values(local.capacity_status_by_ad) : st == "HARDWARE_NOT_SUPPORTED"])
  )
}

# The gate. It is intentionally NOT wired as a module dependency (that would
# defer the module's data sources and break a for_each inside it — see the note
# on module.oke in main.tf). Instead it stands alone: the capacity reports
# resolve in seconds, so this precondition fails the apply almost immediately —
# well before the slow worker node-pool build the capacity actually gates. A
# little networking may be created before the failure surfaces; `terraform
# destroy` (the stack's teardown) cleans it up.
resource "terraform_data" "capacity_gate" {
  count = local.capacity_preflight ? 1 : 0
  input = local.capacity_status_by_ad

  lifecycle {
    precondition {
      condition = length(local.ads_with_capacity) > 0
      error_message = join("\n", [
        local.shape_unsupported ? join(" ", [
          "Shape ${local.node_shape} is not offered in ${var.region}: every availability domain reports HARDWARE_NOT_SUPPORTED,",
          "which means the shape does not exist here — not that it is temporarily full. Waiting for capacity or pinning an AD will not help.",
          "Run `oci compute shape list --compartment-id <tenancy> --region ${var.region} --all` to see what this region actually offers.",
          ]) : join(" ", [
          "No availability domain in ${var.region} currently has free ${local.node_shape} (${local.node_ocpus} OCPU) capacity for the production flavor.",
        ]),
        "Per-AD status: ${join(", ", [for ad, st in local.capacity_status_by_ad : "${ad}=${st}"])}.",
        local.shape_unsupported ?
        "Options: (1) deploy to a region that offers this shape; (2) use the non-production flavor (Standard shapes, block-volume drives); or (3) override node_shape with a DenseIO shape this region does offer." :
        "Options: (1) reserve the hosts up front and set capacity_reservation_ids — one reservation per AD, which is the only option that cannot fail for capacity; (2) try another region; (3) once capacity frees up, pin an AD via worker_placement_ads; (4) use the non-production flavor (block-volume drives, abundant quota); or (5) if you believe this report is wrong, set skip_capacity_preflight = true to bypass this check.",
      ])
    }
  }
}

# ---------------------------------------------------------------------------
# Capacity-reservation gate.
#
# OCI fills a reservation PARTIALLY when it is short: ask for 8 hosts, get 6,
# and the node pool fails on the last 2 exactly as it would have without a
# reservation. Setting capacity_reservation_ids also switches the preflight
# above off, so this is the only capacity verification left.
#
# A reservation lives in ONE availability domain and the module allows one AD
# per pool, so each reservation becomes its own worker pool (main.tf).
#
# Reading a reservation needs the "inspect capacity-reservations" permission.
# The lookup is NOT gated on skip_capacity_preflight: its availability_domain
# decides where each pool is placed, so the build needs it either way. Only the
# host-count precondition honours that bypass.
#
# THIS GATE DOES NOT COVER THE FAILURE THAT ACTUALLY KILLS RESERVED APPLIES.
# OKE launches nodes under the node-pool principal, which needs a separate
# TENANCY-level grant on compute-capacity-reservations. Nothing here can see
# that: the data source below runs as the DEPLOYING user, succeeds, and the
# preconditions then pass on real data — while the node pool dies ~7 minutes
# later with a 404 (NotAuthorizedOrNotFound) that names the reservation and
# reads like it is missing. TROUBLESHOOTING.md §9.
# ---------------------------------------------------------------------------
data "oci_core_compute_capacity_reservation" "worker" {
  for_each                = toset(local.capacity_reservation_ids)
  capacity_reservation_id = each.value
}

locals {
  reservation_details = {
    for id, r in data.oci_core_compute_capacity_reservation.worker : id => {
      # The module derives an AD's number from the last character of its name
      # (module-iam.tf); match that so placement_ads agrees with it.
      ad_number = parseint(substr(r.availability_domain, -1, -1), 10)

      # reserved_count, NOT reserved minus used: once this stack's own nodes
      # launch they become the used count, so a free-host check would pass on
      # create and fail every re-apply afterwards. reserved_count is what OCI
      # actually granted, which is also exactly what a partial fill lowers.
      # Filtering by shape makes a wrong-shape reservation count zero rather
      # than silently satisfying the check.
      reserved = sum(concat([0], [
        for c in r.instance_reservation_configs :
        tonumber(c.reserved_count) if c.instance_shape == local.node_shape
      ]))
    }
  }

  reservation_ids_sorted = sort(keys(local.reservation_details))
  reservation_ad_numbers = [for id in local.reservation_ids_sorted : local.reservation_details[id].ad_number]

  # Even spread: the first (node count % pools) pools take one extra node.
  reservation_pool_count = length(local.reservation_ids_sorted)
  reservation_pool_size  = ceil(local.effective_node_count / local.reservation_pool_count)
  reservation_pools = [
    for i, id in local.reservation_ids_sorted : {
      reservation_id = id
      ad_number      = local.reservation_details[id].ad_number
      reserved       = local.reservation_details[id].reserved
      size           = floor(local.effective_node_count / local.reservation_pool_count) + (i < local.effective_node_count % local.reservation_pool_count ? 1 : 0)
    }
  ]

  reservation_pools_short = [
    for p in local.reservation_pools : "AD-${p.ad_number} needs ${p.size}, reserved ${p.reserved}"
    if p.size > p.reserved
  ]
}

resource "terraform_data" "reservation_gate" {
  count = local.has_capacity_reservation ? 1 : 0

  lifecycle {
    # Two reservations in one AD would collide on the pool name built from that
    # AD number, and one pool would silently replace the other.
    precondition {
      condition = length(distinct(local.reservation_ad_numbers)) == length(local.reservation_ad_numbers)
      error_message = join(" ", [
        "capacity_reservation_ids must name reservations in distinct availability domains, but got ADs",
        "${join(", ", local.reservation_ad_numbers)}. Consolidate the reservations that share an AD into one.",
      ])
    }

    precondition {
      condition = var.worker_placement_ads == ""
      error_message = join(" ", [
        "worker_placement_ads must be empty when capacity_reservation_ids is set —",
        "workers are placed in the ADs of the reservations themselves (currently",
        "${join(", ", formatlist("AD-%d", local.reservation_ad_numbers))}).",
      ])
    }

    precondition {
      condition = var.skip_capacity_preflight || length(local.reservation_pools_short) == 0
      error_message = join(" ", [
        "Spreading ${local.effective_node_count} nodes over ${local.reservation_pool_count} reservation(s)",
        "needs up to ${local.reservation_pool_size} hosts of ${local.node_shape} in each:",
        "${join("; ", local.reservation_pools_short)}.",
        "OCI grants fewer hosts than asked for when capacity is short, so check what each reservation",
        "actually holds with `oci compute capacity-reservation list -c <compartment>`.",
        "Even out the reservations, drop the one that is short (its nodes then spread over the rest),",
        "or pick a production_tier that fits what you were granted.",
      ])
    }
  }
}
