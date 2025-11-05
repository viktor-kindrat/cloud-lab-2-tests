variable "aws_region" {
  description = "AWS region to deploy infrastructure into."
  type        = string
}

variable "project_name" {
  description = "Short name used for tagging and resource naming."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the application VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets."
  type        = list(string)
  default     = [
    "10.10.1.0/24",
    "10.10.2.0/24"
  ]
}

variable "container_image" {
  description = "Initial container image to deploy in the ECS task."
  type        = string
}

variable "container_port" {
  description = "Container port exposed by the application."
  type        = number
  default     = 5000
}

variable "task_family" {
  description = "ECS task definition family name."
  type        = string
  default     = "cloud-lab-app"
}

variable "task_cpu" {
  description = "CPU units for the ECS task definition."
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Memory (in MiB) for the ECS task definition."
  type        = string
  default     = "1024"
}

variable "container_cpu" {
  description = "CPU units reserved for the container."
  type        = number
  default     = 256
}

variable "container_memory" {
  description = "Memory (in MiB) reserved for the container."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks desired in the ECS service."
  type        = number
  default     = 1
}
