# AWS Runbook — Cold-Chain Sentinel

Step-by-step guide to deploy Cold-Chain Sentinel on AWS.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| AWS CLI v2 | 2.x | `aws configure` with AdministratorAccess |
| Terraform | >= 1.5 | `brew install terraform` |
| Docker | 24.x | Docker Desktop or Docker Engine |
| bash | 5.x | macOS / Linux / WSL2 |

### AWS permissions required

The IAM user/role running Terraform needs:
- IoT: Full access (iot:*)
- DynamoDB: Full access
- Lambda: Full access
- IAM: CreateRole, AttachRolePolicy, PutRolePolicy
- ECR: Full access
- ECS: Full access
- SNS: Full access
- SSM: Full access
- Timestream: Full access
- API Gateway: Full access
- CloudWatch: Full access

For a student project, `AdministratorAccess` is acceptable.

## Step 1 — Configure Variables

```bash
# Clone and enter the project
cd cold-chain-sentinel

# Set environment variables (will be used by all scripts)
export AWS_REGION=us-east-1
export PREFIX=coldchain          # Change this if deploying multiple stacks
export ALERT_EMAIL=you@example.com
```

Or create a `terraform.tfvars` file:

```hcl
# cloud/terraform/terraform.tfvars
aws_region   = "us-east-1"
prefix       = "coldchain"
alert_email  = "you@example.com"

timestream_enabled       = true
grafana_enabled          = true
incident_ttl_days        = 90
log_retention_days       = 30
timestream_memory_hours  = 24
timestream_magnetic_days = 90
```

## Step 2 — Provision Infrastructure

```bash
# Option A: Automated (recommended)
chmod +x aws_setup.sh
./aws_setup.sh

# Option B: Manual step-by-step
make tf-init
make tf-plan   # Review what will be created
make tf-apply  # Apply (takes ~3-5 minutes)
```

Terraform creates:
- IoT Thing: `coldchain-fog-gateway`
- IoT Policy: `coldchain-fog-gateway-policy`
- IoT Certificate (stored in SSM)
- IoT Topic Rules: events → Lambda, telemetry → Timestream
- DynamoDB tables: `coldchain-incidents`, `coldchain-devices`
- Timestream DB/table: `coldchain-telemetry` / `device_telemetry`
- SNS topic: `coldchain-alerts` + email subscription
- Lambda functions: alert_handler, api_handler, stream_processor
- API Gateway: `https://xxx.execute-api.us-east-1.amazonaws.com/v1`
- ECR repos: `coldchain/fog-processor`, `coldchain/edge-processor`, `coldchain/simulator`
- ECS cluster: `coldchain-cluster`
- ECS service: `coldchain-fog-processor` (Fargate)
- CloudWatch log groups + dashboard

## Step 3 — Confirm SNS Email Subscription

Check your email inbox for a message from AWS SNS with subject:
`AWS Notification - Subscription Confirmation`

Click **Confirm subscription**.  Without this, alert emails won't be delivered.

## Step 4 — Retrieve IoT Certificates

```bash
make certs-from-ssm
# or manually:
mkdir -p certs
aws ssm get-parameter --name "/coldchain/iot/cert-pem" \
    --with-decryption --query Parameter.Value --output text > certs/device-cert.pem
aws ssm get-parameter --name "/coldchain/iot/private-key" \
    --with-decryption --query Parameter.Value --output text > certs/private-key.pem
curl -sSL https://www.amazontrust.com/repository/AmazonRootCA1.pem -o certs/AmazonRootCA1.pem
chmod 600 certs/private-key.pem
```

## Step 5 — Get IoT Core Endpoint

```bash
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS \
    --query endpointAddress --output text)
echo "IoT Endpoint: $IOT_ENDPOINT"
# Example: abcdef1234567-ats.iot.us-east-1.amazonaws.com
```

Add to `.env`:
```bash
echo "AWS_IOT_ENDPOINT=${IOT_ENDPOINT}" >> .env
```

## Step 6 — Build and Push Docker Images

```bash
# Build + push all images to ECR
make push-all AWS_REGION=us-east-1

# Or individually:
make push-fog   # fog-processor
make push-edge  # edge-processor
make push-sim   # simulator
```

## Step 7 — Start ECS Services

After pushing images, update the ECS service:

```bash
make deploy-ecs AWS_REGION=us-east-1
```

Watch the ECS service come up:

```bash
aws ecs describe-services \
    --cluster coldchain-cluster \
    --services coldchain-fog-processor \
    --region us-east-1 \
    --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount}"
```

## Step 8 — Run Simulator Pointing to AWS

For local simulator → fog → AWS IoT Core pipeline:

```bash
# This uses the AWS override compose file which mounts certs
docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d

# Or run simulator standalone pointing to your local fog:
docker compose run --rm simulator python -m simulator.main \
    --devices 20 --seed 42
```

The fog-processor will receive MQTT messages and forward to AWS IoT Core.

## Step 9 — Verify IoT Core Messages

```bash
# Subscribe using AWS CLI (requires --query-id for long-polling)
# Best done via AWS Console: IoT Core → Test → Subscribe to topic

# Or use MQTT client:
# Subscribe to: aws/coldchain/+/telemetry  and  aws/coldchain/+/events
# Using the same certificates (certs/) and endpoint
```

Via AWS Console:
1. Navigate to **IoT Core → Test → MQTT test client**
2. Subscribe to `aws/coldchain/+/telemetry`
3. You should see telemetry JSON arriving within seconds

## Step 10 — Verify DynamoDB

```bash
# Check incidents table
aws dynamodb scan \
    --table-name coldchain-incidents \
    --region us-east-1 \
    --limit 5 \
    --query "Items[*].{device:device_id.S, type:event_type.S, sev:severity.S}"

# Check devices table
aws dynamodb scan \
    --table-name coldchain-devices \
    --region us-east-1 \
    --query "Items[*].{device:device_id.S, last_seen:last_seen.S}"
```

## Step 11 — Verify Timestream

```bash
# Query last 10 temperature readings
aws timestream-query query \
    --query-string "SELECT device_id, time, measure_value::double AS temp_c \
        FROM \"coldchain-telemetry\".\"device_telemetry\" \
        WHERE measure_name = 'temp_c' \
        ORDER BY time DESC LIMIT 10" \
    --region us-east-1
```

## Step 12 — Test the API

```bash
# Get API Gateway URL from Terraform
API_URL=$(cd cloud/terraform && terraform output -raw api_gateway_url)
echo "API URL: $API_URL"

# List devices
curl -s "${API_URL}/devices" | python3 -m json.tool

# List incidents
curl -s "${API_URL}/incidents" | python3 -m json.tool

# Device summary (after some events have been generated)
curl -s "${API_URL}/devices/truck-000/summary" | python3 -m json.tool
```

## Step 13 — Trigger a Test Alert

```bash
# Inject a compressor failure scenario on device-000
docker compose run --rm -e INCIDENTS=compressor_fail simulator \
    python -m simulator.main --devices 3 --seed 42
```

After ~30 seconds, `TEMP_EXCURSION` events should:
1. Appear in DynamoDB incidents table
2. Trigger the alert Lambda
3. Deliver an SNS email to your inbox

## Step 14 — View Grafana (on ECS)

```bash
# Get Grafana task's public IP
TASK_ARN=$(aws ecs list-tasks --cluster coldchain-cluster \
    --service-name coldchain-grafana --query taskArns[0] --output text)
ENI_ID=$(aws ecs describe-tasks --cluster coldchain-cluster \
    --tasks "$TASK_ARN" \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
    --output text)
PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text)
echo "Grafana: http://${PUBLIC_IP}:3000"
```

Login with `admin` and the password set in `TF_VAR_grafana_admin_password`.

Configure the Timestream datasource:
1. Go to **Configuration → Data Sources → Add → Amazon Timestream**
2. Auth Type: `EC2 IAM Role`
3. Region: `us-east-1`
4. Test connection → should show "Data source is working"

## Monitoring

### CloudWatch Logs

```bash
# Fog processor logs (real-time)
aws logs tail /coldchain/fog-processor --follow --region us-east-1

# Alert Lambda logs
aws logs tail /coldchain/lambda-alerts --follow --region us-east-1

# API Lambda logs
aws logs tail /coldchain/lambda-api --follow --region us-east-1
```

### CloudWatch Dashboard

AWS Console → CloudWatch → Dashboards → `coldchain-overview`

### ECS Exec (live debugging)

```bash
# Shell into the running fog-processor container
TASK_ARN=$(aws ecs list-tasks --cluster coldchain-cluster \
    --service-name coldchain-fog-processor --query taskArns[0] --output text)
aws ecs execute-command \
    --cluster coldchain-cluster \
    --task "$TASK_ARN" \
    --container fog-processor \
    --command "/bin/bash" \
    --interactive
```

## EC2 Alternative Deployment

If you prefer EC2 over ECS Fargate:

```bash
# Launch Amazon Linux 2023 instance
aws ec2 run-instances \
    --image-id ami-0889a44b331db0194 \
    --instance-type t3.small \
    --key-name my-keypair \
    --security-group-ids sg-xxx \
    --iam-instance-profile Name=coldchain-ec2-profile \
    --user-data '#!/bin/bash
        dnf install -y docker
        systemctl start docker
        aws ecr get-login-password --region us-east-1 | \
            docker login --username AWS --password-stdin \
            <account>.dkr.ecr.us-east-1.amazonaws.com
        docker run -d --name fog-processor \
            -p 8080:8080 \
            -e AWS_IOT_ENDPOINT=<endpoint> \
            -e AWS_REGION=us-east-1 \
            -v /certs:/certs:ro \
            <account>.dkr.ecr.us-east-1.amazonaws.com/coldchain/fog-processor:latest
    '
```

Required IAM instance profile permissions:
- `AmazonSSMReadOnlyAccess` (for cert retrieval)
- `AmazonECSTaskExecutionRolePolicy` (for ECR pull)

## Teardown

```bash
# Stop ECS services
aws ecs update-service --cluster coldchain-cluster \
    --service coldchain-fog-processor --desired-count 0

# Destroy all infrastructure
make tf-destroy

# Warning: this deletes all DynamoDB data, Timestream data,
# certificates, and ECR images.
```
