# Automated Fargate Deployment Pipeline

This repository now contains Terraform configuration for provisioning an AWS Fargate environment and a GitHub Actions workflow to build, publish, and deploy the application.

## 1. Provision infrastructure with Terraform

1. Install [Terraform](https://developer.hashicorp.com/terraform/downloads).
2. Copy `infra/terraform/terraform.tfvars.example` to `infra/terraform/terraform.tfvars` and update the values:
   - `aws_region`: AWS region to deploy to.
   - `project_name`: Short, unique name used when naming resources.
   - `container_image`: The initial image to deploy (the GitHub Actions workflow will overwrite this on subsequent deployments).
3. Initialise and apply the Terraform plan:

   ```bash
   cd infra/terraform
   terraform init
   terraform apply
   ```

   Terraform provisions the following:

   - VPC, public subnets, security groups, and an internet-facing Application Load Balancer.
   - Amazon ECS cluster, task definition, service, CloudWatch log group, and Amazon ECR repository.
   - IAM roles for the ECS task and execution, plus a CI/CD IAM user with the least privileges required to deploy.

4. Capture the outputs displayed after a successful apply. They are required to configure the CI pipeline:
   - `cluster_name`
   - `service_name`
   - `task_family`
   - `ecr_repository_url`
   - `ci_user_name`
   - `load_balancer_dns`

5. Create an access key for the `${project_name}-github` IAM user via the AWS Console or CLI. The access key ID and secret access key must be stored as GitHub Secrets (see below). The secret access key is only shown once—store it securely.

## 2. Configure GitHub Secrets

Add the following secrets to the repository (Settings → Secrets and variables → Actions):

| Secret Name            | Value                                                                 |
| ---------------------- | --------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`    | Access key ID for the `${project_name}-github` IAM user.              |
| `AWS_SECRET_ACCESS_KEY`| Secret access key for the IAM user.                                   |
| `AWS_REGION`           | Same region used in Terraform (`aws_region`).                         |
| `ECR_REPOSITORY`       | Repository name (last segment of `ecr_repository_url`).               |
| `ECS_CLUSTER_NAME`     | Value from the Terraform `cluster_name` output.                       |
| `ECS_SERVICE_NAME`     | Value from the Terraform `service_name` output.                       |
| `ECS_TASK_FAMILY`      | Value from the Terraform `task_family` output.                        |

The GitHub Actions workflow uses OIDC-capable tooling, but access keys are required for the IAM user because Terraform provisions the user rather than a role in the GitHub account.

## 3. Deployment workflow

The workflow defined in `.github/workflows/deploy.yml` runs on every push to the `main` branch and can be triggered manually. It performs the following steps:

1. Checks out the repository.
2. Configures AWS credentials from secrets.
3. Logs in to the Amazon ECR registry created by Terraform.
4. Builds the Docker image using the repository's `Dockerfile` and tags it with the current commit SHA.
5. Pushes the image to ECR.
6. Retrieves the latest ECS task definition revision, swaps the container image for the freshly built one, and registers a new revision.
7. Updates the ECS service to use the new task definition and waits for the deployment to stabilise.

Once the workflow completes, the application becomes available through the load balancer DNS name output by Terraform.

Health checks:
- The Application Load Balancer is configured to probe path "/" and treat 200-399 as healthy.
- The application exposes health endpoints at "/", "/health", and "/healthz" which return HTTP 200 with JSON {"status":"ok"}.
- The Docker image defines a HEALTHCHECK that probes http://localhost:${APP_PORT:-8080}/health (falls back to 5000). This makes the container health visible to ECS when container health checks are enabled.

## 4. Ongoing maintenance

- Re-run `terraform apply` whenever you need to modify infrastructure-level settings (for example CPU/memory, scaling, networking, or environment variables). Application-level changes should be handled by GitHub Actions deployments.
- Rotate the CI/CD user's access keys regularly and update the corresponding GitHub Secrets.
- Monitor the ECS service, load balancer, and CloudWatch logs to ensure successful deployments.
