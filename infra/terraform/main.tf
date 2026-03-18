terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # Estado remoto no GCS — compartilhado entre setup.sh e CI/CD
  # bucket e prefix são passados via -backend-config (não hardcoded)
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -------------------------------------------------------
# APIs necessárias
# -------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# -------------------------------------------------------
# Artifact Registry — repositório Docker privado
# -------------------------------------------------------
resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = var.repo_name
  format        = "DOCKER"
  description   = "Docker images — DevOps Challenge"
  depends_on    = [google_project_service.apis]
}

# -------------------------------------------------------
# Firewall — abre portas da aplicação
# -------------------------------------------------------
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

# -------------------------------------------------------
# GCE VM — roda o Docker Compose
# -------------------------------------------------------
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
    access_config {} # IP externo efêmero
  }

  # Startup script lê variáveis do metadata server (sem conflito com bash)
  metadata = {
    region         = var.region
    repo_name      = var.repo_name
    startup-script = file("${path.module}/../scripts/startup.sh")
  }

  # Service Account com acesso ao Artifact Registry e Cloud Build
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [
    google_project_service.apis,
    google_artifact_registry_repository.docker_repo,
  ]
}
