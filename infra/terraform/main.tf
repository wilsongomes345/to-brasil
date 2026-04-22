terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.29"
    }
  }
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# APIs necessárias
resource "google_project_service" "apis" {
  for_each           = toset(["compute.googleapis.com", "artifactregistry.googleapis.com"])
  service            = each.key
  disable_on_destroy = false
}

# Artifact Registry
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = var.repo_name
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# Firewall
resource "google_compute_firewall" "allow_app" {
  name    = "devops-challenge-allow"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "3000", "9090"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["devops-challenge"]
  depends_on    = [google_project_service.apis]
}

# VM GCE
resource "google_compute_instance" "vm" {
  name         = "devops-challenge-vm"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["devops-challenge"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    region         = var.region
    repo_name      = var.repo_name
    repo_url       = var.repo_url
    startup-script = file("${path.module}/../scripts/startup.sh")
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [
    google_project_service.apis,
    google_artifact_registry_repository.repo,
  ]
}
