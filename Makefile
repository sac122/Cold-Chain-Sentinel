# Cold-Chain Sentinel — Makefile
# ================================
# Common tasks for local development and AWS deployment.
#
# Prerequisites: docker, docker compose, aws cli v2, terraform >= 1.5

.PHONY: help up down logs build push-all push-fog push-edge push-sim \
        tf-init tf-plan tf-apply tf-destroy \
        deploy-ecs update-ecs certs-from-ssm \
        sim-run sim-incident smoke-test clean

SHELL        := /bin/bash
.DEFAULT_GOAL:= help

# ── Project config ────────────────────────────────────────────────────────────
AWS_REGION   ?= us-east-1
PREFIX       ?= coldchain
TF_DIR       := cloud/terraform
AWS_ACCOUNT  := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
ECR_BASE     := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com/$(PREFIX)

TAG          ?= latest

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "Cold-Chain Sentinel — Available Targets"
	@echo "==========================================="
	@echo ""
	@echo "Local Development:"
	@echo "  make up               Start all services with docker compose"
	@echo "  make down             Stop and remove containers"
	@echo "  make logs             Follow logs for all services"
	@echo "  make build            Build all Docker images"
	@echo "  make sim-run          Run simulator (10 devices)"
	@echo "  make sim-incident     Run simulator with compressor_fail on device-000"
	@echo "  make smoke-test       Curl fog-processor health + metrics endpoints"
	@echo ""
	@echo "AWS Deployment:"
	@echo "  make tf-init          terraform init"
	@echo "  make tf-plan          terraform plan"
	@echo "  make tf-apply         terraform apply"
	@echo "  make tf-destroy       terraform destroy"
	@echo "  make push-all         Build + push all images to ECR"
	@echo "  make push-fog         Build + push fog-processor to ECR"
	@echo "  make push-edge        Build + push edge-processor to ECR"
	@echo "  make push-sim         Build + push simulator to ECR"
	@echo "  make deploy-ecs       Force new ECS deployment (rolling update)"
	@echo "  make certs-from-ssm   Download IoT certs from SSM to ./certs/"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean            Remove built images and Terraform .lambda_zips"
	@echo ""

# ── Local development ─────────────────────────────────────────────────────────

up:
	docker compose up -d
	@echo ""
	@echo "Services started. URLs:"
	@echo "  Mosquitto MQTT:     mqtt://localhost:1883"
	@echo "  Fog Processor API:  http://localhost:8080"
	@echo "  Grafana:            http://localhost:3000  (admin / coldchain123)"
	@echo ""

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

build:
	docker compose build --parallel

sim-run:
	docker compose run --rm simulator python -m simulator.main \
		--devices $(NUM_DEVICES) --seed 42

sim-incident:
	docker compose run --rm simulator python -m simulator.main \
		--devices 10 --incident compressor_fail --seed 42

smoke-test:
	@echo "==> Health check"
	curl -s http://localhost:8080/health | python3 -m json.tool
	@echo ""
	@echo "==> Metrics"
	curl -s http://localhost:8080/metrics | python3 -m json.tool
	@echo ""
	@echo "==> Buffer status"
	curl -s http://localhost:8080/buffer | python3 -m json.tool

# ── Docker / ECR ──────────────────────────────────────────────────────────────

ecr-login:
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin \
		$(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com

push-fog: ecr-login
	docker build -t $(ECR_BASE)/fog-processor:$(TAG) \
		-f fog/fog-processor/Dockerfile .
	docker push $(ECR_BASE)/fog-processor:$(TAG)
	@echo "Pushed: $(ECR_BASE)/fog-processor:$(TAG)"

push-edge: ecr-login
	docker build -t $(ECR_BASE)/edge-processor:$(TAG) \
		-f edge/Dockerfile .
	docker push $(ECR_BASE)/edge-processor:$(TAG)
	@echo "Pushed: $(ECR_BASE)/edge-processor:$(TAG)"

push-sim: ecr-login
	docker build -t $(ECR_BASE)/simulator:$(TAG) \
		-f simulator/Dockerfile .
	docker push $(ECR_BASE)/simulator:$(TAG)
	@echo "Pushed: $(ECR_BASE)/simulator:$(TAG)"

push-all: push-fog push-edge push-sim
	@echo "All images pushed."

# ── Terraform ─────────────────────────────────────────────────────────────────

tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	cd $(TF_DIR) && terraform plan \
		-var="aws_region=$(AWS_REGION)" \
		-var="prefix=$(PREFIX)"

tf-apply:
	mkdir -p $(TF_DIR)/.lambda_zips
	cd $(TF_DIR) && terraform apply \
		-var="aws_region=$(AWS_REGION)" \
		-var="prefix=$(PREFIX)" \
		-auto-approve
	@echo ""
	@echo "Infrastructure provisioned. Run 'make certs-from-ssm' to get certs."

tf-destroy:
	@echo "WARNING: This will delete all infrastructure."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ]
	cd $(TF_DIR) && terraform destroy \
		-var="aws_region=$(AWS_REGION)" \
		-var="prefix=$(PREFIX)" \
		-auto-approve

# ── ECS Deployment ────────────────────────────────────────────────────────────

deploy-ecs:
	aws ecs update-service \
		--cluster $(PREFIX)-cluster \
		--service $(PREFIX)-fog-processor \
		--force-new-deployment \
		--region $(AWS_REGION)
	@echo "ECS rolling deployment started."

update-ecs: push-fog deploy-ecs

# ── Certificate management ───────────────────────────────────────────────────

certs-from-ssm:
	@mkdir -p certs
	@echo "Downloading IoT certificates from SSM..."
	aws ssm get-parameter \
		--name "/$(PREFIX)/iot/cert-pem" \
		--with-decryption \
		--query Parameter.Value \
		--output text \
		--region $(AWS_REGION) > certs/device-cert.pem
	aws ssm get-parameter \
		--name "/$(PREFIX)/iot/private-key" \
		--with-decryption \
		--query Parameter.Value \
		--output text \
		--region $(AWS_REGION) > certs/private-key.pem
	curl -sSL https://www.amazontrust.com/repository/AmazonRootCA1.pem \
		-o certs/AmazonRootCA1.pem
	chmod 600 certs/private-key.pem certs/device-cert.pem
	@echo "Certificates written to ./certs/"
	@echo "  certs/device-cert.pem"
	@echo "  certs/private-key.pem"
	@echo "  certs/AmazonRootCA1.pem"

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	docker compose down -v --remove-orphans
	rm -rf $(TF_DIR)/.lambda_zips
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null; true
	find . -name "*.pyc" -delete 2>/dev/null; true
	@echo "Cleaned."
