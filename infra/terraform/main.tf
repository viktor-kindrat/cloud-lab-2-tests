provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    Project = var.project_name
    Managed = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "tests" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "tests" {
  vpc_id = aws_vpc.tests.id

  tags = merge(local.tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.tests.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.tags, {
    Name = "${var.project_name}-public-${count.index}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.tests.id

  tags = merge(local.tags, {
    Name = "${var.project_name}-public"
  })
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.tests.id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "tasks" {
  name        = "${var.project_name}-tasks"
  description = "Allow outbound traffic for test tasks"
  vpc_id      = aws_vpc.tests.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.project_name}-tasks"
  })
}

resource "aws_cloudwatch_log_group" "tests" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_ecr_repository" "tests" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

data "aws_iam_policy_document" "cicd" {
  statement {
    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeTasks",
      "ecs:DescribeTaskDefinition",
      "ecs:ListClusters",
      "ecs:ListServices",
      "ecs:ListTaskDefinitions",
      "ecs:RegisterTaskDefinition",
      "ecs:RunTask",
      "ecs:StopTask",
      "ecs:UpdateService"
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "iam:PassRole"
    ]
    resources = [
      aws_iam_role.ecs_task_execution.arn,
      aws_iam_role.ecs_task.arn
    ]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [aws_ecr_repository.tests.arn]
  }

  statement {
    actions   = ["logs:GetLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_user" "cicd" {
  name = "${var.project_name}-github"

  tags = local.tags
}

resource "aws_iam_user_policy" "cicd" {
  name   = "${var.project_name}-github"
  user   = aws_iam_user.cicd.name
  policy = data.aws_iam_policy_document.cicd.json
}

resource "aws_ecs_cluster" "tests" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

locals {
  container_definitions = jsonencode([
    {
      name      = var.project_name
      image     = var.container_image
      essential = true
      command   = var.container_command
      cpu       = var.container_cpu
      memory    = var.container_memory
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.tests.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = var.project_name
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "tests" {
  family                   = var.task_family
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  container_definitions    = local.container_definitions
}

output "cluster_name" {
  value       = aws_ecs_cluster.tests.name
  description = "Name of the ECS cluster used for test workloads."
}

output "task_definition_arn" {
  value       = aws_ecs_task_definition.tests.arn
  description = "ARN of the ECS task definition registered for tests."
}

output "task_family" {
  value       = aws_ecs_task_definition.tests.family
  description = "Task definition family to update during deployments."
}

output "task_execution_role_arn" {
  value       = aws_iam_role.ecs_task_execution.arn
  description = "Execution role ARN passed to ECS tasks."
}

output "task_role_arn" {
  value       = aws_iam_role.ecs_task.arn
  description = "Task role ARN used by ECS tasks."
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.tests.repository_url
  description = "URL of the ECR repository used for test container images."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs for ECS task networking."
}

output "task_security_group_id" {
  value       = aws_security_group.tasks.id
  description = "Security group applied to ECS tasks."
}

output "ci_user_name" {
  value       = aws_iam_user.cicd.name
  description = "IAM user provisioned for CI/CD access."
}
