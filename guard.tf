# ---------------------------------------------------------------------------
# Immutable-after-first-apply guard.
#
# ORM has no "read-only after create" for form fields — schema.yaml renders the
# SAME form on Create and Edit, so a re-apply can carry a changed value. We freeze
# the destructive inputs at the Terraform level instead:
#   - input_lock snapshots them on the FIRST apply and never updates the snapshot
#     (lifecycle.ignore_changes on `input` pins .output to the create-time value).
#   - input_guard's preconditions compare the current var to that snapshot and
#     HARD-FAIL any later apply whose value drifted — the plan aborts before a
#     single resource is touched, so nothing is destroyed or replaced.
#
# Frozen (changing any would destroy/replace instances or force-replace the cluster):
#   flavor                  — pinned per zip anyway (prod vs dev)
#   production_tier         — chosen capacity => worker instance type + node count
#   node_count              — non-production node count
#   create_vcn / vcn_id     — VCN topology
#   control_plane_is_public — public<->private force-replaces the cluster/endpoint
# Left editable after apply: quay_username, quay_password, operator_version.
# ---------------------------------------------------------------------------
resource "terraform_data" "input_lock" {
  input = {
    flavor                  = var.flavor
    production_tier         = var.production_tier
    node_count              = var.node_count
    create_vcn              = var.create_vcn
    vcn_id                  = coalesce(var.vcn_id, "none")
    control_plane_is_public = var.control_plane_is_public
  }

  # Written once, on create, and never updated — the frozen baseline.
  lifecycle {
    ignore_changes = [input]
  }
}

resource "terraform_data" "input_guard" {
  # No input; exists only to host the preconditions, which are re-evaluated every
  # plan and abort the apply when a locked value no longer matches the snapshot.
  lifecycle {
    precondition {
      condition     = var.flavor == terraform_data.input_lock.output.flavor
      error_message = "flavor is immutable after first apply (locked to '${terraform_data.input_lock.output.flavor}')."
    }
    precondition {
      condition     = var.production_tier == terraform_data.input_lock.output.production_tier
      error_message = "production_tier is immutable after first apply (locked to '${terraform_data.input_lock.output.production_tier}'). Changing it changes the worker instance type/count and would destroy instances — deploy a new stack for a different capacity."
    }
    precondition {
      condition     = var.node_count == terraform_data.input_lock.output.node_count
      error_message = "node_count is immutable after first apply (locked to ${terraform_data.input_lock.output.node_count}). Changing it would destroy/replace worker instances."
    }
    precondition {
      condition     = var.create_vcn == terraform_data.input_lock.output.create_vcn
      error_message = "create_vcn is immutable after first apply (locked to ${terraform_data.input_lock.output.create_vcn}). Changing the VCN topology would tear down networking."
    }
    precondition {
      condition     = coalesce(var.vcn_id, "none") == terraform_data.input_lock.output.vcn_id
      error_message = "vcn_id is immutable after first apply. Changing the VCN would tear down networking."
    }
    precondition {
      condition     = var.control_plane_is_public == terraform_data.input_lock.output.control_plane_is_public
      error_message = "control_plane_is_public is immutable after first apply (locked to ${terraform_data.input_lock.output.control_plane_is_public}). Flipping public<->private force-replaces the cluster."
    }
  }
}
