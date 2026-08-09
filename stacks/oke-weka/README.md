# oke-weka — all-in-one (cluster + WEKA operator) one-click stack

<!-- Works once the repo is public and a vX.Y.Z release is tagged. -->
This stack ships as two zips, built from the same Terraform (they differ only in the
bundled `schema.yaml`, generated from `schema-prod.yaml` / `schema-dev.yaml`):

- **Production** — local-NVMe `BM.DenseIO.E5.128`, fixed capacity options 367 TB → 10 PB (`production_tier`):
  [![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-prod.zip)
- **Dev / non-production** — block-volume drives, instance count (`node_count`):
  [![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/weka/oci-oke-deployment/releases/latest/download/oke-weka-dev.zip)

Sizing, networking, and the API-endpoint visibility are **frozen after the first apply**
(a change would destroy/replace instances); only the quay.io creds and operator version
stay editable. See [`guard.tf`](guard.tf).

A **single** OCI Resource Manager stack that does the whole thing in **one apply**:

1. OKE cluster + converged DenseIO node pool (hugepages, local NVMe, WEKA node prep)
2. the intra-VCN data-plane security-list fix (`weka_data_network.tf`)
3. the WEKA operator (Helm), quay.io image pull secrets, and the
   WekaPolicy / WekaCluster / WekaClient custom resources (`weka.tf`)

This is the one-click alternative to running the separate [`../oke-infra`](../oke-infra)
then [`../weka-layer`](../weka-layer) stacks. Same building blocks, one deploy.

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

## One-click in Resource Manager

The `oci` CLI is used for two calls (the subnet attach and the OKE token). **Verified: the ORM
runner ships `oci`/`kubectl`/`helm` and is pre-authenticated**, so with the defaults
(`oci_cli_auth = ""`, no `--auth` flag) this stack runs start-to-finish in the **ORM Console**:

1. **Resource Manager → Stacks → Create stack** from a zip of this folder (or a source-control
   config provider with working dir `stacks/oke-weka`).
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

> The `kubernetes`/`helm`/`kubectl` **providers** are self-contained (no `kubectl`/`helm` binaries).
> The one external tool is `oci`, which the runner already has. Cloud Shell / local work too — see
> the auth table below.

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** (Console) | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |

## Local / Cloud Shell

```bash
cd stacks/oke-weka
cp terraform.tfvars.example terraform.tfvars   # tenancy_id, compartment_id, quay creds (+ profile for local)
terraform init && terraform apply              # ~15–20 min: cluster + WEKA
terraform output -raw create_kubeconfig_command | bash
export KUBECONFIG=~/weka-cluster.yaml
kubectl get pods -n weka-operator-system       # operator Running
kubectl get wekacluster dev -n default -w      # forms → healthy
```

## Security posture (accepted)

The OKE API endpoint is **public and reachable from `0.0.0.0/0`** — not for laptop `kubectl`, but
because this stack installs WEKA over the Kubernetes API **from the ORM / Marketplace runner, which
is outside your VCN**, so the endpoint must be reachable for the install to succeed. The endpoint is
still **token-authenticated** (short-lived OCI/OKE tokens). This is an accepted, documented default
(see [`SECURITY.md`](../../SECURITY.md)).

**Hardening (optional, not implemented here):** for a fully private control plane, install WEKA from
**inside the VCN** — enable the module's operator host (`create_operator = true`) and run the Helm
install + `kubectl apply` from it via cloud-init, then set `control_plane_is_public = false`. That
removes the public endpoint entirely at the cost of an always-on operator VM and dropping the
in-stack helm/kubectl providers for the WEKA layer.

## Caveats

- **Same-apply provider auth** (k8s providers targeting a cluster built in the same run) is the
  standard OKE/EKS/GKE one-click pattern and works, but it's more fragile than two stacks on
  *replacement* — if you ever recreate the cluster, prefer `terraform apply` in two phases or use
  the separate `../oke-infra` + `../weka-layer` stacks.
- **DenseIO capacity:** the production shape (`BM.DenseIO.E5.128`) is frequently
  *out-of-host-capacity*. A `capacity.tf` preflight checks every AD before building and
  fails early with guidance. Note it only reports whether the shape is available in an AD, **not
  whether N hosts are free** — the multi-PB options need tens to hundreds of bare-metal hosts, so
  confirm quota/capacity with Oracle before picking one. If an apply still fails, choose a smaller
  capacity option, pin ADs via `worker_placement_ads`, or try another region/AD. (This is an OCI
  availability constraint, not a config issue.)
- **Bare metal:** the module omits `shape_config` for non-Flex shapes automatically, so OCPU/memory
  are shape-fixed (128 cores); provisioning takes longer (bare-metal first boot). `driveCores` and
  `dataNICsNumber` are set from safe defaults — revisit them for throughput tuning at the largest
  capacities.
- The WEKA CRs are **bundled** in this stack's own [`crds/`](crds); `03-wekacluster.yaml` is a
  `templatefile` rendered from the selected capacity option, so the WEKA layout matches the
  provisioned hardware.
  (The repo-root `crds/` stay static for the manual/staged path, so the two intentionally diverge.)
  Keep the two in sync if you edit the manifests.

## Teardown

```bash
terraform destroy
```
(or an ORM **Destroy** job). DenseIO nodes burn quota — destroy when done.
