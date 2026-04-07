#!/usr/bin/env bash
# =============================================================================
# Cold-Chain Sentinel — Complete AWS Production Deployment Script
# =============================================================================
#
# What this script does (in order):
#   1.  Validates prerequisites (aws cli, docker, terraform, jq)
#   2.  Runs terraform init + plan + apply  →  provisions ALL AWS resources
#   3.  Retrieves IoT certificates from SSM  →  saved to ./certs/
#   4.  Gets AWS IoT Core endpoint
#   5.  Logs into ECR
#   6.  Builds + pushes 4 Docker images:
#         fog-processor, edge-processor, simulator, dashboard
#   7.  Forces new ECS deployments for all 5 services
#   8.  Waits for ECS services to stabilise (~3 min)
#   9.  Prints the dashboard URL and quick-test commands
#
# Usage:
#   export AWS_REGION=us-east-1
#   export PREFIX=coldchain
#   export ALERT_EMAIL=you@example.com
#   chmod +x aws_setup.sh
#   ./aws_setup.sh
#
# Re-running after a code change (just rebuild + redeploy, skip Terraform):
#   ./aws_setup.sh --skip-terraform
#
# Options:
#   --skip-terraform    Skip terraform apply (infra already exists)
#   --skip-build        Skip Docker build+push (image already in ECR)
#   --skip-deploy       Skip ECS force-new-deployment
#   --no-wait           Don't wait for ECS services to stabilise
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; NC="\033[0m"
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${CYAN}══════ $* ══════${NC}\n"; }
step()    { echo -e "${GREEN}  ▶${NC} $*"; }

# ── CLI flags ─────────────────────────────────────────────────────────────────
SKIP_TERRAFORM=false
SKIP_BUILD=false
SKIP_DEPLOY=false
NO_WAIT=false

for arg in "$@"; do
  case $arg in
    --skip-terraform) SKIP_TERRAFORM=true ;;
    --skip-build)     SKIP_BUILD=true ;;
    --skip-deploy)    SKIP_DEPLOY=true ;;
    --no-wait)        NO_WAIT=true ;;
    --help|-h)
      grep '^#' "$0" | head -30 | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-coldchain}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
TF_DIR="cloud/terraform"

# ── Prerequisites ─────────────────────────────────────────────────────────────
header "Checking prerequisites"

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "$1 is required but not installed."
  step "$1 → $(command -v "$1")"
}

check_cmd aws
check_cmd docker
check_cmd terraform
check_cmd jq

# Terraform version check (need >= 1.5)
TF_VER=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo "0.0.0")
step "Terraform $TF_VER"

# AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION" 2>/dev/null) \
  || error "AWS credentials not configured. Run: aws configure"

step "AWS Account : $AWS_ACCOUNT"
step "AWS Region  : $AWS_REGION"
step "Prefix      : $PREFIX"

if [ -z "$ALERT_EMAIL" ]; then
  warn "ALERT_EMAIL not set — SNS will use placeholder@example.com"
  ALERT_EMAIL="placeholder@example.com"
fi
step "Alert Email : $ALERT_EMAIL"

ECR_BASE="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PREFIX}"

# ── Terraform ─────────────────────────────────────────────────────────────────
if [ "$SKIP_TERRAFORM" = false ]; then
  header "Provisioning AWS Infrastructure (Terraform)"

  mkdir -p "${TF_DIR}/.lambda_zips"
  pushd "$TF_DIR" > /dev/null

  step "terraform init"
  terraform init -upgrade -input=false

  step "terraform plan"
  terraform plan \
    -var="aws_region=${AWS_REGION}" \
    -var="prefix=${PREFIX}" \
    -var="alert_email=${ALERT_EMAIL}" \
    -out=tfplan \
    -input=false

  echo ""
  warn "Applying in 10 seconds… (Ctrl+C to abort)"
  sleep 10

  terraform apply -auto-approve tfplan

  step "Capturing Terraform outputs"
  TF_OUTPUTS=$(terraform output -json 2>/dev/null || echo "{}")
  popd > /dev/null
else
  info "--skip-terraform: reusing existing infrastructure"
  pushd "$TF_DIR" > /dev/null
  TF_OUTPUTS=$(terraform output -json 2>/dev/null || echo "{}")
  popd > /dev/null
fi

# Pull key values from Terraform outputs
API_GW_URL=$(echo "$TF_OUTPUTS"     | jq -r '.api_gateway_url.value    // empty' 2>/dev/null || true)
DASHBOARD_URL=$(echo "$TF_OUTPUTS"  | jq -r '.dashboard_url.value      // empty' 2>/dev/null || true)
ECR_FOG=$(echo "$TF_OUTPUTS"        | jq -r '.ecr_fog_repo_url.value   // empty' 2>/dev/null || true)
ECR_EDGE=$(echo "$TF_OUTPUTS"       | jq -r '.ecr_edge_repo_url.value  // empty' 2>/dev/null || true)
ECR_SIM=$(echo "$TF_OUTPUTS"        | jq -r '.ecr_simulator_repo_url.value  // empty' 2>/dev/null || true)
ECR_DASH=$(echo "$TF_OUTPUTS"       | jq -r '.ecr_dashboard_repo_url.value  // empty' 2>/dev/null || true)
ECS_CLUSTER=$(echo "$TF_OUTPUTS"    | jq -r '.ecs_cluster_name.value   // empty' 2>/dev/null || "${PREFIX}-cluster")

# Fall back to convention-based names if outputs unavailable
ECR_FOG="${ECR_FOG:-${ECR_BASE}/fog-processor}"
ECR_EDGE="${ECR_EDGE:-${ECR_BASE}/edge-processor}"
ECR_SIM="${ECR_SIM:-${ECR_BASE}/simulator}"
ECR_DASH="${ECR_DASH:-${ECR_BASE}/dashboard}"
ECS_CLUSTER="${ECS_CLUSTER:-${PREFIX}-cluster}"

# ── IoT Certificates ──────────────────────────────────────────────────────────
header "Retrieving IoT Certificates"

mkdir -p certs

step "device-cert.pem"
aws ssm get-parameter \
  --name "/${PREFIX}/iot/cert-pem" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" > certs/device-cert.pem

step "private-key.pem"
aws ssm get-parameter \
  --name "/${PREFIX}/iot/private-key" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION" > certs/private-key.pem

step "AmazonRootCA1.pem"
curl -sSL https://www.amazontrust.com/repository/AmazonRootCA1.pem \
  -o certs/AmazonRootCA1.pem

chmod 600 certs/private-key.pem certs/device-cert.pem
info "Certificates saved to ./certs/"

# ── IoT Core endpoint ─────────────────────────────────────────────────────────
header "Retrieving IoT Core Endpoint"

IOT_ENDPOINT=$(aws iot describe-endpoint \
  --endpoint-type iot:Data-ATS \
  --query endpointAddress \
  --output text \
  --region "$AWS_REGION")
step "IoT Endpoint: $IOT_ENDPOINT"

# Write .env
cat > .env << EOF
# Cold-Chain Sentinel — AWS environment
# Generated by aws_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
AWS_REGION=${AWS_REGION}
AWS_ACCOUNT_ID=${AWS_ACCOUNT}
PREFIX=${PREFIX}
AWS_IOT_ENDPOINT=${IOT_ENDPOINT}
AWS_IOT_CLIENT_ID=fog-gateway-001
ALERT_EMAIL=${ALERT_EMAIL}
ECS_CLUSTER=${ECS_CLUSTER}
DASHBOARD_URL=${DASHBOARD_URL:-pending}
API_GATEWAY_URL=${API_GW_URL:-pending}
EOF
info ".env written"

# ── Build and push Docker images ──────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
  header "Building and Pushing Docker Images to ECR"

  step "ECR login"
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  build_push() {
    local name=$1
    local tag=$2
    local dockerfile=$3
    step "Building ${name}…"
    docker build \
      --platform linux/amd64 \
      -t "${tag}:latest" \
      -f "${dockerfile}" \
      .
    step "Pushing ${name}…"
    docker push "${tag}:latest"
    info "✓ ${name} → ${tag}:latest"
  }

  # Build from project root (context = .) so all COPY paths resolve
  build_push "fog-processor"  "${ECR_FOG}"  "fog/fog-processor/Dockerfile"
  build_push "edge-processor" "${ECR_EDGE}" "edge/Dockerfile"
  build_push "simulator"      "${ECR_SIM}"  "simulator/Dockerfile"
  build_push "dashboard"      "${ECR_DASH}" "dashboard/Dockerfile"

  info "All images pushed to ECR"
else
  info "--skip-build: using existing ECR images"
fi

# ── ECS deployments ───────────────────────────────────────────────────────────
if [ "$SKIP_DEPLOY" = false ]; then
  header "Deploying ECS Services"

  ecs_deploy() {
    local svc=$1
    local full_name="${PREFIX}-${svc}"
    step "Updating ${full_name}…"
    aws ecs update-service \
      --cluster "${ECS_CLUSTER}" \
      --service "${full_name}" \
      --force-new-deployment \
      --region "$AWS_REGION" \
      --query "service.status" \
      --output text 2>/dev/null \
      && info "  ✓ ${full_name} deployment triggered" \
      || warn "  ✗ ${full_name} service not found (may start on first apply)"
  }

  ecs_deploy "mosquitto"
  ecs_deploy "edge-processor"
  ecs_deploy "fog-processor"
  ecs_deploy "simulator"
  ecs_deploy "dashboard"

else
  info "--skip-deploy: skipping ECS force-new-deployment"
fi

# ── Wait for services ─────────────────────────────────────────────────────────
if [ "$NO_WAIT" = false ] && [ "$SKIP_DEPLOY" = false ]; then
  header "Waiting for ECS services to stabilise (~3 min)"
  info "Press Ctrl+C to skip waiting (services continue deploying in background)"

  wait_service() {
    local svc="${PREFIX}-$1"
    step "Waiting: ${svc}"
    aws ecs wait services-stable \
      --cluster "${ECS_CLUSTER}" \
      --services "${svc}" \
      --region "$AWS_REGION" 2>/dev/null \
      && info "  ✓ ${svc} stable" \
      || warn "  ✗ ${svc} did not stabilise in time (check CloudWatch logs)"
  }

  # Wait in dependency order
  wait_service "mosquitto"     &
  WAIT_MOSQUITTO=$!
  wait $WAIT_MOSQUITTO

  wait_service "edge-processor" &
  wait_service "fog-processor"  &
  wait_service "simulator"      &
  wait

  wait_service "dashboard"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
header "Deployment Complete"

# Refresh dashboard URL from ALB in case it wasn't in outputs yet
if [ -z "$DASHBOARD_URL" ]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names "${PREFIX}-dash-alb" \
    --query "LoadBalancers[0].DNSName" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "pending")
  DASHBOARD_URL="http://${ALB_DNS}"
fi

cat << EOF

╔══════════════════════════════════════════════════════════════════╗
║        Cold-Chain Sentinel — Live on AWS                        ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  🌐  Dashboard         ${DASHBOARD_URL:-http://pending (ALB starting)}
║  📡  API Gateway       ${API_GW_URL:-run: terraform output api_gateway_url}
║  🔒  IoT Endpoint      ${IOT_ENDPOINT}
║  🖥   ECS Cluster       ${ECS_CLUSTER}
║  📜  Certificates      ./certs/
║  ⚙️   Config            .env
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║  Quick Tests                                                     ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  # Check dashboard health:
║  curl ${DASHBOARD_URL:-<DASHBOARD_URL>}/api/health
║
║  # Query incidents via API Gateway:
║  curl ${API_GW_URL:-<API_GW_URL>}/incidents
║
║  # Stream fog-processor logs:
║  aws logs tail /${PREFIX}/fog-processor --follow
║
║  # Stream dashboard logs:
║  aws logs tail /${PREFIX}/dashboard --follow
║
║  # SSH into a running container (ECS Exec):
║  aws ecs execute-command \\
║    --cluster ${ECS_CLUSTER} \\
║    --task \$(aws ecs list-tasks --cluster ${ECS_CLUSTER} \\
║             --service-name ${PREFIX}-dashboard \\
║             --query taskArns[0] --output text) \\
║    --container dashboard --interactive --command /bin/sh
║
║  # To update code only (no Terraform):
║  ./aws_setup.sh --skip-terraform
║
║  # To just redeploy (image already in ECR):
║  ./aws_setup.sh --skip-terraform --skip-build
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║  ⚠️  Check your email (${ALERT_EMAIL}) to confirm SNS alerts     ║
╚══════════════════════════════════════════════════════════════════╝

EOF
