output "cluster_id" {
  description = "OCID of the created OKE cluster. Feed this to `oci ce cluster create-kubeconfig`."
  value       = module.oke.cluster_id
}

output "cluster_endpoints" {
  description = "OKE control-plane endpoints (public/private API server addresses)."
  value       = module.oke.cluster_endpoints
}

output "region" {
  description = "Region the cluster lives in (for create-kubeconfig, and as input to the weka-layer stack)."
  value       = var.region
}

output "vcn_id" {
  description = "OCID of the cluster VCN (debugging / network inspection)."
  value       = module.oke.vcn_id
}

output "worker_subnet_id" {
  description = "OCID of the worker subnet the weka-data security list is attached to (debugging)."
  value       = module.oke.worker_subnet_id
}

output "create_kubeconfig_command" {
  description = "Ready-to-run command to write a kubeconfig for this cluster."
  # Append --profile only when set; config_file_profile is null in ORM/Cloud Shell
  # and format("%s", null) errors, which would fail the whole apply.
  value = format(
    "oci ce cluster create-kubeconfig --cluster-id %s --file ~/%s.yaml --region %s --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT%s",
    module.oke.cluster_id, var.cluster_name, var.region,
    var.config_file_profile != null ? " --profile ${var.config_file_profile}" : "",
  )
}
