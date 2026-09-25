# Guidelines

## Scope of a change

Fix what was asked, and only that. Unrelated problems you notice along the way
stay untouched — even obvious ones, even one-line ones. Mention them and offer
to open a ticket instead.

A change is in scope only if the requested fix does not work without it.

## After any code change

Run `/simplify` once the change is complete and working. Not after each edit —
after the change as a whole.

## Commit messages

One line. No body, no bullet list, no trailing explanation — if the change needs
more words than a single subject line, those words belong in the PR description,
the code, or a comment, not in the commit.

Existing history is the bar: `fix: grant OKE workers the IAM to attach WEKA data
VNICs on VM deploys`.

## Comments

Keep them minimal. Write a comment only when the code cannot be made obvious on
its own: a non-obvious OCI/ORM constraint, a deliberate omission, a workaround
whose reason isn't visible in the diff. Do not comment what the code already
says.

Existing comments in `variables.tf` that explain *why* a default is what it is
(e.g. `region` having no default on purpose) are the bar — they carry
information the reader cannot recover from the code.

## Terraform defaults must match the stack defaults

A `terraform apply` with no tfvars must produce the same deployment as the ORM
stack with every field left untouched. So for any variable that carries a
`default:` in `schema-prod.yaml` or `schema-dev.yaml`, the `default` in
`variables.tf` must be identical.

Currently paired: `operator_version`, `production_tier`, `node_count`,
`skip_capacity_preflight`, `control_plane_is_public`, `create_vcn`.

Change one, change the other in the same commit.

The single intentional exception is `flavor`: `variables.tf` defaults to
`production` (what the production zip ships), and `schema-dev.yaml` overrides it
to `non-production`. Leave that asymmetry alone.
