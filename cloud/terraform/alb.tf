# ── Application Load Balancer — public HTTPS/HTTP for Dashboard ───────────────
#
# Why ALB over a public task IP?
#   - Fargate task IPs change on every restart; ALB gives a stable DNS name
#   - ALB health-checks prevent traffic to starting/failing tasks
#   - Zero-downtime deploys (old task stays in service until new one is healthy)

# ── ALB Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-sg"
  description = "Cold-Chain Dashboard ALB — public inbound HTTP"
  vpc_id      = local.vpc_id

  # Allow HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound (to ECS task on port 5001)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-alb-sg" }
}

# ── Load Balancer ─────────────────────────────────────────────────────────────

resource "aws_lb" "dashboard" {
  name               = "${var.prefix}-dash-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids

  enable_deletion_protection = false

  tags = { Name = "${var.prefix}-dashboard-alb" }
}

# ── Target Group — points at dashboard ECS tasks on port 5001 ────────────────

resource "aws_lb_target_group" "dashboard" {
  name        = "${var.prefix}-dash-tg"
  port        = 5001
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"   # Required for Fargate (awsvpc networking)

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/api/health"
    matcher             = "200"
  }

  # WebSocket connections need longer idle timeouts
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Name = "${var.prefix}-dashboard-tg" }
}

# ── Listener — HTTP:80 → Dashboard ───────────────────────────────────────────

resource "aws_lb_listener" "dashboard_http" {
  load_balancer_arn = aws_lb.dashboard.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dashboard.arn
  }
}
