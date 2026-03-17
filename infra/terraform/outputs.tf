output "cluster_name" {
  description = "Nome do cluster GKE"
  value       = google_container_cluster.gke.name
}

output "cluster_location" {
  description = "Região do cluster GKE"
  value       = google_container_cluster.gke.location
}

output "artifact_registry_url" {
  description = "URL base do Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}"
}

output "kubectl_command" {
  description = "Comando para configurar kubectl"
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}"
}

output "registry_auth_command" {
  description = "Comando para autenticar Docker no Artifact Registry"
  value       = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
}
