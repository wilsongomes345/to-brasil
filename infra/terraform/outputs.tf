output "vm_ip" {
  description = "IP externo da VM"
  value       = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "artifact_registry_url" {
  description = "URL base do Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}"
}

output "app1_text" { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}/app1/text" }
output "app1_time" { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}/app1/time" }
output "app2_text" { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}/app2/text" }
output "app2_time" { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}/app2/time" }
output "prometheus" { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}:9090" }
output "grafana"    { value = "http://${google_compute_instance.vm.network_interface[0].access_config[0].nat_ip}:3000" }

output "ssh_command" {
  value = "gcloud compute ssh devops-challenge-vm --zone=${var.zone} --project=${var.project_id}"
}
