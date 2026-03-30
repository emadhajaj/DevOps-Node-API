variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Must be staging or production."
  }
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.micro" # Jenkins needs a bit of memory
}

variable "app_instance_type" {
  description = "EC2 instance type for the app"
  type        = string
  default     = "t3.micro" # App is lightweight
}

variable "your_ip" {
  description = "Your local IP for SSH access (run: curl ifconfig.me)"
  type        = string
}
