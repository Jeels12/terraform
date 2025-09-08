variable "region" {
  type    = string
  default = "us-east-1"
}

# Use an Ubuntu 22.04/20.04 AMI ID appropriate for your region.
# You can set this to a valid region-specific AMI ID (HVM, x86_64).
variable "ami" {
  description = "AMI ID (Ubuntu). Set to an Ubuntu AMI valid in your region."
  type        = string
  default     = "" 
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
  description = "Optional: local path used to create a new key pair (if you want Terraform to create it). Leave empty if using existing key_name."
  type        = string
  default     = ""
}

variable "allowed_ip" {
  description = "CIDR to allow SSH from (for security). Default allows anywhere (0.0.0.0/0) — change for safety."
  type        = string
  default     = "0.0.0.0/0"
}
