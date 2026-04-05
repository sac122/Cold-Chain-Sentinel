# ── SNS Alert Topic ───────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name         = "${var.prefix}-alerts"
  display_name = "Cold-Chain Sentinel Alerts"

  tags = {
    Name    = "${var.prefix}-alerts"
    Purpose = "Alert notifications for cold-chain incidents"
  }
}

# Email subscription — requires manual confirmation from the inbox
resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
