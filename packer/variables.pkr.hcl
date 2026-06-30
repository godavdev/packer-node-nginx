variable "image_version" {
  type        = string
  description = "Version tag for the image"
  default     = "1.0.0"
}

variable "app_name" {
  type        = string
  description = "Application name used for image naming"
  default     = "express-nginx-app"
}

variable "aws_region" {
  type        = string
  description = "AWS region to build and deploy"
  default     = "us-east-2"
}

variable "aws_instance_type" {
  type        = string
  description = "EC2 instance type for building the AMI"
  default     = "t3.micro"
}

variable "azure_location" {
  type        = string
  description = "Azure region to build and deploy"
  default     = "East US"
}

variable "azure_vm_size" {
  type        = string
  description = "Azure VM size for building the managed image"
  default     = "Standard_D2s_v3"
}

variable "node_env" {
  type        = string
  description = "Node environment (production, development, etc)"
  default     = "production"
}
