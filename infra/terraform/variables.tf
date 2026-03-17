variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP (Autopilot é regional — alta disponibilidade)"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Nome do cluster GKE"
  type        = string
  default     = "devops-challenge-cluster"
}

variable "repo_name" {
  description = "Nome do repositório no Artifact Registry"
  type        = string
  default     = "devops-challenge"
}
