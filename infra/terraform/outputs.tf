output "vm_ip" {
  value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
}

output "registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}"
}
