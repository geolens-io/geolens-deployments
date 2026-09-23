resource "aws_lb" "this" {
  name_prefix        = substr(var.name, 0, 6)
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  # A large export or a slow multipart handshake outlives the 60 s default.
  idle_timeout = 300
}

# Everything goes through the frontend container. It is the application edge:
# it proxies /api and /raster-tiles to the api, blocks /api/metrics, and rate
# limits anonymous raster traffic. Routing anything straight to the api would
# skip all of that.
resource "aws_lb_target_group" "app" {
  name_prefix = substr(var.name, 0, 6)
  vpc_id      = aws_vpc.this.id
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"

  deregistration_delay = 15

  # Through the edge to the api (codex review on #40), process-only (#52): ECS
  # stops a task that fails this check, and the deep /health 503s on any S3 or
  # cache outage, so the recipe replaced healthy tasks it could not fix.
  health_check {
    path    = "/api/health/live"
    matcher = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.acm_certificate_arn == "" ? [1] : []

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }

  dynamic "default_action" {
    for_each = var.acm_certificate_arn == "" ? [] : [1]

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.acm_certificate_arn == "" ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
