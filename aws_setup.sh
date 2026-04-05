#!/usr/bin/env bash
# =============================================================================
# Cold-Chain Sentinel — AWS Setup Script
# =============================================================================
# Usage:
#   export AWS_REGION=us-east-1
#   export PREFIX=coldchain
#   export ALERT_EMAIL=your@email.com
#   chmod +x aws_setup.sh && ./aws_setup.sh
#
# What this script does (in order):
#   1. Validates prerequisites (aws cli, docker, terraform)
#   2. Creates .lambda_zips directory
#   3. Runs terraform init + apply (provisions all AWS resources)
#   4. Retrieves IoT certificates from SSM and saves to ./certs/
#   5. Builds and pushes Docker images to ECR
#   6. Forces a new ECS deployment
#   7. Prints the API Gateway URL and next steps
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-coldchain}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
TF_DIR="cloud/terraform"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${GREEN}=== $* ===${NC}\n"; }

# ── Check prerequisites ───────────────────────────────────────────────────────
header "Checking prerequisites"

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "$1 is required but not installed."
    info "$1: $(command -v "$1")"
}

check_cmd aws
check_cmd docker
check_cmd terraform

# Validate Terraform version
TF_VERSION=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || echo "0.0.0")
info "Terraform version: $TF_VERSION"

# Validate AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION") \
    || error "AWS credentials not configured. Run: aws configure"
info "AWS Account: $AWS_ACCOUNT"
info "AWS Region:  $AWS_REGION"
info "Prefix:      $PREFIX"

if [ -z "$ALERT_EMAIL" ]; then
    warn "ALERT_EMAIL is not set. SNS subscription will use a placeholder."
    ALERT_EMAIL="placeholder@example.com"
fi
info "Alert Email: $ALERT_EMAIL"

# ── Terraform init + apply ────────────────────────────────────────────────────
header "Provisioning AWS Infrastructure (Terraform)"

mkdir -p "${TF_DIR}/.lambda_zips"

cd "$TF_DIR"

terraform init -upgrade

terraform plan \
    -var="aws_region=${AWS_REGION}" \
    -var="prefix=${PREFIX}" \
    -var="alert_email=${ALERT_EMAIL}" \
    -out=tfplan

echo ""
warn "Review the plan above. Applying in 10 seconds... (Ctrl+C to abort)"
sleep 10

terraform apply tfplan

# Capture outputs
API_GW_URL=$(terraform output -raw api_gateway_url 2>/dev/null || echo "")
INCIDENTS_TABLE=$(terraform output -raw incidents_table_name 2>/dev/null || echo "")
ECR_FOG_URL=$(terraform output -raw ecr_fog_repo_url 2>/dev/null || echo "")

cd - >/dev/null

# ── Retrieve IoT certificates ─────────────────────────────────────────────────
header "Retrieving IoT Certificates from SSM"

mkdir -p certs

aws ssm get-parameter \
    --name "/${PREFIX}/iot/cert-pem" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region "$AWS_REGION" > certs/device-cert.pem

aws ssm get-parameter \
    --name "/${PREFIX}/iot/private-key" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region "$AWS_REGION" > certs/private-key.pem

curl -sSL https://www.amazontrust.com/repository/AmazonRootCA1.pem \
    -o certs/AmazonRootCA1.pem

chmod 600 certs/private-key.pem certs/device-cert.pem

info "Certificates saved to ./certs/"

# ── Get IoT Core endpoint ─────────────────────────────────────────────────────
header "Retrieving IoT Core Endpoint"

IOT_ENDPOINT=$(aws iot describe-endpoint \
    --endpoint-type iot:Data-ATS \
    --query endpointAddress \
    --output text \
    --region "$AWS_REGION")

info "IoT Core Endpoint: $IOT_ENDPOINT"

# Write .env file
cat > .env << EOF
AWS_REGION=${AWS_REGION}
AWS_ACCOUNT_ID=${AWS_ACCOUNT}
PREFIX=${PREFIX}
AWS_IOT_ENDPOINT=${IOT_ENDPOINT}
AWS_IOT_CLIENT_ID=fog-gateway-001
ALERT_EMAIL=${ALERT_EMAIL}
EOF
info ".env file created"

# ── Build and push Docker images ──────────────────────────────────────────────
header "Building and Pushing Docker Images to ECR"

# ECR login
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

ECR_BASE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PREFIX}"

# Build and push fog-processor
info "Building fog-processor..."
docker build -t "${ECR_BASE}/fog-processor:latest" \
    -f fog/fog-processor/Dockerfile .
docker push "${ECR_BASE}/fog-processor:latest"
info "fog-processor pushed: ${ECR_BASE}/fog-processor:latest"

# Build and push simulator (needed if running from ECS)
info "Building simulator..."
docker build -t "${ECR_BASE}/simulator:latest" \
    -f simulator/Dockerfile .
docker push "${ECR_BASE}/simulator:latest"
info "simulator pushed"

# ── ECS deployment ────────────────────────────────────────────────────────────
header "Starting ECS Services"

# Update fog-processor task definition image URI
FOG_TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "${PREFIX}-fog-processor" \
    --region "$AWS_REGION" \
    --query taskDefinition \
    --output json 2>/dev/null || echo "{}")

if [ "$FOG_TASK_DEF" != "{}" ]; then
    aws ecs update-service \
        --cluster "${PREFIX}-cluster" \
        --service "${PREFIX}-fog-processor" \
        --force-new-deployment \
        --region "$AWS_REGION" \
        --output text --query "service.status" \
        && info "ECS fog-processor service updated" \
        || warn "ECS update failed — task may not be running yet"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
header "Setup Complete"

cat << EOF

=====================================================================
 Cold-Chain Sentinel — AWS Infrastructure Ready
=====================================================================

 IoT Core Endpoint : ${IOT_ENDPOINT}
 API Gateway URL   : ${API_GW_URL:-"Run: terraform output api_gateway_url"}
 DynamoDB Incidents: ${INCIDENTS_TABLE}
 ECR Fog Image     : ${ECR_BASE}/fog-processor:latest
 ECS Cluster       : ${PREFIX}-cluster

 Certificates      : ./certs/ (device-cert.pem, private-key.pem)
 Config            : .env

Next Steps:
  1. Confirm SNS alert email subscription (check your inbox)
  2. Test the API:
       curl "${API_GW_URL:-<API_GW_URL>}/devices"
       curl "${API_GW_URL:-<API_GW_URL>}/incidents"
  3. Run simulator pointing to fog:
       export AWS_IOT_ENDPOINT=${IOT_ENDPOINT}
       docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d
  4. View Grafana (after ECS starts):
       aws ecs describe-tasks --cluster ${PREFIX}-cluster \\
           --tasks \$(aws ecs list-tasks --cluster ${PREFIX}-cluster --output text --query taskArns[0])
  5. Monitor CloudWatch:
       aws logs tail /${PREFIX}/fog-processor --follow

=====================================================================
EOF
