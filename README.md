# oci-oke-deployment — WEKA on OKE

Terraform that stands up a managed **OKE** cluster on OCI and layers **WEKA** (operator +
custom resources) on top in a **single apply**, delivered as an **OCI Resource Manager (ORM)**
stack so the whole path — *OKE creation → operator setup* — is Infrastructure-as-Code.

<!-- Works once the repo is public and a vX.Y.Z release is tagged (see .github/workflows/release.yml). -->
The stack ships as two zips built from the same Terraform (they differ only in the bundled
`schema.yaml`, generated from `schema-prod.yaml` / `schema-dev.yaml`) — pick one:

- **Production** — local-NVMe `BM.DenseIO.E5.128`, fixed capacity options 367 TB → 10 PB (`production_tier`):
  [![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-prod.zip)
- **Dev / non-production** — block-volume drives, instance count (`node_count`):
  [![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-dev.zip)

Licensed under **Apache-2.0** (see [LICENSE](LICENSE)). Security notes and the accepted IaC
posture are in [SECURITY.md](SECURITY.md).

One apply does the whole thing:

1. OKE cluster + converged node pool (hugepages, local NVMe, WEKA node prep)
2. the intra-VCN data-plane security-list fix (`weka_data_network.tf`)
3. the WEKA operator (Helm), quay.io image pull secrets, and the
   WekaPolicy / WekaCluster / WekaClient custom resources (`weka.tf`)

Sizing, networking, and the API-endpoint visibility are **frozen after the first apply**
(a change would destroy/replace instances); only the quay.io creds and operator version
stay editable. See [`guard.tf`](guard.tf).

## Layout

The repo **is** the stack — every `.tf` at the root is part of one Terraform configuration:

| File | Purpose |
|---|---|
| `providers.tf` | Terraform + `oci` (default + `oci.home`), `helm`, `kubernetes`, `kubectl` providers |
| `variables.tf` | All inputs (required: `tenancy_id`, `compartment_id`, quay.io creds) |
| `main.tf` | The `terraform-oci-oke` module block (VCN, cluster, node pool + WEKA node prep) |
| `capacity.tf` | Preflight that checks DenseIO shape availability per AD before building |
| `weka_data_network.tf` | Intra-VCN data-plane security list + attach to the worker subnet |
| `weka.tf` | Operator namespace, pull secrets, `helm_release`, and the WEKA custom resources |
| `guard.tf` | Lifecycle guards that freeze sizing/network inputs after the first apply |
| `outputs.tf` | `cluster_id`, `region`, `weka_sizing`, a ready-to-run `create_kubeconfig` command |
| `schema-prod.yaml` / `schema-dev.yaml` | ORM Console variable forms; one becomes `schema.yaml` per zip |
| `crds/` | WEKA custom resource manifests (`03-wekacluster.yaml` is a rendered `templatefile`) |

## How the single apply works

- The `oci` (+ `oci.home`) providers build the cluster via the `terraform-oci-oke` module.
- The `kubernetes`/`helm`/`kubectl` providers connect to the cluster **created in this same apply**:
  their endpoint/CA come from `module.oke` outputs (`cluster_endpoints` / `cluster_ca_cert`, with
  `output_detail = true`) **frozen into a `terraform_data` resource** so the values are state-backed
  and still resolve during `destroy` (a kube-config *data source* cannot — see
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §3). The API token is minted by the
  `oci ce cluster generate-token` exec plugin.
- Workers are bootstrapped by the **module's own cloud-init** (`disable_default_cloud_init = false`) —
  required so self-managed instance-pool (non-production) nodes join; WEKA node tuning is layered as a
  supplementary `cloud_init` part (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §1).
- A `null_resource.wait_for_kube_api` gate makes the WEKA layer wait until the API endpoint is
  actually reachable, and the WEKA resources `depends_on = [module.oke]`, so the operator install
  waits until the cluster, workers, and the network fix are all done.

> **Hit a failure?** See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — the common ones (0 nodes, Helm
> `context deadline exceeded`, `destroy` stuck) all have documented root causes and fixes.

## Running in Resource Manager (and the one dependency)

[OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resource-manager-and-terraform.htm)
runs Terraform as a managed service: it stores + locks state, versions your config, injects
resource-principal credentials, and renders a Console variable form from `schema.yaml`.

**kubectl and helm are not binaries here — they are the Terraform providers** (`hashicorp/helm`,
`hashicorp/kubernetes`, `gavinbunney/kubectl`), which `terraform init` downloads into whatever runs
the apply. The **only** external tool the stack needs is the **`oci` CLI**, for two calls: the
worker-subnet security-list attach, and minting the OKE API token (there is no provider-native OKE
token — `oci_containerengine_cluster_token` does not exist in the provider, so that call is
unavoidable).

Auth is picked automatically via the **`oci_cli_auth`** variable (default `""` — no `--auth` flag;
the environment is already authenticated):

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** (Console one-click) | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |
| operator/compute host | `oci_cli_auth = "instance_principal"` | `--auth instance_principal` |

**Verified against a live ORM runner (us-phoenix-1):** the managed runner ships `oci`, `kubectl`,
and `helm`, and is pre-authenticated with a delegation token — so `oci` with **no `--auth` flag**
works (note: `--auth resource_principal` does **not** — no RP env there). In the ORM runner, provide
the SSH key as **content** (`ssh_public_key`) — there are no local files on the runner.

## One-click in Resource Manager

1. **Resource Manager → Stacks → Create stack** from one of the release zips above (or a
   source-control config provider pointed at this repo — the working directory is the repo root).
2. Fill the form (`schema.yaml`): compartment, **quay.io creds**, SSH key (paste content), and
   sizing. In the **production** zip you pick a **capacity** (`production_tier`) — every option is
   a `BM.DenseIO.E5.128` cluster (12 × 6.8 TB local NVMe per node), so the value simply fixes the
   node count:

   | Option (the value itself) | Nodes | Protection |
   |---|---|---|
   | `367 TB usable - 8 x BM.DenseIO.E5.128 (12 NVMe)` | 8 | `5+2+1` |
   | `661 TB usable - 12 x BM.DenseIO.E5.128 (12 NVMe)` | 12 | `9+2+1` |
   | `955 TB usable - 16 x BM.DenseIO.E5.128 (12 NVMe)` | 16 | `13+2+1` |
   | `1.2 PB usable - 21 x BM.DenseIO.E5.128 (12 NVMe)` | 21 | `16+4+1` |
   | `2` / `3` / `4` / `5` / `6` / `7` / `8` / `9` / `10 PB usable - N x BM.DenseIO.E5.128 (12 NVMe)` | 35 / 52 / 69 / 86 / 103 / 120 / 137 / 154 / 171 | `16+4+1` |

   Above 21 nodes each **+17 nodes adds ~1 PB** usable, up to 10 PB at 171 nodes; for more than
   that, deploy a separate cluster.
   Each NVMe drive is 6.8 TB; the capacity shown is WEKA usable after protection and filesystem
   overhead, and the derived scheme + capacity is printed as the `weka_sizing` output. In the **dev**
   zip you instead set an instance count (`node_count`, min 6); WEKA drives come from a per-node block
   volume. The capacity choice / count is **frozen after the first apply** — deploy a new stack for a
   different capacity.
3. **Plan**, then **Apply**. When it finishes, the cluster is up *and* WEKA is installed.

## Local / Cloud Shell

```bash
cp terraform.tfvars.example terraform.tfvars   # tenancy_id, compartment_id, quay creds (+ profile for local)
terraform init && terraform apply              # ~15–20 min: cluster + WEKA
terraform output -raw create_kubeconfig_command | bash
export KUBECONFIG=~/weka-cluster.yaml
kubectl get pods -n weka-operator-system       # operator Running
kubectl get wekacluster dev -n default -w      # forms → healthy
```

Teardown is `terraform destroy` (or an ORM **Destroy** job). OKE clusters do **not** auto-expire and
DenseIO nodes burn quota — destroy explicitly when done.

## Testing in Resource Manager via the CLI

You can drive the whole ORM lifecycle from the `oci` CLI (no Console clicks). Replace `<C>`/`<T>`
with your compartment/tenancy OCIDs, `<PUBKEY>` with your SSH public key **content**, and use a
working `--profile`.

```bash
# Build a stack zip the same way the release workflow does: the repo root, minus
# scaffolding, the raw schema variants, and local-only artifacts.
cp schema-prod.yaml schema.yaml                  # or schema-dev.yaml
zip -qr /tmp/stack.zip . \
  -x '.git/*' '.github/*' 'schema-prod.yaml' 'schema-dev.yaml' \
     '.terraform/*' '*.tfstate*' 'terraform.tfvars' '*.auto.tfvars' 'orm-vars.json'

printf '{"tenancy_id":"<T>","compartment_id":"<C>","region":"us-phoenix-1","ssh_public_key":"<PUBKEY>","quay_username":"%s","quay_password":"%s"}' \
      "$QUAY_USERNAME" "$QUAY_PASSWORD" > /tmp/vars.json

S=$(oci resource-manager stack create --compartment-id <C> --config-source /tmp/stack.zip \
      --terraform-version 1.5.x --variables file:///tmp/vars.json --display-name weka-oke \
      --region us-phoenix-1 --query 'data.id' --raw-output)
J=$(oci resource-manager job create-apply-job --stack-id $S --execution-plan-strategy AUTO_APPROVED \
      --region us-phoenix-1 --query 'data.id' --raw-output)
# poll until SUCCEEDED:
oci resource-manager job get --job-id $J --query 'data."lifecycle-state"' --raw-output
# logs if needed: oci resource-manager job get-job-logs-content --job-id $J --raw-output

# --- Teardown ---
oci resource-manager job create-destroy-job --stack-id $S --execution-plan-strategy AUTO_APPROVED \
  --region us-phoenix-1 --query 'data.id' --raw-output    # poll to SUCCEEDED
oci resource-manager stack delete --stack-id $S --force --region us-phoenix-1
```

Notes:
- The zip must **exclude** `terraform.tfvars` / state / `.terraform/` — pass values via `--variables`
  and leave `config_file_profile`/`oci_cli_auth` unset so the runner authenticates itself.
- `--terraform-version 1.5.x` is what the runner accepts; a Plan job (`create-plan-job`) is a free
  dry run that validates the config + `schema.yaml` before you apply.

## Security posture (accepted)

The OKE API endpoint is **public and reachable from `0.0.0.0/0`** — not for laptop `kubectl`, but
because this stack installs WEKA over the Kubernetes API **from the ORM / Marketplace runner, which
is outside your VCN**, so the endpoint must be reachable for the install to succeed. The endpoint is
still **token-authenticated** (short-lived OCI/OKE tokens). This is an accepted, documented default
(see [`SECURITY.md`](SECURITY.md)).

**Hardening (optional, not implemented here):** for a fully private control plane, install WEKA from
**inside the VCN** — enable the module's operator host (`create_operator = true`) and run the Helm
install + `kubectl apply` from it via cloud-init, then set `control_plane_is_public = false`. That
removes the public endpoint entirely at the cost of an always-on operator VM and dropping the
in-stack helm/kubectl providers for the WEKA layer.

## Caveats

- **Same-apply provider auth** (k8s providers targeting a cluster built in the same run) is the
  standard OKE/EKS/GKE one-click pattern and works, but it's more fragile on *replacement* — if you
  ever recreate the cluster, prefer a two-phase `terraform apply` (`-target=module.oke` first, then
  a full apply) over recreating everything in one shot.
- **DenseIO capacity:** the production shape (`BM.DenseIO.E5.128`) is frequently
  *out-of-host-capacity*. A `capacity.tf` preflight checks every AD before building and
  fails early with guidance. Note it only reports whether the shape is available in an AD, **not
  whether N hosts are free** — the multi-PB options need tens to hundreds of bare-metal hosts, so
  confirm quota/capacity with Oracle before picking one. If an apply still fails, choose a smaller
  capacity option, pin ADs via `worker_placement_ads`, or try another region/AD. (This is an OCI
  availability constraint, not a config issue.)
- **Bare metal:** the module omits `shape_config` for non-Flex shapes automatically, so OCPU/memory
  are shape-fixed (128 cores); provisioning takes longer (bare-metal first boot). `driveCores` is
  set from a safe default — revisit it for throughput tuning at the largest capacities.
- **Bare-metal data plane:** on bare metal the data NICs are already attached, so WEKA selects them
  **by subnet** — `spec.network.selectors` on both the WekaCluster and the WekaClient, filled with
  the worker subnet the stack itself builds or reuses. Nothing shape-specific to set. Consequently
  the `ensure-nics` policy — which asks the OCI Core API for secondary VNICs — is **not applied**:
  it cannot work there, failing with `authorization error ... operation: GetVnic` and crash-looping.
  `is_bare_metal` is derived from the flavor; set it explicitly only if you pair a flavor with an
  unusual shape (e.g. a VM shape in the production zip). VMs still use `ensure-nics` (no
  pre-attached data NICs) — untested since this change.
