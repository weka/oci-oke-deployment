output "operator_namespace" {
  description = "Namespace the WEKA operator runs in."
  value       = kubernetes_namespace_v1.operator.metadata[0].name
}

output "applied_custom_resources" {
  description = "WEKA custom resource manifests applied from crds/."
  value       = sort([for k in keys(kubectl_manifest.weka_cr) : k])
}

output "verify_commands" {
  description = "Quick checks that the WEKA layer came up."
  value = <<-EOT
    kubectl get pods -n ${kubernetes_namespace_v1.operator.metadata[0].name}
    kubectl get wekapolicy,wekacluster,wekaclient -n default
  EOT
}
