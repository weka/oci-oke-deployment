first# Testing a change before releasing it

The ORM stacks that customers deploy are built by `.github/workflows/release.yml` from a
tag and published as `oke-weka-{dev,prod}.zip`. That pipeline is the *delivery* path, not
the *development* path: a change has to be committed and tagged before it exists in a zip,
which is a slow and public way to discover that a `where` clause is wrong or that a
variable validation blows up on the runner's Terraform.

The `Makefile` closes that loop. It builds a stack zip from the **working tree** —
uncommitted changes included — uploads it to Resource Manager, and drives the job
lifecycle. Nothing here commits, tags, pushes, or publishes anything.

`make help` lists every target with the current knob values.

## Prerequisites

- `oci` CLI authenticated for the tenancy (the Makefile passes `--profile` only when
  `OCI_PROFILE` is set; on a pre-authenticated host such as Cloud Shell, leave it empty).
- `terraform` on PATH, for the local checks.
- An SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`, or
  `SSH_PUBLIC_KEY_FILE=/path/to/key.pub`. It is sent as *content*, because the ORM runner
  has no access to your filesystem.
- quay.io pull credentials for the WEKA operator chart and image.

Export the four values you will reuse across every command:

```bash
export REGION=eu-frankfurt-1
export COMPARTMENT_ID=ocid1.compartment.oc1..<your compartment>
export QUAY_USERNAME='weka.io+<robot>'
export QUAY_PASSWORD='<token>'
```

Every knob uses `?=`, so exported environment values are picked up and the commands stay
short. `REGION` is required by every ORM call; `COMPARTMENT_ID` is required by
`stack-create` and `stack-update` (both regenerate `build/vars.json`).

## Always run the local checks first

```bash
make check      # terraform fmt -check + terraform validate, no cloud calls
```

**`make check` passing does not mean the runner will accept the config.** Two independent
reasons, both of which have already cost a failed apply:

- **`terraform validate` never evaluates `validation` blocks.** A broken variable
  validation is invisible locally and fails the *plan* on the runner.
- **Your local Terraform is not the runner's Terraform.** ORM stacks here are pinned to
  `TF_VERSION = 1.5.x` while a current local install is 1.15.x. Semantics differ: `||`
  does not short-circuit in 1.5, so `var.x == null || var.x >= 6` evaluates `null >= 6`
  and dies with `argument must not be null` — on the runner only. Use
  `coalesce(var.x, <passing value>)` for nullable-number validations.

The plan job is therefore the real check, and it is free. Never go straight to `apply`.

## The loop

```bash
make zip          VARIANT=dev                        # build/oke-weka-dev.zip from the tree
make stack-create VARIANT=dev STACK_NAME=my-dev-test # upload it, create the stack
make plan         VARIANT=dev                        # FREE dry run; also validates schema.yaml
make apply        VARIANT=dev CONFIRM=yes            # spends money
```

`stack-create` runs `zip` and `vars-json` itself, so the first line is only needed when you
want to inspect the zip. Targets can be chained, since make honours goal order:

```bash
make stack-create plan apply VARIANT=dev STACK_NAME=my-dev-test CONFIRM=yes
```

### `VARIANT` belongs on every command

`VARIANT` selects far more than the zip name: `schema-{prod,dev}.yaml` becomes the single
`schema.yaml` in the zip, a dev zip gets `flavor` rewritten to `non-production` directly in
`variables.tf` (a `visible: false` schema default never reaches Terraform), and the stack id
is remembered per variant in `build/.stack-id.$(VARIANT)`.

It defaults to `prod`. Omitting it after building a dev stack therefore targets the wrong
stack, or fails on a missing id file. Both variants can exist simultaneously — that is the
point of the per-variant id file:

```bash
make stack-create plan apply VARIANT=dev  STACK_NAME=weka-oke-dev  CONFIRM=yes
make stack-create plan apply VARIANT=prod STACK_NAME=weka-oke-bare CONFIRM=yes
```

## Bare-metal (`VARIANT=prod`) specifics

Bare-metal testing defaults `TIER` to the 8-node **E4** tier rather than letting
`variables.tf`'s 8-node E5 default apply. E5 DenseIO in eu-frankfurt-1 is routinely short:
an 8 × E5 apply failed with `Out of host capacity` after launching 6 of 8 hosts. E4 has
filled every request so far. This only sets a stack *input* for test stacks; the shipped
default is unchanged.

Note that `capacity.tf`'s preflight cannot catch this. The compute capacity report exposes
a per-AD `availability_status` only, never a host **count**, so "6 of 8 available" reads as
`AVAILABLE` and the gate passes moments before `LaunchInstance` fails.

If even 8 × E4 is short, shrink the cluster instead of the shape:

```bash
make stack-create plan apply VARIANT=prod NODES=6 CONFIRM=yes
```

`NODES` sets `production_node_count`, which overrides the count the tier implies while
keeping its shape and per-node drives. 6 hosts derives 3+2+1, WEKA's minimum viable
layout. The tier's advertised capacity no longer applies, and `weka_sizing` says so.

To test a specific capacity instead, pass `TIER` explicitly, or `TIER=''` to fall back to
the Terraform default:

```bash
make stack-create VARIANT=prod TIER='955 TB usable - 16 x BM.DenseIO.E5.128 (12 NVMe)'
```

`production_tier` and `node_count` are frozen by `guard.tf` after the first apply, so
changing either needs a **new** stack. `production_node_count` is deliberately *not*
frozen — changing it on a live stack will destroy and replace workers.

## Verifying a deploy

```bash
make outputs VARIANT=dev     # stack outputs, incl. the ready-to-run kubeconfig command
oci ce cluster create-kubeconfig --cluster-id <ocid> --file ~/kube-weka.yaml \
  --region "$REGION" --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT
export KUBECONFIG=~/kube-weka.yaml

kubectl get nodes
kubectl get wekapolicy,wekacluster,wekaclient -n default
kubectl get pods -n default
```

A healthy cluster ends at `wekacluster … Ready` with every drive, compute and client pod
`Running`.

### ensure-nics (non-production only)

`status.result` is an escaped JSON *string*, so `grep '"ensured":true'` silently matches
nothing. Parse it:

```bash
kubectl get wekapolicy ensure-nics-policy -n default -o json | python3 -c "
import json,sys
st=json.load(sys.stdin)['status']
r=json.loads(st['result'])['results']
print('status:', st.get('status'))
for node,v in sorted(r.items()):
    print(f'  {node:16} ensured={v[\"ensured\"]} nics={len(v[\"nics\"])} err={v[\"err\"]}')"
```

Expect `Done` with `ensured=True` and `nics` equal to `dataNICsNumber` in
`crds/02-ensure-nics-policy.yaml` on every node.

Getting there is noisy and that is normal. `cloud-helper` fires concurrent `AttachVnic`
calls per instance, collects `409 Conflict — instance is currently being modified`, and
aborts the whole run; the operator restarts the pod and it converges, typically inside two
minutes. A `409` is a conflict, **not** a denial — do not read it as an IAM problem. Allow
2–4 minutes for IAM propagation after an apply before treating an actual authorization
error as real.

### Confirming the flavor gates

The ensure-nics IAM policy and the ensure-nics CR are both keyed off
`local.ensure_nics_policy`, so they must appear together or not at all:

```bash
oci iam policy       list --compartment-id "$COMPARTMENT_ID" --all \
  --query "data[?contains(name,'weka-ensure-nics')].name"
oci iam dynamic-group list --all --query "data[?contains(name,'oke-workers')].name"
```

- **`VARIANT=dev`** — `weka-ensure-nics-<state_id>` and `oke-workers-<state_id>` both
  exist, and `02-ensure-nics-policy.yaml` is among the applied CRs.
- **`VARIANT=prod`** — neither exists, and the plan contains no
  `oci_identity_policy.weka_ensure_nics` and no `02-ensure-nics-policy.yaml`. Bare metal
  uses pre-attached NICs selected by subnet, so the Core API is never called. Check this in
  the *plan*, before spending on DenseIO.

## When a job fails

```bash
make status VARIANT=dev     # last job's state
make logs   VARIANT=dev     # full log for the last job
```

`wait-job` prints logs automatically on `FAILED`. For a job the Makefile is no longer
tracking:

```bash
oci resource-manager job list --stack-id <stack ocid> \
  --query 'data[].{op:operation,state:"lifecycle-state",id:id}' --output table
oci resource-manager job get-job-logs-content --job-id <job ocid> --raw-output
```

Errors are wrapped in JSON with escaped newlines, so pipe through
`python3 -c "import sys;print(sys.stdin.read().replace('\\\\n','\n'))"` before grepping.

| Failure | Meaning |
| --- | --- |
| `argument must not be null` at a `validation` block | 1.5.x semantics — see the local-checks caveat above |
| `Out of host capacity` from `LaunchInstance` | DenseIO shortage; switch to E4 or lower `NODES` |
| `production_tier is immutable after first apply` | `guard.tf`; deploy a new stack |
| `403 node not authorized` at `:12250/workerNodeBootstrap` | missing CLUSTER_JOIN — see TROUBLESHOOTING.md §8 |
| `authorization error … operation: GetVnic` | missing VNIC IAM — see `iam_weka.tf` |

## Iterating without recreating the stack

```bash
make stack-update VARIANT=dev     # push the current tree AND variables to the same stack
make plan         VARIANT=dev
```

`stack-update` regenerates `build/vars.json`, so it needs `COMPARTMENT_ID` and the quay
credentials again. To push *only* config and leave the stack's stored variables untouched:

```bash
oci resource-manager stack update --stack-id "$(cat build/.stack-id.dev)" \
  --config-source build/oke-weka-dev.zip --force
```

To point the Makefile at a stack it did not create:

```bash
make stack-adopt VARIANT=dev STACK_ID=ocid1.ormstack...
```

A fresh stack is the cleanest way to test a WekaCluster CR change, because updating a stack
behind a *healthy* cluster patches a live CR in place — a different and less understood code
path. That caveat does not apply to a cluster that never formed: there is nothing working to
disturb, and reusing its stack avoids competing for scarce DenseIO capacity.

## Teardown

```bash
make destroy      VARIANT=dev CONFIRM=yes
make stack-delete VARIANT=dev
```

**Destroy before deleting.** Deleting a stack removes the stack object and its
Terraform state only — never the resources. Everything it built keeps running and keeps
billing, with no state left to tear it down as a unit. The stray
`weka-ensure-nics-qkhawm` policy in this tenancy, whose dynamic group no longer exists, is
what that looks like weeks later.

`make stack-create` overwrites `build/.stack-id.$(VARIANT)`, so tear down the current stack
*before* creating another one of the same variant — otherwise the pointer is gone and
cleanup becomes a console job. If you need to keep resources but stop managing them, export
the state first:

```bash
oci resource-manager stack get-stack-tf-state --stack-id <ocid> --file saved.tfstate
```

## What never reaches a release

`make zip` excludes `.git/`, `.github/`, `.terraform/`, tfstate, `terraform.tfvars`,
`build/`, and strips `Makefile`, `TESTING.md` and both `schema-*.yaml` variants from the
staged tree. So the testing harness cannot leak into a customer zip, and the only
release-visible artifacts are the ones the release workflow produces.

`build/` is gitignored because `vars-json` writes your quay password into
`build/vars.json` (mode 600). Never commit it, and prefer exporting `QUAY_PASSWORD` over
passing it on the command line, where it lands in shell history and the process list.
