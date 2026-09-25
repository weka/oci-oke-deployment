output "cluster_id" {
  description = "OCID of the created OKE cluster. Feed this to `oci ce cluster create-kubeconfig`."
  value       = module.oke.cluster_id
}

output "cluster_endpoints" {
  description = "OKE control-plane endpoints (public/private API server addresses)."
  value       = module.oke.cluster_endpoints
}

output "console_url" {
  description = "Direct link to this OKE cluster in the OCI Console (drives the primary button on the stack's Application Information tab)."
  value       = "https://cloud.oracle.com/containers/clusters/${module.oke.cluster_id}?region=${var.region}"
}

output "region" {
  description = "Region the cluster lives in (used by the create-kubeconfig command)."
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

# --- Sizing ---
output "weka_sizing" {
  description = <<-EOT
    Derived worker sizing. Production shows the WEKA protection scheme (stripe
    width + redundancy + hot spare) and raw/usable capacity for the selected
    capacity/instance-type option; non-production shows the block-volume layout.
  EOT
  value = local.is_production ? join("\n", [
    "selected:      ${var.production_tier} (production, local NVMe)",
    "shape:         ${local.node_shape}",
    # Flag the override, or the tier name above reads as a promise the raw/usable
    # lines below no longer keep (they are recomputed from the actual count).
    "workers:       ${local.effective_node_count}${var.production_node_count != null ? " (production_node_count override; tier implies ${local.selected_tier.node_count})" : ""}",
    # Which AD owns which nodes is otherwise invisible, and it is what you need
    # when one pool of several fails to build.
    "placement:     ${local.has_capacity_reservation ? join(", ", [for p in local.reservation_pools : "AD-${p.ad_number}: ${p.size}"]) : "on demand, ${var.worker_placement_ads != "" ? "AD(s) ${var.worker_placement_ads}" : "all ADs"}"}",
    "protection:    ${local.weka_stripe_width}+${local.weka_redundancy}+${local.weka_hot_spare} (stripe width + redundancy + hot spare)",
    "raw:           ${format("%.1f", local.cluster_raw_tb)} TB (${local.effective_node_count} x ${format("%.1f", local.nvme_tb_per_node)} TB/node = ${local.selected_tier.drives_per_node} x 6.8 TB NVMe)",
    "usable:        ~${format("%.1f", local.cluster_usable_tb)} TB",
    ]) : join("\n", [
    "flavor:        non-production (VM.Standard.E5.Flex, block volume)",
    "workers:       ${local.effective_node_count}",
    "per-node data: ${var.data_volume_gb} GB block volume",
    "raw:           ${format("%.1f", local.effective_node_count * var.data_volume_gb / 1000)} TB (${local.effective_node_count} x ${var.data_volume_gb} GB)",
  ])
}

# --- WEKA layer ---
output "operator_namespace" {
  description = "Namespace the WEKA operator runs in."
  value       = kubernetes_namespace_v1.operator.metadata[0].name
}

output "applied_custom_resources" {
  description = "WEKA custom resource manifests applied from crds/."
  value       = sort([for k in keys(kubectl_manifest.weka_cr) : k])
}

output "verify_commands" {
  description = "Quick checks that WEKA came up (after writing a kubeconfig)."
  value       = <<-EOT
    kubectl get pods -n ${kubernetes_namespace_v1.operator.metadata[0].name}
    kubectl get wekapolicy,wekacluster,wekaclient -n default
  EOT
}

# --- Troubleshooting ---
# Interpolates input variables only. Anything derived from a created resource is
# missing from a failed job's state, so it would drop off the Application
# Information tab on exactly the applies this output exists for.
output "troubleshooting" {
  description = "Commands for diagnosing a running or failed apply of this stack."
  value       = <<-EOT
    # stage of a running or failed job (same stream as the job's Logs tab)
    oci resource-manager job get-job-logs-content --job-id <job-ocid> --region ${var.region} --query data --raw-output

    # why a worker node pool failed; Terraform's error prints the work-request OCID
    oci ce work-request-error list --work-request-id <work-request-ocid> --compartment-id ${var.compartment_ocid} --region ${var.region}
  EOT
}
