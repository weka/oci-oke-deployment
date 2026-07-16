# Security

## Reporting

Please report suspected vulnerabilities privately to **security@weka.io** rather
than opening a public issue.

## No secrets in this repo

This repository contains **only Terraform configuration and Kubernetes manifests** —
no credentials. Account-specific inputs (`tenancy_id`, `compartment_id`), the quay.io
image-pull credentials (`quay_username` / `quay_password`), and the SSH key are
supplied at apply time as variables; `terraform.tfvars`, state files, and `.terraform/`
are git-ignored and have never been committed.

## Accepted-by-design IaC posture

Static IaC scanners (Wiz, checkov, tfsec) will flag the items below. They are
**intentional** for a self-service developer/demo stack and are documented here as
accepted risk. Harden them for production use.

| Item | Where | Why it's here | How to harden |
|---|---|---|---|
| **OKE API reachable from `0.0.0.0/0`** (High) | `control_plane_allowed_cidrs` default, `control_plane_is_public = true` | The all-in-one stack installs the WEKA operator + CRs **over the Kubernetes API from the Resource Manager / Marketplace runner**, which runs **outside your VCN** — so the API endpoint must be publicly reachable for that apply to succeed. The endpoint is **still authenticated** (every call needs a short-lived OCI/OKE token); `0.0.0.0/0` only makes it network-*reachable*, and it can't be narrowed to the runner's ephemeral egress IP. | Fully private posture: install WEKA from **inside the VCN** (an operator host) and set `control_plane_is_public = false` — see the private-endpoint note in the README roadmap. Otherwise restrict `control_plane_allowed_cidrs` if you know the deploying network. |
| **Security list allows all protocols intra-VCN** (Low) | `weka_data_network.tf` ingress (`protocol = "all"`, source = VCN CIDR) | Required by the WEKA DPDK data plane, which uses arbitrary ports between backends on the non-NSG "data" VNICs. Scoped to the VCN CIDR (not the internet). | Not recommended to change — WEKA needs it. Keep the VCN CIDR scope. |

Egress on that security list is scoped to the VCN CIDR (not `0.0.0.0/0`); worker
internet egress is provided by the worker NSG.
