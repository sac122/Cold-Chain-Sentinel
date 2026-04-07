# ── ECR Repositories ──────────────────────────────────────────────────────────
# One repo per custom Docker image.
# Mosquitto uses the public Docker Hub image (eclipse-mosquitto:2.0.18) — no ECR needed.

locals {
  ecr_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── fog-processor ─────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "fog_processor" {
  name                 = "${var.prefix}/fog-processor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }

  tags = { Name = "${var.prefix}-fog-processor" }
}

resource "aws_ecr_lifecycle_policy" "fog_processor" {
  repository = aws_ecr_repository.fog_processor.name
  policy     = local.ecr_lifecycle_policy
}

# ── edge-processor ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "edge_processor" {
  name                 = "${var.prefix}/edge-processor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }

  tags = { Name = "${var.prefix}-edge-processor" }
}

resource "aws_ecr_lifecycle_policy" "edge_processor" {
  repository = aws_ecr_repository.edge_processor.name
  policy     = local.ecr_lifecycle_policy
}

# ── simulator ─────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "simulator" {
  name                 = "${var.prefix}/simulator"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }

  tags = { Name = "${var.prefix}-simulator" }
}

resource "aws_ecr_lifecycle_policy" "simulator" {
  repository = aws_ecr_repository.simulator.name
  policy     = local.ecr_lifecycle_policy
}

# ── dashboard ─────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "dashboard" {
  name                 = "${var.prefix}/dashboard"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }

  tags = { Name = "${var.prefix}-dashboard" }
}

resource "aws_ecr_lifecycle_policy" "dashboard" {
  repository = aws_ecr_repository.dashboard.name
  policy     = local.ecr_lifecycle_policy
}
