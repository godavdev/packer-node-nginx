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
