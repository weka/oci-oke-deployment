# oci-oke-deployment — WEKA on OKE

Terraform to stand up a managed **OKE** cluster on OCI and layer **WEKA** (operator +
custom resources) on top, delivered as **OCI Resource Manager (ORM)** stacks so the
whole path — *OKE creation → operator setup* — is Infrastructure-as-Code, either as a
single one-click stack or as two staged stacks.

<!-- Works once the repo is public and a vX.Y.Z release is tagged (see .github/workflows/release.yml). -->
The one-click stack ships in two flavors — pick one:

**Production** (local-NVMe DenseIO; pick usable capacity + worker instance type, 31 TB → 1175 TB):
[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-prod.zip)

**Dev / non-production** (block-volume drives, for trying the CSI driver / operator):
[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-dev.zip)

Licensed under **Apache-2.0** (see [LICENSE](LICENSE)). Security notes and the
accepted IaC posture are in [SECURITY.md](SECURITY.md).

## Layout

```
stacks/
  oke-weka/     # ONE-CLICK: cluster + WEKA operator + CRs in a single apply
  oke-infra/    # Stack 1 (staged): OKE cluster + WEKA node prep + intra-VCN data-plane fix
  weka-layer/   # Stack 2 (staged): WEKA operator + image pull secrets + WekaPolicy/Cluster/Client
crds/           # WEKA custom resource manifests (consumed by weka-layer and oke-weka)
scripts/        # install-weka-operator.sh — the pre-Terraform manual path (fallback)
```

Two ways to deploy — pick one:

- **One-click:** [`stacks/oke-weka/`](stacks/oke-weka) — a single ORM stack that provisions the
  cluster **and** installs WEKA in one apply. Best for "click Apply, get a running WEKA-on-OKE".
- **Staged (two stacks):** [`stacks/oke-infra/`](stacks/oke-infra) then
  [`stacks/weka-layer/`](stacks/weka-layer) (feed stack 1's `cluster_id` / `region` into stack 2).
  Best when you want infra and the WEKA layer managed/rerun independently.

Each stack has its own `README.md`, `variables.tf`, and `schema.yaml`.

## Running in Resource Manager (and the one dependency)

[OCI Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resource-manager-and-terraform.htm)
runs Terraform as a managed service: it stores + locks state, versions your config, injects
resource-principal credentials, and renders a Console variable form from each stack's `schema.yaml`.

**kubectl and helm are not binaries here — they are the Terraform providers** (`hashicorp/helm`,
`hashicorp/kubernetes`, `gavinbunney/kubectl`), which `terraform init` downloads into whatever runs
the apply. The **only** external tool either stack needs is the **`oci` CLI**, for one call each:

- `oke-infra` attaches the WEKA data-plane security list (`oci network subnet update`).
- `weka-layer` mints the OKE API token the k8s providers use (`oci ce cluster generate-token`).
  There is no provider-native OKE token (`oci_containerengine_cluster_token` does not exist in the
  provider), so this one `oci` call is unavoidable.

Both stacks pick the right `oci` auth automatically via the **`oci_cli_auth`** variable
(default `""` — no `--auth` flag; the environment is already authenticated):

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** (Console one-click) | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |
| operator/compute host | `oci_cli_auth = "instance_principal"` | `--auth instance_principal` |

**Verified against a live ORM runner (us-phoenix-1):** the managed runner ships `oci`, `kubectl`,
and `helm`, and is pre-authenticated with a delegation token — so `oci` with **no `--auth` flag**
works (note: `--auth resource_principal` does **not** — no RP env there). A stack-1 **Plan job**
succeeded (`64 to add`) with resource-principal creds auto-injected into the provider. So both stacks
run **directly in the ORM Console**; Cloud Shell works identically. In the ORM runner, provide the
SSH key as **content** (`ssh_public_key`) — there are no local files on the runner.

## Quick start

```bash
# Stack 1 — cluster
cd stacks/oke-infra
cp terraform.tfvars.example terraform.tfvars    # tenancy_id + compartment_id (+ profile for local)
terraform init && terraform apply
terraform output -raw create_kubeconfig_command | bash
kubectl get nodes                                # wait for Ready

# Stack 2 — WEKA (run from Cloud Shell or a host with the oci CLI)
cd ../weka-layer
cp terraform.tfvars.example terraform.tfvars     # cluster_id + region from stack 1, quay creds
terraform init && terraform apply
kubectl get pods -n weka-operator-system
kubectl get wekacluster dev -n default
```

Teardown is `terraform destroy` in each stack (weka-layer first, then oke-infra).

## Testing in Resource Manager via the CLI

You can drive the whole ORM lifecycle from the `oci` CLI (no Console clicks). This is how the stacks
were validated. Replace `<C>`/`<T>` with your compartment/tenancy OCIDs, `<PUBKEY>` with your SSH
public key **content**, and use a working `--profile`.

```bash
# --- Stack 1: oke-infra ---
cd stacks/oke-infra
zip -q /tmp/s1.zip main.tf variables.tf providers.tf outputs.tf weka_data_network.tf schema.yaml .terraform.lock.hcl
printf '{"tenancy_id":"<T>","compartment_id":"<C>","region":"us-phoenix-1","ssh_public_key":"<PUBKEY>"}' > /tmp/v1.json
S1=$(oci resource-manager stack create --compartment-id <C> --config-source /tmp/s1.zip \
      --terraform-version 1.5.x --variables file:///tmp/v1.json --display-name weka-oke-infra \
      --region us-phoenix-1 --query 'data.id' --raw-output)
J1=$(oci resource-manager job create-apply-job --stack-id $S1 --execution-plan-strategy AUTO_APPROVED \
      --region us-phoenix-1 --query 'data.id' --raw-output)
# poll until SUCCEEDED:
oci resource-manager job get --job-id $J1 --query 'data."lifecycle-state"' --raw-output
# logs if needed: oci resource-manager job get-job-logs-content --job-id $J1 --raw-output
CLUSTER=$(oci ce cluster list --compartment-id <C> --name weka-oke --region us-phoenix-1 \
      --query 'data[0].id' --raw-output)

# --- Stack 2: weka-layer ---
cd ../weka-layer
zip -q /tmp/s2.zip main.tf variables.tf providers.tf outputs.tf schema.yaml .terraform.lock.hcl
printf '{"cluster_id":"%s","region":"us-phoenix-1","quay_username":"%s","quay_password":"%s"}' \
      "$CLUSTER" "$QUAY_USERNAME" "$QUAY_PASSWORD" > /tmp/v2.json
S2=$(oci resource-manager stack create --compartment-id <C> --config-source /tmp/s2.zip \
      --terraform-version 1.5.x --variables file:///tmp/v2.json --display-name weka-layer \
      --region us-phoenix-1 --query 'data.id' --raw-output)
oci resource-manager job create-apply-job --stack-id $S2 --execution-plan-strategy AUTO_APPROVED \
      --region us-phoenix-1 --query 'data.id' --raw-output   # poll as above

# --- Teardown (weka-layer first, then oke-infra) ---
for S in $S2 $S1; do
  oci resource-manager job create-destroy-job --stack-id $S --execution-plan-strategy AUTO_APPROVED \
    --region us-phoenix-1 --query 'data.id' --raw-output    # poll to SUCCEEDED
  oci resource-manager stack delete --stack-id $S --force --region us-phoenix-1
done
```

Notes:
- The zip must **exclude** `terraform.tfvars` / state / `.terraform/` — pass values via `--variables`
  and leave `config_file_profile`/`oci_cli_auth` unset so the runner authenticates itself.
- `--terraform-version 1.5.x` is what the runner accepts; a Plan job (`create-plan-job`) is a free
  dry run that validates the config + `schema.yaml` before you apply.
- **Capacity:** the worker pool uses `VM.DenseIO.E5.Flex`, which is frequently
  *out-of-host-capacity*. If the node pool fails to launch, retry, lower `node_count` (add it to the
  variables JSON), pick another AD, or try another region (e.g. `us-ashburn-1`). This is an OCI
  availability constraint, not a config issue.

## Verified status

- ✅ Bare-ORM mechanism: stack-1 **Plan** succeeds (`64 to add`), resource-principal auth injected;
  the ORM runner ships `oci`/`kubectl`/`helm` and authenticates with **no `--auth` flag**; OKE
  control plane creates and destroys cleanly through ORM.
- ⏳ Full worker pool + WEKA layer: not yet completed end-to-end — blocked by DenseIO
  out-of-host-capacity in us-phoenix-1 at test time (not a code issue). Re-run the steps above when
  capacity is available.
