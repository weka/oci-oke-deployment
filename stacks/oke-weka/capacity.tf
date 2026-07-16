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
# Caveats (both bypassable via skip_capacity_preflight):
#   - The report is a strong signal, not a guarantee — it can occasionally say
#     OUT_OF_HOST_CAPACITY for a shape that would actually provision.
#   - Reading it needs the "inspect compute-capacity-reports" permission; a
#     tenancy without it fails on the report itself.
#
# Non-production (Standard shapes, abundant quota) skips this entirely.
# ---------------------------------------------------------------------------

locals {
  capacity_preflight = local.is_production && !var.skip_capacity_preflight
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
        "Options: (1) try another region; (2) once capacity frees up, pin an AD via worker_placement_ads; (3) use the non-production flavor (block-volume drives, abundant quota); or (4) if you believe this report is wrong, set skip_capacity_preflight = true to bypass this check.",
      ])
    }
  }
}
