# ECS Fargate Load Test Runner

This repository provisions the AWS infrastructure required to execute the load tests on-demand in AWS Fargate and wires it up to a reusable GitHub Actions workflow. Each workflow run builds the tester image, launches a one-off ECS task, streams the CloudWatch logs, and fails the workflow if the task exits non-zero.

## 1. Provision the infrastructure with Terraform

1. Install [Terraform](https://developer.hashicorp.com/terraform/downloads).
2. Copy `infra/terraform/terraform.tfvars.example` to `infra/terraform/terraform.tfvars` and supply values for:
   - `aws_region`: Region that should host the temporary test infrastructure.
   - `project_name`: Short, unique name used as a prefix for all resources.
   - `container_image`: Seed image to register in the initial task definition (the workflow swaps this on every run).
   - Optionally adjust CPU/memory or command values if your tests require different defaults.
3. Apply the configuration:

   ```bash
   cd infra/terraform
   terraform init
   terraform apply
   ```

Terraform creates:

- A VPC with two public subnets, routing, and a security group that allows the Fargate tasks outbound internet access.
- An Amazon ECR repository where the tester image is published.
- An ECS cluster and task definition tailored for Fargate, including CloudWatch logging configuration.
- IAM roles for the task execution and runtime permissions.
- A `${project_name}-github` IAM user that the CI pipeline uses to build images and launch tasks.

After `terraform apply` completes, capture the outputs—they feed into the workflow configuration:

| Output name             | Purpose                                            |
| ----------------------- | -------------------------------------------------- |
| `cluster_name`          | Cluster where tasks are launched.                  |
| `task_definition_arn`   | Initial task definition revision (informational).  |
| `task_family`           | Family name that the workflow updates each run.    |
| `ecr_repository_url`    | Full URI for the tester image repository.         |
| `public_subnet_ids`     | Comma-separated subnet IDs for the task network.   |
| `task_security_group_id`| Security group applied to test tasks.              |
| `ci_user_name`          | Name of the IAM user created for CI access.        |

Generate an access key for the `${project_name}-github` user via the AWS Console or CLI—you will only see the secret key once, so store it securely.

## 2. Configure GitHub Actions secrets

Add the following repository secrets (Settings → Secrets and variables → Actions):

| Secret name             | Value                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | Access key ID for the `${project_name}-github` IAM user.              |
| `AWS_SECRET_ACCESS_KEY` | Secret key for the IAM user.                                          |
| `AWS_REGION`            | Same value as `aws_region` in Terraform.                              |
| `ECR_REPOSITORY`        | Repository name (last segment of `ecr_repository_url`).               |
| `ECS_CLUSTER`           | Value from the `cluster_name` output.                                 |
| `ECS_TASK_FAMILY`       | Value from the `task_family` output.                                  |
| `ECS_SUBNETS`           | Comma-separated list of IDs from `public_subnet_ids`.                 |
| `ECS_SECURITY_GROUPS`   | The ID from `task_security_group_id`.                                 |
| `ECS_CONTAINER_NAME`    | Container name inside the task definition (defaults to `project_name`). |

The workflow defined in `.github/workflows/ecs-tests.yml` expects these secrets and environment variables. It uses static credentials because Terraform provisions an IAM user rather than an assumable GitHub OIDC role.

## 3. How the GitHub Actions workflow runs tests

The **Run ECS Load Tests** workflow triggers on pushes to `main` or via the `workflow_dispatch` button. It performs the following steps:

1. Checks out the repository code.
2. Configures AWS credentials from the repository secrets.
3. Authenticates to the ECR registry emitted by Terraform.
4. Builds the tester Docker image from the repository and tags it with the short commit SHA.
5. Pushes the image to ECR.
6. Invokes `scripts/run-ecs-task.sh`, which:
   - Registers a new task definition revision with the freshly built image.
   - Starts a Fargate task in the provided subnets and security group.
   - Waits for the task to finish, streams CloudWatch Logs, and returns the container exit code.

If the ECS task exits non-zero, the workflow fails—use this to gate merges or release workflows on successful load-test execution.

## 4. Monitoring and maintenance

- Review CloudWatch Logs streamed in the workflow output or directly in the AWS console for deeper debugging.
- Tune CPU, memory, and command defaults in `infra/terraform/variables.tf` and re-run `terraform apply` when resource requirements change.
- Rotate the CI user credentials regularly and update the corresponding GitHub Secrets.
- Clean up infrastructure when it is no longer needed by running `terraform destroy` from the `infra/terraform` directory.
