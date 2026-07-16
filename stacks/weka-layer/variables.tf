# Inputs for the WEKA layer. cluster_id + region come from the oke-infra stack
# outputs; the quay.io robot creds come from https://get.weka.io.

variable "cluster_id" {
  description = "OCID of the target OKE cluster (oke-infra output `cluster_id`)."
  type        = string
}

variable "region" {
  description = "Region the cluster lives in (oke-infra output `region`)."
  type        = string
}

variable "config_file_profile" {
  description = <<-EOT
    Profile in ~/.oci/config used by the oci CLI exec plugin (token minting) and
    the oci provider. Set for local runs (e.g. "DEFAULT"); leave null in OCI Cloud
    Shell, whose delegation-token auth needs no profile.
  EOT
  type        = string
  default     = null
}

variable "oci_cli_auth" {
  description = <<-EOT
    Auth mode for the `oci ce cluster generate-token` exec plugin (the OKE bearer
    token the kubernetes/helm/kubectl providers use), passed as `--auth <mode>`.
    Only used when config_file_profile is null:
      - ""  (empty, default) — no --auth flag; the environment is pre-authenticated.
        Correct for BOTH the OCI Resource Manager runner (delegation/OBO token) and
        OCI Cloud Shell (session token). The ORM runner does NOT support
        --auth resource_principal.
      - "instance_principal"  — an operator/compute host in a dynamic group.
      - "resource_principal"  — only where OCI_RESOURCE_PRINCIPAL_* is set (NOT the ORM runner).
    Ignored when config_file_profile is set (local runs use --profile).
  EOT
  type        = string
  default     = ""
}

variable "quay_username" {
  description = "quay.io robot username (from https://get.weka.io). Used for the image pull secret."
  type        = string
  sensitive   = true
}

variable "quay_password" {
  description = "quay.io robot password (from https://get.weka.io). Used for the image pull secret."
  type        = string
  sensitive   = true
}

variable "operator_version" {
  description = "WEKA operator Helm chart version."
  type        = string
  default     = "v1.14.1"
}
