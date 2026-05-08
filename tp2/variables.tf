variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "eu-central-1"
}

variable "odoo_instance_type" {
  description = "Type instance EC2 pour Odoo (minimum t3.medium recommandé)"
  type        = string
  default     = "t3.medium"
}

variable "db_password" {
  description = "Mot de passe PostgreSQL Odoo"
  type        = string
  sensitive   = true
}

variable "repl_password" {
  description = "Mot de passe réplication PostgreSQL"
  type        = string
  sensitive   = true
}

variable "odoo_admin_pass" {
  description = "Mot de passe master Odoo"
  type        = string
  sensitive   = true
}
