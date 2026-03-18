variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona GCP"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "Tipo de máquina GCE (e2-medium = 2 vCPU / 4 GB RAM)"
  type        = string
  default     = "e2-medium"
}

variable "repo_name" {
  description = "Nome do repositório no Artifact Registry"
  type        = string
  default     = "devops-challenge"
}
