# WEKA data-plane network fix (OCI security).
#
# WHY THIS EXISTS
# ---------------
# WEKA's ensure-nics operation (the `cloud-helper` binary inside the WEKA image)
# creates one secondary "data" VNIC per IO node on the worker subnet, tagged
# `weka_reason=ensure_nics`. It creates those VNICs with NO NSG membership, and
# the WEKA operator exposes no knob to change that.
#
# The terraform-oci-oke module, meanwhile, puts ALL intra-cluster "allow" rules
# on the worker NSG, and that allow-all-worker<->worker rule is scoped to NSG
# *membership* (source/dest = the NSG itself). The worker subnet is left on the
# VCN's default security list, which the module locks down to EMPTY
# (lockdown_default_seclist = true, the module default).
#
# Net effect:
#   * the primary/mgmt VNIC IS in the worker NSG  -> mgmt plane works, cluster forms
#   * the WEKA data VNICs are NOT in the NSG, and the subnet's only security list
#     (the default) is empty -> they have ZERO allow coverage, so DPDK
#     backend<->backend traffic is silently dropped ("Network port inactivity
#     triggered node termination") and the cluster is stuck in Init with no drives.
#
# THE FIX
# -------
# Attach a security list to the worker subnet that allows all traffic within the
# VCN CIDR. Subnet security lists apply to EVERY VNIC in the subnet regardless of
# NSG membership, so this is the only construct that can cover the non-NSG WEKA
# data VNICs. (Adding rules to the worker NSG cannot help them: NSG rules apply
# only to NSG members.)
#
# HOW (and why local-exec)
# ------------------------
# The module hardcodes the worker subnet's `security_list_ids` and marks that
# attribute `ignore_changes`, so there is no supported, fully-declarative way to
# add a security list to that subnet through the module. We therefore attach it
# out-of-band via the `oci` CLI in a null_resource. Because the module ignores
# `security_list_ids`, it will not revert this on subsequent applies. A
# destroy-time provisioner puts the subnet back on the VCN default security list
# so the weka-data security list detaches and can be deleted cleanly on teardown.

locals {
  # Auth for the out-of-band `oci` CLI calls below, robust across environments:
  #   * config_file_profile set  -> `--profile <p>`            (local run)
  #   * else oci_cli_auth set     -> `--auth <mode>`            (ORM = resource_principal)
  #   * else                      -> no flag                    (Cloud Shell session auth)
  oci_auth_args = (
    var.config_file_profile != null ? "--profile ${var.config_file_profile}" :
    trimspace(var.oci_cli_auth == null ? "" : var.oci_cli_auth) != "" ? "--auth ${var.oci_cli_auth}" :
    ""
  )
}

data "oci_core_vcn" "this" {
  vcn_id = module.oke.vcn_id
}

resource "oci_core_security_list" "weka_data" {
  compartment_id = var.compartment_ocid
  vcn_id         = module.oke.vcn_id
  display_name   = "${var.cluster_name}-weka-data-intra-vcn"

  # Allow all traffic between hosts inside the VCN. This covers the WEKA DPDK
  # data plane running on the non-NSG secondary VNICs. One rule per VCN CIDR.
  dynamic "ingress_security_rules" {
    for_each = data.oci_core_vcn.this.cidr_blocks
    content {
      protocol    = "all"
      source      = ingress_security_rules.value
      source_type = "CIDR_BLOCK"
      description = "Allow all intra-VCN ingress (WEKA data plane)"
    }
  }

  # Egress scoped to the VCN: the WEKA data VNICs only need to reach peers inside
  # the VCN. The primary worker VNICs keep their internet egress via the worker NSG
  # (OCI applies the UNION of NSG + subnet-security-list rules), so image pulls are
  # unaffected. Scoping here avoids an unrestricted-egress (0.0.0.0/0) finding.
  dynamic "egress_security_rules" {
    for_each = data.oci_core_vcn.this.cidr_blocks
    content {
      protocol         = "all"
      destination      = egress_security_rules.value
      destination_type = "CIDR_BLOCK"
      description      = "Allow all intra-VCN egress (WEKA data plane)"
    }
  }

  lifecycle {
    ignore_changes = [defined_tags, freeform_tags]
  }
}

resource "null_resource" "attach_weka_data_seclist" {
  # Re-run the attach if any of these change.
  triggers = {
    subnet_id     = module.oke.worker_subnet_id
    weka_sl_id    = oci_core_security_list.weka_data.id
    default_sl_id = data.oci_core_vcn.this.default_security_list_id
    # Baked into triggers because destroy-time provisioners can only read self.triggers.
    auth_args = local.oci_auth_args
    region    = var.region
  }

  # Attach our security list to the worker subnet. Replaces the empty default
  # seclist; the module ignores security_list_ids, so this persists across applies.
  provisioner "local-exec" {
    command = <<-EOT
      oci network subnet update \
        --subnet-id '${self.triggers.subnet_id}' \
        --security-list-ids '["${self.triggers.weka_sl_id}"]' \
        --force ${self.triggers.auth_args} --region '${self.triggers.region}'
    EOT
  }

  # On teardown, restore the VCN default security list on the subnet so the
  # weka-data security list is unattached and Terraform can delete it.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      oci network subnet update \
        --subnet-id '${self.triggers.subnet_id}' \
        --security-list-ids '["${self.triggers.default_sl_id}"]' \
        --force ${self.triggers.auth_args} --region '${self.triggers.region}' || true
    EOT
  }

  depends_on = [module.oke]
}
