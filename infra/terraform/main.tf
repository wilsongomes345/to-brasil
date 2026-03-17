terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
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
    "container.googleapis.com",          # GKE
    "artifactregistry.googleapis.com",   # Artifact Registry
    "compute.googleapis.com",            # Necessário pelo GKE
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
# GKE Autopilot Cluster
# Autopilot: Google gerencia os nodes automaticamente,
# cobra por pod (não por node), escala sem configuração.
# -------------------------------------------------------
resource "google_container_cluster" "gke" {
  name     = var.cluster_name
  location = var.region  # Regional = alta disponibilidade

  enable_autopilot    = true
  deletion_protection = false

  # Versão do Kubernetes gerenciada pelo GKE (release channel)
  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.apis]
}
