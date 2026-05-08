variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "Type instance EC2"
  type        = string
  default     = "t2.micro"
}

variable "db_password" {
  description = "Mot de passe RDS MySQL"
  type        = string
  sensitive   = true
}
