# =============================================================================
# alb.tf - load balancer, TLS certificate, target group
# =============================================================================
# The ALB is a receptionist: visitors talk to it, never directly to Keycloak.
#
# It does three jobs:
#   1. Absorbs all internet exposure, so the instance needs no public IP
#   2. Handles HTTPS, so Keycloak does not have to
#   3. Health-checks the instance and stops sending traffic to a dead one
#
# COST: ~$22/month (ALB hourly + a small amount of capacity units).
# =============================================================================


# -----------------------------------------------------------------------------
# THE TLS CERTIFICATE
# -----------------------------------------------------------------------------
# A certificate makes the padlock appear in the browser. It does two things:
# encrypts the connection, and proves the server is who it claims to be.
#
# We generate a SELF-SIGNED certificate here. The encryption is real; what is
# missing is third-party proof of identity, which is why browsers show a
# warning you must click past.
#
# This uses the "tls" provider, which does the cryptography locally on your
# machine. Nothing is sent to AWS until we upload the finished certificate.
#
# WANT A REAL CERTIFICATE WITH NO WARNING? You need a domain name. See the
# README section "Using a real domain."

# Step 1: the private key - the secret half of the pair.
resource "tls_private_key" "cert" {
  algorithm = "RSA"
  rsa_bits  = 2048 # current minimum considered safe
}

# Step 2: the certificate, signed by our own key.
# "Self-signed" literally means the signature comes from the same key it is
# vouching for - like writing your own reference letter. That is exactly why
# browsers do not trust it.
resource "tls_self_signed_cert" "cert" {
  private_key_pem = tls_private_key.cert.private_key_pem

  subject {
    common_name  = "keycloak.local"
    organization = var.name
  }

  validity_period_hours = 8760 # 1 year

  # What the certificate is permitted to be used for.
  allowed_uses = [
    "key_encipherment",  # encrypt session keys
    "digital_signature", # sign the handshake
    "server_auth",       # identify a server
  ]

  # Modern browsers ignore common_name entirely and read only this list.
  # A certificate without SANs fails outright.
  dns_names = ["keycloak.local", "localhost"]
}

# Step 3: upload it to ACM so the load balancer can use it.
# ACM storage is free.
resource "aws_acm_certificate" "cert" {
  private_key      = tls_private_key.cert.private_key_pem
  certificate_body = tls_self_signed_cert.cert.cert_pem

  lifecycle { create_before_destroy = true }

  tags = { Name = "${var.name}-cert" }
}


# -----------------------------------------------------------------------------
# THE LOAD BALANCER
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  internal           = false # internet-facing (but the SG locks it to your IP)
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb.id]

  # PUBLIC subnets, both of them. AWS enforces a two-AZ minimum for an ALB.
  subnets = aws_subnet.public[*].id

  # Drop malformed HTTP requests instead of forwarding them. This blocks
  # "request smuggling," where a deliberately broken request is read one way
  # by the ALB and differently by the backend.
  drop_invalid_header_fields = true

  # Keycloak login involves several redirects; 60s is comfortable.
  idle_timeout = 60

  tags = { Name = "${var.name}-alb" }
}


# -----------------------------------------------------------------------------
# THE TARGET GROUP
# -----------------------------------------------------------------------------
# The list of backends the ALB may send traffic to, plus the health check
# that decides whether they are fit to receive it.
resource "aws_lb_target_group" "keycloak" {
  name        = "${var.name}-tg"
  port        = 8080 # the port ON THE INSTANCE
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # Traffic between the ALB and the instance is plain HTTP. That is correct
  # and normal: it never leaves the private VPC, and TLS was already handled
  # at the ALB. The pattern is called "TLS termination at the edge."

  health_check {
    enabled = true

    # Keycloak 25+ serves readiness here, on a separate management port.
    # "ready" means started AND able to serve traffic.
    path     = "/health/ready"
    port     = "9000"
    protocol = "HTTP"

    interval            = 15 # seconds between checks
    timeout             = 5  # must be less than interval
    healthy_threshold   = 2  # 2 passes -> healthy (so ~30s to detect)
    unhealthy_threshold = 5  # 5 failures -> pull from rotation
    matcher             = "200"
  }

  lifecycle { create_before_destroy = true }
  tags = { Name = "${var.name}-tg" }
}

# Register the instance. Without an Auto Scaling Group, we attach it directly.
resource "aws_lb_target_group_attachment" "keycloak" {
  target_group_arn = aws_lb_target_group.keycloak.arn
  target_id        = aws_instance.keycloak.id
  port             = 8080
}


# -----------------------------------------------------------------------------
# LISTENERS
# -----------------------------------------------------------------------------
# A listener watches a port and says what to do with what arrives.

# Port 443: the real one.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"

  # Which TLS versions and ciphers to accept. This policy requires TLS 1.2
  # or 1.3 and refuses the older, broken versions.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

# Port 80: redirect only. Its entire job is to say "use https instead."
# No application traffic is ever served here.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port     = "443"
      protocol = "HTTPS"

      # 301 = permanent, so browsers remember and skip the detour next time.
      status_code = "HTTP_301"

      # These are ALB placeholder variables. They copy the original path and
      # query into the redirect, so /admin/x does not become /.
      host  = "#{host}"
      path  = "/#{path}"
      query = "#{query}"
    }
  }
}

# =============================================================================
# WHY NO LISTENER RULES?
# =============================================================================
# An earlier version added listener rules to block /admin by source IP, as a
# second layer on top of the security group.
#
# They are gone because they were redundant: the security group ALREADY drops
# every packet that is not from your IP, before it reaches the listener. The
# rules only ever fired for traffic that could not arrive in the first place.
#
# One lock that works beats two locks where the second is decorative.
# =============================================================================
