variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
}

variable "repo_name" {
  type    = string
  default = "devops-challenge"
}

variable "repo_url" {
  type    = string
  default = "https://github.com/wilsongomes345/to-brasil.git"
}
