output "vm_external_ip" {
  description = "IP externo da VM"
  value       = google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip
}

output "artifact_registry_url" {
  description = "URL base do Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}"
}

output "app1_text_url" {
  description = "App 1 — rota texto"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}/app1/text"
}

output "app1_time_url" {
  description = "App 1 — rota horário"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}/app1/time"
}

output "app2_text_url" {
  description = "App 2 — rota texto"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}/app2/text"
}

output "app2_time_url" {
  description = "App 2 — rota horário"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}/app2/time"
}

output "grafana_url" {
  description = "Grafana"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus"
  value       = "http://${google_compute_instance.app_vm.network_interface[0].access_config[0].nat_ip}:9090"
}

output "ssh_command" {
  description = "Comando SSH para acessar a VM"
  value       = "gcloud compute ssh devops-challenge-vm --zone=${var.zone}"
}
