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
#   capacity_reservation_ids — one worker pool per reservation, so adding or
#                             removing one adds or destroys a whole pool
# Left editable after apply: quay_username, quay_password, operator_version.
# ---------------------------------------------------------------------------
resource "terraform_data" "input_lock" {
  input = {
    flavor          = var.flavor
    production_tier = var.production_tier
    node_count      = var.node_count
    create_vcn      = var.create_vcn
    vcn_id          = coalesce(var.vcn_id, "none")
    # Normalised so whitespace or reordering is not read as a change.
    capacity_reservation_ids = join(",", sort(local.capacity_reservation_ids))
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
    # try(): ignore_changes freezes the snapshot's SHAPE too, so a stack created
    # before this key existed has no such attribute and a bare lookup would error
    # on every plan. Those stacks predate reservations, so "" is the right value.
    precondition {
      condition     = join(",", sort(local.capacity_reservation_ids)) == try(terraform_data.input_lock.output.capacity_reservation_ids, "")
      error_message = "capacity_reservation_ids is immutable after first apply (locked to '${try(terraform_data.input_lock.output.capacity_reservation_ids, "")}'). Each reservation backs its own worker pool, so changing the set would destroy or replace nodes — deploy a new stack instead."
    }
  }
}
