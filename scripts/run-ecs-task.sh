#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run this script" >&2
  exit 1
fi

: "${TASK_FAMILY:?TASK_FAMILY environment variable is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME environment variable is required}"
: "${IMAGE_URI:?IMAGE_URI environment variable is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER environment variable is required}"
: "${ECS_SUBNETS:?ECS_SUBNETS environment variable is required}"
: "${ECS_SECURITY_GROUPS:?ECS_SECURITY_GROUPS environment variable is required}"

LAUNCH_TYPE=${LAUNCH_TYPE:-FARGATE}
ASSIGN_PUBLIC_IP=${ASSIGN_PUBLIC_IP:-ENABLED}

TASK_DEF_JSON=$(aws ecs describe-task-definition --task-definition "$TASK_FAMILY")

NEW_TASK_DEF=$(echo "$TASK_DEF_JSON" | jq --arg IMAGE "$IMAGE_URI" --arg NAME "$CONTAINER_NAME" '
  {
    family: .taskDefinition.family,
    executionRoleArn: .taskDefinition.executionRoleArn,
    taskRoleArn: .taskDefinition.taskRoleArn,
    networkMode: .taskDefinition.networkMode,
    containerDefinitions: (.taskDefinition.containerDefinitions | map(if .name == $NAME then .image = $IMAGE | . else . end)),
    requiresCompatibilities: .taskDefinition.requiresCompatibilities,
    cpu: .taskDefinition.cpu,
    memory: .taskDefinition.memory,
    volumes: .taskDefinition.volumes,
    placementConstraints: .taskDefinition.placementConstraints,
    runtimePlatform: .taskDefinition.runtimePlatform
  } | with_entries(select(.value != null and (.value | tostring) != "null"))
')

REGISTER_OUTPUT=$(aws ecs register-task-definition --cli-input-json "$NEW_TASK_DEF")
NEW_TASK_DEF_ARN=$(echo "$REGISTER_OUTPUT" | jq -r '.taskDefinition.taskDefinitionArn')

SUBNET_LIST=$(echo "$ECS_SUBNETS" | tr -d ' ')
SG_LIST=$(echo "$ECS_SECURITY_GROUPS" | tr -d ' ')

NETWORK_CONFIGURATION="awsvpcConfiguration={subnets=[$SUBNET_LIST],securityGroups=[$SG_LIST],assignPublicIp=$ASSIGN_PUBLIC_IP}"

RUN_OUTPUT=$(aws ecs run-task \
  --cluster "$ECS_CLUSTER" \
  --launch-type "$LAUNCH_TYPE" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --network-configuration "$NETWORK_CONFIGURATION")

FAILURES=$(echo "$RUN_OUTPUT" | jq '.failures | length')
if [[ "$FAILURES" -ne 0 ]]; then
  echo "Failed to run ECS task:" >&2
  echo "$RUN_OUTPUT" | jq '.failures' >&2
  exit 1
fi

TASK_ARN=$(echo "$RUN_OUTPUT" | jq -r '.tasks[0].taskArn')
TASK_ID=${TASK_ARN##*/}

echo "Started task $TASK_ARN" >&2

aws ecs wait tasks-stopped --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN"

describe=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN")
STOPPED_REASON=$(echo "$describe" | jq -r '.tasks[0].stoppedReason')
EXIT_CODE=$(echo "$describe" | jq -r --arg NAME "$CONTAINER_NAME" '.tasks[0].containers[] | select(.name == $NAME) | .exitCode // 1')

LOG_GROUP=$(echo "$NEW_TASK_DEF" | jq -r --arg NAME "$CONTAINER_NAME" '.containerDefinitions[] | select(.name == $NAME) | .logConfiguration.options["awslogs-group"] // empty')
LOG_PREFIX=$(echo "$NEW_TASK_DEF" | jq -r --arg NAME "$CONTAINER_NAME" '.containerDefinitions[] | select(.name == $NAME) | .logConfiguration.options["awslogs-stream-prefix"] // empty')

if [[ -n "$LOG_GROUP" && -n "$LOG_PREFIX" ]]; then
  LOG_STREAM="$LOG_PREFIX/$CONTAINER_NAME/$TASK_ID"
  echo "--- CloudWatch Logs ($LOG_GROUP :: $LOG_STREAM) ---"
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM" --start-from-head >/tmp/logs.txt || true
  cat /tmp/logs.txt
  rm -f /tmp/logs.txt
  echo "--- End Logs ---"
fi

echo "Task stopped reason: $STOPPED_REASON" >&2

echo "Container exit code: $EXIT_CODE" >&2

if [[ "$EXIT_CODE" != "0" ]]; then
  echo "ECS task failed" >&2
  exit "$EXIT_CODE"
fi

echo "ECS task completed successfully" >&2
