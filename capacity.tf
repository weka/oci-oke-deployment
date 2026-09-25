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
  has_capacity_reservation = var.capacity_reservation_id != ""

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
        "Options: (1) reserve the hosts up front and set capacity_reservation_id (the only option that cannot fail for capacity); (2) try another region; (3) once capacity frees up, pin an AD via worker_placement_ads; (4) use the non-production flavor (block-volume drives, abundant quota); or (5) if you believe this report is wrong, set skip_capacity_preflight = true to bypass this check.",
      ])
    }
  }
}

# ---------------------------------------------------------------------------
# Capacity-reservation gate.
#
# Setting capacity_reservation_id switches the preflight above off, so these
# checks are the only capacity verification left. They matter because OCI fills
# a reservation PARTIALLY when it is short: ask for 8 hosts, get 6, and the node
# pool fails on the last 2 exactly as it would have without a reservation.
#
# The single-AD rule is also enforced upstream for production (node pools), but
# NOT for the non-production instance-pool path, which has no such precondition
# (modules/workers/instancepools.tf) and fails at OCI launch instead.
#
# Reading the reservation needs the "inspect capacity-reservations" permission;
# skip_capacity_preflight bypasses these checks along with the report above.
# ---------------------------------------------------------------------------
data "oci_core_compute_capacity_reservation" "worker" {
  count                   = local.verify_reservation ? 1 : 0
  capacity_reservation_id = var.capacity_reservation_id
}

locals {
  verify_reservation = local.has_capacity_reservation && !var.skip_capacity_preflight

  # null when unparseable, so the first precondition reports it instead of the
  # whole plan dying inside tonumber().
  placement_ad_number = try(tonumber(trimspace(var.worker_placement_ads)), null)

  reservation = one(data.oci_core_compute_capacity_reservation.worker)
  # The module derives an AD's number from the last character of its name
  # (module-iam.tf); match that so the comparison agrees with placement_ads.
  reservation_ad_number = local.reservation == null ? null : parseint(substr(local.reservation.availability_domain, -1, -1), 10)

  reservation_free_per_config = local.reservation == null ? [] : [
    for c in local.reservation.instance_reservation_configs :
    tonumber(c.reserved_count) - tonumber(c.used_count) if c.instance_shape == local.node_shape
  ]
  # Zero also covers "the reservation holds a different shape than we launch".
  reservation_free = length(local.reservation_free_per_config) > 0 ? sum(local.reservation_free_per_config) : 0
}

resource "terraform_data" "reservation_gate" {
  count = local.has_capacity_reservation ? 1 : 0

  lifecycle {
    precondition {
      condition = local.placement_ad_number != null
      error_message = join(" ", [
        "capacity_reservation_id requires worker_placement_ads to name exactly one availability domain number,",
        "but it is \"${var.worker_placement_ads}\".",
        "Run `oci compute capacity-reservation get --capacity-reservation-id ${var.capacity_reservation_id}`",
        "and set worker_placement_ads to the trailing number of its availability domain (e.g. \"2\" for ...-AD-2).",
      ])
    }

    precondition {
      condition = local.reservation == null || local.placement_ad_number == null || local.placement_ad_number == local.reservation_ad_number
      error_message = join(" ", [
        "worker_placement_ads is \"${var.worker_placement_ads}\" but the reservation lives in",
        "${try(local.reservation.availability_domain, "?")} (AD ${coalesce(local.reservation_ad_number, 0)}).",
        "Workers can only draw on a reservation in their own AD — set worker_placement_ads to",
        "${coalesce(local.reservation_ad_number, 0)}.",
      ])
    }

    precondition {
      condition = local.reservation == null || local.reservation_free >= local.effective_node_count
      error_message = join(" ", [
        "The reservation has ${local.reservation_free} free ${local.node_shape} host(s) but this deployment needs",
        "${local.effective_node_count}. OCI fills a reservation partially when capacity is short, so a request for",
        "${local.effective_node_count} may have returned fewer — check it with",
        "`oci compute capacity-reservation get --capacity-reservation-id ${var.capacity_reservation_id}`.",
        "Grow the reservation, pick a production_tier that fits, or reserve in another AD or region.",
      ])
    }
  }
}
