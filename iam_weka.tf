# ---------------------------------------------------------------------------
# IAM for WEKA's ensure-nics (VM / non-bare-metal deploys only).
#
# WHY THIS EXISTS
# ---------------
# On VMs there are no pre-attached data NICs, so WEKA runs the ensure-nics policy:
# `cloud-helper ensure-nics` calls the OCI Core API under the WORKER NODE's
# instance principal to create one secondary VNIC per IO node. The module's own IAM
# grants those workers exactly one permission — {CLUSTER_JOIN}, scoped to the
# cluster — and nothing on the network family. So every ensure-nics pod dies with:
#
#   {"cloud":"oci","error_code":"UnknownError",
#    "error":"authorization error: Authorization failed or requested resource
#             not found., operation: GetVnic"}
#
# and the whole WEKA layer stalls behind it: no NICs created -> no
# weka.io/weka-nics advertised -> drive/compute pods sit Pending on
# "Insufficient weka.io/weka-nics" while the WekaCluster stays in Init.
#
# BARE METAL DOES NOT NEED THIS. There the NICs already exist and WEKA selects
# them by subnet (spec.network.selectors, see weka.tf), so ensure-nics is not
# applied and no Core API call is ever made. Granting the permission there would
# only authorize a mechanism we deliberately do not use.
#
# WHY A POLICY BUT NO DYNAMIC GROUP
# ---------------------------------
# The module already creates the worker dynamic group (oke-workers-<state_id>)
# whenever create_iam_resources is on, which is precisely instance-pool mode. We
# reference it by its deterministic name instead of creating a second group that
# would match the same instances. The count below is gated on instance-pool mode
# so the policy is never created in a mode where that group does not exist, and
# does not sit in the compartment granting VNIC permissions to a principal set
# that never materializes.
#
# OCI does NOT reject a policy naming a group that does not exist yet. Verified on
# a fresh apply, where this policy was created 131 ms BEFORE the group it names
# (08:49:10.649 vs 08:49:10.780) and was accepted — statements resolve by name at
# authorization time, not at policy creation. So ordering is not a correctness
# requirement, but getting it right was pure luck: interpolating the group NAME
# creates no dependency edge. The precondition on the resource adds one.
#
# Policies are identity resources, so this uses the oci.home provider, like the
# module's own IAM. instance-pool deploys already require the deploying principal
# to manage dynamic groups + policies (see the create_iam_resources note in
# main.tf), so this adds no new privilege requirement.
# ---------------------------------------------------------------------------

locals {
  # The module creates the worker dynamic group only in instance-pool mode, and
  # ensure-nics only runs off bare metal. Both must hold for this policy to be
  # both needed and valid.
  weka_ensure_nics_iam = local.ensure_nics_policy && local.worker_mode == "instance-pool"

  # Deterministic name from the module (modules/iam/group-workers.tf):
  #   worker_group_name = format("oke-workers-%v", var.state_id)
  oke_worker_dynamic_group = "oke-workers-${module.oke.state_id}"
}

resource "oci_identity_policy" "weka_ensure_nics" {
  count    = local.weka_ensure_nics_iam ? 1 : 0
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "weka-ensure-nics-${module.oke.state_id}"
  description    = "Lets WEKA worker nodes create the secondary data VNICs that ensure-nics needs (non-bare-metal deploys)."

  # ensure-nics CREATES a secondary VNIC and ATTACHES it. AttachVnic is a single
  # API call that checks FOUR permissions spread across two resource families, and
  # granting three of them fails as completely as granting none:
  #
  #   VNIC_CREATE                      -> virtual-network-family (vnics)
  #   VNIC_ATTACH                      -> virtual-network-family (vnics)
  #   SUBNET_ATTACH                    -> virtual-network-family (subnets)
  #   INSTANCE_ATTACH_SECONDARY_VNIC   -> instances, `manage` VERB ONLY
  #
  # TWO TRAPS, both of which cost real debugging time — do not "simplify" this:
  #
  #   1. `use instance-family` does NOT include INSTANCE_ATTACH_SECONDARY_VNIC.
  #      That permission exists only at the `manage` verb on `instances`. This is
  #      why granting the network family alone gets GetVnic working and then dies
  #      on AttachVnic with 404 NotAuthorizedOrNotFound — read-level calls succeed,
  #      so it LOOKS like progress.
  #
  #   2. `manage vnic-attachments` is a NO-OP here, despite the REST path being
  #      POST /20160918/vnicAttachments. That resource-type carries only
  #      VNIC_ATTACHMENT_READ. OCI accepts the statement silently and grants
  #      nothing. (Likewise: VNIC_ATTACHMENT_CREATE and INSTANCE_ATTACH_VNIC are
  #      not real permission names.)
  #
  # The `where any {request.permission=...}` condition is what makes `manage
  # instances` safe: it admits exactly the two VNIC permissions and withholds the
  # rest of the manage verb — INSTANCE_DELETE above all. Plain `manage instances`
  # or `manage instance-family` would let any compromised worker pod terminate
  # every instance in the compartment.
  #
  # VERIFIED: this exact pair of statements took all 6 nodes of a dev cluster to
  # `ensured: true` with 5 data NICs each (36/36 VNIC attachments) and the
  # WekaPolicy to Done. Transient "Conflict — instance is currently being
  # modified" errors appear during convergence because cloud-helper issues
  # concurrent AttachVnic calls per instance; retries clear them in ~2 minutes.
  #
  # NOT DONE, deliberately: the network grant could narrow further to `use vnics`
  # plus `use subnets ... where target.subnet.id = <worker subnet>`. That matches
  # the permission table but has never been exercised end to end, and a wrong
  # guess here costs a full apply cycle to discover. Narrow it as its own change,
  # with its own verification.
  #
  # Allow 2-4 minutes for IAM propagation after this policy is created. ensure-nics
  # pods that start inside that window fail and crashloop; the operator retries and
  # they converge on their own.
  statements = [
    "Allow dynamic-group ${local.oke_worker_dynamic_group} to use virtual-network-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${local.oke_worker_dynamic_group} to manage instances in compartment id ${var.compartment_ocid} where any {request.permission='INSTANCE_ATTACH_SECONDARY_VNIC', request.permission='INSTANCE_DETACH_SECONDARY_VNIC'}",
  ]

  # Order the policy AFTER the module's dynamic groups. The statements above name
  # the worker group by interpolated string, which creates no dependency on the
  # group resource, so Terraform is otherwise free to create this first.
  #
  # Reading the module's IAM output is what adds the edge. Deliberately NOT
  # depends_on = [module.oke]: that would also wait for the cluster, the instance
  # pool and the whole WEKA layer, pushing the grant to the very end of the apply —
  # exactly backwards, since IAM takes 2-4 minutes to propagate and the nodes start
  # calling AttachVnic as soon as the operator schedules ensure-nics. Depending on
  # the groups alone keeps the policy early (more propagation headroom) while still
  # guaranteeing its principal exists.
  #
  # The condition doubles as a guard: an empty list means the module created no IAM
  # at all, so oke-workers-<state_id> is not there to grant to.
  lifecycle {
    precondition {
      condition     = try(length(module.oke.dynamic_group_ids), 0) > 0
      error_message = "module.oke created no IAM dynamic groups, so the OKE worker dynamic group this policy grants to does not exist. Check create_iam_resources in main.tf."
    }
  }
}
