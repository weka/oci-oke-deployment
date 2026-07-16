# weka-layer — WEKA operator + custom resources (Stack 2)

Installs WEKA onto an **existing OKE cluster** (built by [`../oke-infra`](../oke-infra)):

1. `weka-operator-system` namespace
2. `quay-io-robot-secret` image pull secret in `weka-operator-system` **and** `default`
3. the `weka-operator` Helm chart (bundled CRDs install automatically)
4. the WekaPolicy / WekaCluster / WekaClient manifests from [`../../crds`](../../crds)

This is the Terraform equivalent of `scripts/install-weka-operator.sh` + `kubectl apply -f crds/`.

## kubectl/helm are the providers; the only external need is `oci` (for the token)

The `kubernetes`/`helm`/`kubectl` providers are self-contained (no `kubectl`/`helm` binaries) —
`terraform init` downloads them. They authenticate to OKE with a bearer token minted by
`oci ce cluster generate-token` (no provider-native OKE token exists), so the **one** external tool
this stack needs is the **`oci` CLI**. Auth mode is chosen by **`oci_cli_auth`** (default `""` =
no `--auth` flag; the environment authenticates):

| Where you apply | Set | `oci` CLI auth |
|---|---|---|
| **ORM runner** (Console) | nothing (defaults) | none — runner's delegation/OBO token |
| **OCI Cloud Shell** | nothing (defaults) | none — session token |
| **Local** | `config_file_profile = "<profile>"` | `--profile <profile>` |
| operator host | `oci_cli_auth = "instance_principal"` | `--auth instance_principal` |

**Verified:** the ORM runner ships `oci`/`kubectl`/`helm` and is pre-authenticated, so it runs
directly in the ORM Console (the runner does **not** support `--auth resource_principal`; no flag is
correct). Cloud Shell is identical. Either way the providers do the whole operator install + CR
apply; you never hand-run `kubectl`/`helm`.

## Files

| File | Purpose |
|---|---|
| `providers.tf` | oci + helm + kubernetes + `gavinbunney/kubectl`; kube-config data source + exec-plugin auth |
| `variables.tf` | `cluster_id`, `region`, `config_file_profile`, `quay_username`/`quay_password`, `operator_version` |
| `main.tf` | namespace, pull secrets, `helm_release`, `kubectl_manifest` for the CRs |
| `outputs.tf` | operator namespace, applied CR list, verify commands |
| `schema.yaml` | OCI Resource Manager Console variable form |

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars

# Fill cluster_id + region straight from the infra stack:
terraform -chdir=../oke-infra output -raw cluster_id
terraform -chdir=../oke-infra output -raw region
# ...and quay.io robot creds from https://get.weka.io.

terraform init
terraform apply

kubectl get pods -n weka-operator-system            # operator Running
kubectl get wekapolicy,wekacluster,wekaclient -n default
```

- **Auth:** ORM runner and Cloud Shell need nothing (default `oci_cli_auth = ""` → no flag; the
  environment authenticates); locally set `config_file_profile`.
- **quay creds** are `sensitive` — pass via `terraform.tfvars` (gitignored) or `TF_VAR_quay_password`,
  not on the CLI.

## Notes

- The `helm_release` installs the chart's bundled CRDs automatically (`skip_crds` defaults to false),
  and `gavinbunney/kubectl` resolves CR kinds at apply time (not plan), so the CRs tolerate the CRDs
  having just been installed in the same apply. If a first apply races the CRD becoming established,
  re-run `terraform apply`.
- The CR manifests in `crds/` are namespaced to `default`; the pull secret is created there to match.

## Teardown

```bash
terraform destroy
```

Run this **before** destroying `../oke-infra`. If the cluster is already gone, remove the resources
from state instead (`terraform state rm ...`) since the API is unreachable.
