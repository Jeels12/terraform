variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  type    = string
  default = "" # optional: leave empty to allow AWS to choose
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "key_name" {
  description = "Existing EC2 key pair name to allow SSH access"
  type        = string
  default     = ""
}

variable "public_key_path" {
  description = "If you want Terraform to create a key pair from a local public key file, provide its path. Otherwise leave empty and set key_name."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH (restrict for safety)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr_1" {
  type    = string
  default = "10.0.1.0/24"
}

variable "public_subnet_cidr_2" {
  type    = string
  default = "10.0.2.0/24"
}
