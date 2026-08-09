# Providers for the ALL-IN-ONE stack: OKE infra + WEKA layer in a single apply.
#
# The two oci providers (default + oci.home alias) drive the OKE module. The
# kubernetes/helm/kubectl providers talk to the cluster THIS stack creates — their
# endpoint/CA come from the kube-config data source (keyed on the in-stack
# module.oke.cluster_id, so it's resolved during apply after the cluster exists),
# and the bearer token is minted per-call by the `oci ce cluster generate-token`
# exec plugin. Verified: the OCI Resource Manager runner ships the oci CLI and
# authenticates with no --auth flag (oci_cli_auth = ""), so this whole stack runs
# one-click in the ORM Console.

terraform {
  required_version = ">= 1.4.0" # terraform_data (capacity preflight gate)

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.14.0"
    }
    helm = {
      # >= 3.0.1 to satisfy the terraform-oci-oke module (which requires helm v3).
      source  = "hashicorp/helm"
      version = ">= 3.0.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.config_file_profile
}

provider "oci" {
  alias               = "home"
  region              = coalesce(var.home_region, var.region)
  config_file_profile = var.config_file_profile
}

# Connection to the cluster created in this same apply. Endpoint + CA come from
# module.oke OUTPUTS (populated because output_detail = true) and are FROZEN into
# a terraform_data resource so the values are stored in state.
#
# Why terraform_data and NOT a kube-config data source: a data source keyed on
# module.oke.cluster_id cannot be read during `terraform destroy` — its dependency
# is in the destroy set — so it resolves to empty and the kubernetes/helm/kubectl
# providers fall back to host = "localhost". They then fail to delete the
# in-cluster namespace/secret and abort the entire destroy (observed: destroy
# died on kubernetes_namespace_v1.operator with a localhost:80 connection error).
# A resource attribute is always readable from state during destroy, so the WEKA
# layer is torn down cleanly BEFORE the cluster. This is what makes teardown work.
resource "terraform_data" "kube_connect" {
  input = {
    host = "https://${var.control_plane_is_public ? module.oke.cluster_endpoints.public_endpoint : module.oke.cluster_endpoints.private_endpoint}"
    # base64 certificate-authority-data (kubeconfig form); decoded in the locals below.
    ca = module.oke.cluster_ca_cert
  }
}

locals {
  cluster_host = terraform_data.kube_connect.output.host
  cluster_ca   = base64decode(terraform_data.kube_connect.output.ca)

  # OKE token exec-plugin auth (named distinctly from weka_data_network.tf's
  # oci_auth_args). Same 3-way logic: --profile (local) > --auth (host) > none
  # (ORM runner / Cloud Shell, which are pre-authenticated).
  k8s_oci_auth_args = (
    var.config_file_profile != null ? ["--profile", var.config_file_profile] :
    trimspace(var.oci_cli_auth == null ? "" : var.oci_cli_auth) != "" ? ["--auth", var.oci_cli_auth] :
    []
  )
  exec_args = concat(
    ["ce", "cluster", "generate-token", "--cluster-id", module.oke.cluster_id, "--region", var.region],
    local.k8s_oci_auth_args,
  )
}

provider "kubernetes" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.exec_args
  }
}

provider "kubectl" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.exec_args
  }
}

provider "helm" {
  # helm provider v3: `kubernetes` is an attribute (= {…}), and `exec` within it is
  # a nested attribute object — not the v2 nested blocks.
  kubernetes = {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = local.exec_args
    }
  }
}
