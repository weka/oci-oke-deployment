# Terraform + provider configuration for the OKE deployment.
#
# The terraform-oci-oke module requires TWO oci provider configurations:
#   * the default provider  -> the region the cluster lives in (var.region)
#   * an "oci.home" alias    -> the tenancy home region, used for identity ops
# (see the module's versions.tf: configuration_aliases = [oci.home]).
#
# Auth uses your local ~/.oci/config via a named profile (var.config_file_profile,
# default "DEFAULT"), so no API keys are hard-coded here.

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.14.0"
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
