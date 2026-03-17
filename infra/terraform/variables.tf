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
  description = "Tipo de máquina GCE"
  type        = string
  default     = "e2-medium" # 2 vCPU / 4 GB RAM
}

variable "repo_name" {
  description = "Nome do repositório no Artifact Registry"
  type        = string
  default     = "devops-challenge"
}

variable "repo_url" {
  description = "URL do repositório Git da aplicação"
  type        = string
  default     = "https://github.com/wilsongomes345/to-brasil.git"
}
