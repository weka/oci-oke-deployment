# Providers for the WEKA layer.
#
# This stack talks to the Kubernetes API of an already-running OKE cluster (built
# by the sibling "oke-infra" stack). The kubernetes/helm/kubectl providers get the
# cluster endpoint + CA from the OKE kube-config data source, and authenticate with
# the OKE token exec plugin (`oci ce cluster generate-token`).
#
# IMPORTANT: the exec plugin shells out to the `oci` CLI at apply time, so run this
# stack from an environment that HAS the oci CLI (OCI Cloud Shell, your laptop, or
# an operator host) — NOT the bare OCI Resource Manager runner, which does not
# guarantee the CLI. ORM still manages this stack's state + variable form.

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.14.0"
    }
    helm = {
      # v2 line: nested `kubernetes { exec { ... } }` provider syntax used below.
      source  = "hashicorp/helm"
      version = ">= 2.12.0, < 3.0.0"
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

# Kube-config for the target OKE cluster (endpoint + CA). The token itself is
# minted per-call by the exec plugin below, not read from here.
data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id = var.cluster_id
}

locals {
  kubeconfig = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
  # certificate-authority-data has a hyphen -> bracket access.
  cluster_ca   = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  cluster_host = local.kubeconfig.clusters[0].cluster.server

  # OKE short-lived token via the oci CLI exec plugin. Auth is robust across
  # environments, matching oke-infra's oci_cli_auth logic:
  #   * config_file_profile set -> `--profile <p>`  (local run)
  #   * else oci_cli_auth set    -> `--auth <mode>`  (ORM runner = resource_principal)
  #   * else                     -> no flag          (Cloud Shell session auth)
  oci_auth_args = (
    var.config_file_profile != null ? ["--profile", var.config_file_profile] :
    trimspace(var.oci_cli_auth == null ? "" : var.oci_cli_auth) != "" ? ["--auth", var.oci_cli_auth] :
    []
  )
  exec_args = concat(
    ["ce", "cluster", "generate-token", "--cluster-id", var.cluster_id, "--region", var.region],
    local.oci_auth_args,
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
  kubernetes {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = local.exec_args
    }
  }
}
