# oke-infra — OKE cluster for WEKA (Stack 1)

Terraform for a managed **OKE** cluster on OCI, built on the upstream
[`terraform-oci-oke`](https://github.com/oracle-terraform-modules/terraform-oci-oke) module
(v5.5.0). It stands up a converged OKE node pool prepared for WEKA (hugepages, DenseIO local NVMe,
and the intra-VCN data-plane security list). The WEKA operator + custom resources are layered on
afterwards by the sibling [`../weka-layer`](../weka-layer) stack.

Sizing/topology have working defaults; the account-specific values (`tenancy_id`, `compartment_id`)
are required inputs. By default the module builds a **fresh VCN**.

## Files

| File | Purpose |
|---|---|
| `providers.tf` | Terraform + the two required `oci` providers (default + `oci.home` alias) |
| `variables.tf` | All inputs (required: `tenancy_id`, `compartment_id`) |
| `main.tf` | The `terraform-oci-oke` module block (VCN, cluster, converged node pool + WEKA node prep) |
| `weka_data_network.tf` | Intra-VCN data-plane security list + attach to the worker subnet |
| `outputs.tf` | `cluster_id`, `region`, `cluster_endpoints`, a ready-to-run `create_kubeconfig` command |
| `schema.yaml` | OCI Resource Manager Console variable form |
| `terraform.tfvars.example` | Copy to `terraform.tfvars`; required vars + how to reuse an existing VCN |

## Auth (works in the ORM runner, Cloud Shell, or local)

The oci Terraform provider uses `config_file_profile` (null in ORM → ORM-injected credentials).
The one `oci` CLI call — the worker-subnet security-list attach in `weka_data_network.tf` — picks
its auth from **`oci_cli_auth`** (default `""` = no `--auth` flag; the environment authenticates):

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |
| operator host | `oci_cli_auth = "instance_principal"` | `--auth instance_principal` |

> **Verified:** the ORM runner ships the `oci` CLI and is pre-authenticated, so the attach works
> with no `--auth` flag (it does **not** support `--auth resource_principal`). Cloud Shell is identical.

**SSH key:** provide `ssh_public_key` (content) in the ORM runner (no local files there); locally,
set `ssh_public_key_path` (e.g. `~/.ssh/id_rsa.pub`) and it is used when content is null. Both
default to null, so SSH is optional — leave both empty for no node SSH access.

## Prerequisites

- `terraform` >= 1.3, the `oci` CLI, and (for local runs) a working `~/.oci/config`.
- Optional: an SSH public key — paste content into `ssh_public_key`, or set `ssh_public_key_path` (e.g. `~/.ssh/id_rsa.pub`) for local runs.

## Usage (local / Cloud Shell)

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in tenancy_id + compartment_id (+ profile)
terraform init
terraform apply

terraform output -raw create_kubeconfig_command | bash
export KUBECONFIG=~/weka-oke.yaml
export OCI_CLI_PROFILE=DEFAULT
kubectl get nodes
```

Expect **~13–16 min** (the control plane is the long pole). The control-plane endpoint is public by
default (`control_plane_allowed_cidrs = ["0.0.0.0/0"]`, tighten for real use).

## Usage (Resource Manager)

1. Create a stack from this folder — upload a `.zip` of `stacks/oke-infra/` or point ORM at this
   repo via a configuration source provider (set the working directory to `stacks/oke-infra`).
2. `schema.yaml` renders the variable form; fill in compartment, cluster, and worker sizing.
3. Run **Plan**, then **Apply**. Leave `config_file_profile` unset. Because of the CLI attach, run
   the stack from Cloud Shell if the runner errors on the `oci` step.

### WEKA node prep (built in)

WEKA has three requirements the stock module doesn't provide, all handled here:

- **hugepages** — via the worker pool's cloud-init (`node_hugepages`, default 8000 × 2Mi).
- **drives** — a managed OKE node pool can't attach data block volumes via Terraform, so the default
  shape is `VM.DenseIO.E5.Flex` (local NVMe), which the WEKA operator's sign-drives policy discovers
  as `weka.io/drives`. That shape accepts fixed OCPU:memory:NVMe combos (1 NVMe per 8 OCPU); the
  default 8 OCPU / 96 GB yields 1 NVMe per node (smallest DenseIO tier — also the easiest to place
  against DenseIO host-capacity limits). Bump `node_ocpus`/`node_memory_gb` for more drives/cores.
- **data-plane security** (`weka_data_network.tf`) — WEKA's ensure-nics attaches a secondary "data"
  VNIC per IO node with **no NSG**, but the module puts all intra-cluster allow rules on the worker
  NSG (scoped to NSG membership) and leaves the worker subnet on an empty default security list.
  Without a fix the DPDK data plane gets no allow coverage, backends never join, and the cluster
  hangs in `Init`. This file attaches a security list allowing all intra-VCN traffic to the worker
  subnet (a subnet security list covers every VNIC regardless of NSG membership). Because the module
  marks the subnet's `security_list_ids` `ignore_changes`, the attach is done via the `oci` CLI in a
  `null_resource`.

## Layering WEKA on top

This stack provisions the **cluster only**. Once `kubectl get nodes` works, install the WEKA layer:

- **Preferred (Terraform):** the [`../weka-layer`](../weka-layer) stack — operator + pull secrets +
  WekaPolicy/WekaCluster/WekaClient. Feed it this stack's `cluster_id` and `region` outputs.
- **Fallback (manual):** `../../scripts/install-weka-operator.sh` + `kubectl apply -f ../../crds/`.

## Teardown

```bash
terraform destroy
```

OKE clusters do **not** auto-expire — destroy explicitly to free quota. A DenseIO node pool can
occasionally have a slow/stuck node termination; re-run `terraform destroy` if it errors out.
(Destroy `../weka-layer` first if you installed it.)
