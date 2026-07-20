# =============================================================================
# ALB MODULE - main.tf
# =============================================================================
# ALB = Application Load Balancer.
#
# ANALOGY: an ALB is the receptionist at the front desk of an office building.
# Visitors talk to the receptionist, never directly to the employees. The
# receptionist checks who you are, decides which desk to send you to, and
# quietly notices if an employee stops answering their phone.
#
# The ALB does four jobs for us:
#   1. It is the ONLY public-facing thing, so it absorbs all internet exposure
#   2. It terminates TLS (handles the HTTPS certificate) so Keycloak doesn't
#   3. It health-checks Keycloak and stops sending traffic to a dead instance
#   4. It gives us one stable DNS name even when instances get replaced
#
# THE PIECES, IN ORDER:
#   Certificate -> Load Balancer -> Target Group -> Listener -> Listener Rule
# =============================================================================


# -----------------------------------------------------------------------------
# LOOK UP THE DNS ZONE (only if using a real domain)
# -----------------------------------------------------------------------------
# A Route 53 "hosted zone" is the DNS control panel for a domain you own.
# We need its ID to create DNS records and to prove we own the domain.
data "aws_route53_zone" "main" {
  # Only look this up when the user actually gave us a domain.
  count = var.create_dns_records && var.domain_name != "" ? 1 : 0

  name = var.hosted_zone_name

  # private_zone = false means "the public internet-facing zone," not an
  # internal-only VPC zone.
  private_zone = false
}


# =============================================================================
# PART 1: THE TLS CERTIFICATE
# =============================================================================
# A certificate is what makes the padlock icon appear in a browser. It does
# two things: encrypts the connection, and proves the server really is who it
# claims to be.
#
# We support TWO modes, because not everyone has a domain name:
#
#   MODE A - ACM certificate (needs a real domain you control)
#     PRO: free, auto-renews forever, browsers trust it, zero warnings
#     CON: requires owning a domain and having it in Route 53
#
#   MODE B - self-signed certificate (works with no domain at all)
#     PRO: works immediately, costs nothing, good for testing
#     CON: browsers show a scary "Not Secure" warning you must click past.
#          The encryption is real; what's missing is third-party proof of
#          identity. Never use this for anything real.
# =============================================================================


# --- MODE A: ACM CERTIFICATE ---
resource "aws_acm_certificate" "main" {
  count = var.use_acm_certificate ? 1 : 0

  # The primary domain this certificate is valid for.
  domain_name = var.domain_name

  # DNS validation proves you own the domain by having you add a special DNS
  # record. The alternative, EMAIL validation, sends a link to the domain's
  # registered contact address and requires a human to click it — which means
  # it cannot auto-renew. Always choose DNS.
  validation_method = "DNS"

  # Extra names the same certificate should cover. A wildcard like
  # "*.example.com" covers any single-level subdomain.
  subject_alternative_names = var.subject_alternative_names

  lifecycle {
    # Certificates cannot be modified in place — a change means a new cert.
    # This flag issues the new one and validates it BEFORE removing the old,
    # so the listener is never left pointing at a deleted certificate.
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-cert"
  })
}

# --- The DNS records that prove domain ownership ---
# ACM generates a unique random record and waits for it to appear in DNS.
# Since Terraform manages our DNS too, we can create it automatically and the
# whole validation happens hands-free.
resource "aws_route53_record" "cert_validation" {
  # This for_each is dense, so here it is unpacked:
  #
  #   aws_acm_certificate.main[0].domain_validation_options is a SET of
  #   objects, one per domain name on the certificate. Each object holds
  #   the record name, type, and value ACM wants us to publish.
  #
  #   The { for ... } syntax builds a MAP from that set, keyed by domain
  #   name. We need a map because for_each requires stable string keys.
  for_each = var.use_acm_certificate && var.create_dns_records ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  # allow_overwrite handles the case where a stale validation record from a
  # previous attempt is still sitting in the zone.
  allow_overwrite = true

  name    = each.value.name
  records = [each.value.record] # records expects a LIST, even for one value
  ttl     = 60                  # seconds browsers/resolvers may cache this
  type    = each.value.type
  zone_id = data.aws_route53_zone.main[0].zone_id
}

# --- Wait for validation to finish ---
# This resource creates NOTHING in AWS. It is a synchronization barrier:
# it blocks Terraform until ACM confirms the certificate is issued.
#
# Without it, Terraform would race ahead and try to attach a still-pending
# certificate to the listener, which fails.
resource "aws_acm_certificate_validation" "main" {
  count = var.use_acm_certificate && var.create_dns_records ? 1 : 0

  certificate_arn = aws_acm_certificate.main[0].arn

  # The list of validation records to wait on.
  # [for record in ... : record.fqdn] pulls the full DNS name out of each.
  validation_record_fqdns = [
    for record in aws_route53_record.cert_validation : record.fqdn
  ]

  timeouts {
    # DNS validation is usually fast but can occasionally crawl. If it hasn't
    # finished in 10 minutes, something is wrong (usually the domain's name
    # servers don't actually point at this Route 53 zone).
    create = "10m"
  }
}


# --- MODE B: SELF-SIGNED CERTIFICATE ---
# Uses the "tls" provider, which does cryptography locally on your machine.
# Nothing is sent to AWS until we upload the finished certificate.

# Step 1: generate a private key. This is the secret half of the pair.
resource "tls_private_key" "self_signed" {
  count = var.use_acm_certificate ? 0 : 1

  # RSA is the widely compatible choice. ECDSA keys are smaller and faster
  # but occasionally trip up older clients.
  algorithm = "RSA"

  # 2048 bits is the current minimum considered safe. 4096 is stronger and
  # noticeably slower on every handshake. 2048 is the sensible default.
  rsa_bits = 2048
}

# Step 2: create the certificate and sign it with our own key.
# "Self-signed" literally means the signature comes from the same key it is
# vouching for — like writing your own reference letter. That is exactly why
# browsers don't trust it.
resource "tls_self_signed_cert" "self_signed" {
  count = var.use_acm_certificate ? 0 : 1

  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    # The name the certificate claims to represent.
    common_name  = var.domain_name != "" ? var.domain_name : "keycloak.local"
    organization = var.name_prefix
  }

  # How long the certificate stays valid. 8760 hours = 365 days.
  validity_period_hours = var.self_signed_validity_hours

  # What this certificate is permitted to be used for. A TLS server cert
  # needs these three specific usages.
  allowed_uses = [
    "key_encipherment",  # may be used to encrypt session keys
    "digital_signature", # may be used to sign the handshake
    "server_auth",       # may identify a server (as opposed to a client)
  ]

  # Modern browsers ignore common_name entirely and look only at the
  # Subject Alternative Name list. A cert without SANs fails outright.
  dns_names = compact(concat(
    [var.domain_name != "" ? var.domain_name : "keycloak.local"],
    var.subject_alternative_names
  ))
}

# Step 3: upload it to ACM so the load balancer can use it.
# ACM stores imported certificates alongside ones it issued itself.
resource "aws_acm_certificate" "self_signed" {
  count = var.use_acm_certificate ? 0 : 1

  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-self-signed-cert"
    Warning = "Self-signed - browsers will warn. Do not use in production."
  })
}


# --- Pick whichever certificate we actually built ---
locals {
  # try() attempts each expression in order and returns the first that works.
  # Exactly one of these branches exists at a time, so this cleanly resolves
  # to whichever mode is active.
  certificate_arn = try(
    aws_acm_certificate_validation.main[0].certificate_arn, # validated ACM
    aws_acm_certificate.main[0].arn,                        # ACM, no DNS mgmt
    aws_acm_certificate.self_signed[0].arn,                 # self-signed
    null
  )
}


# =============================================================================
# PART 2: THE LOAD BALANCER ITSELF
# =============================================================================
resource "aws_lb" "main" {
  name = "${var.name_prefix}-alb"

  # internal = false means internet-facing (it gets public IPs).
  # Setting true would make it reachable only from inside the VPC.
  internal = false

  # "application" operates at layer 7 (HTTP), so it can read URLs, headers,
  # and cookies, and route based on them. That is what lets us do
  # path-based rules and HTTP-to-HTTPS redirects.
  #
  # The alternative, "network" (NLB), works at layer 4 (TCP). It is faster
  # and cheaper but blind to HTTP, so no redirects and no path routing.
  load_balancer_type = "application"

  # The firewall wrapping the ALB — this is what limits access to your IP.
  security_groups = [var.alb_security_group_id]

  # PUBLIC subnets, in at least two availability zones. AWS enforces the
  # two-AZ minimum; a single subnet will be rejected.
  subnets = var.public_subnet_ids

  # Safety switch. When true, a `terraform destroy` will REFUSE to delete
  # this load balancer. Turn it on for production, leave it off for dev
  # or you will not be able to tear your test environment down.
  enable_deletion_protection = var.enable_deletion_protection

  # Drop malformed or ambiguous HTTP requests instead of forwarding them.
  # This blocks "request smuggling," an attack where a carefully broken
  # request is interpreted one way by the ALB and a different way by the
  # backend, letting an attacker sneak a second hidden request through.
  drop_invalid_header_fields = true

  # How long an idle connection stays open. Keycloak login flows involve
  # several redirects; 60 seconds is comfortable.
  idle_timeout = var.idle_timeout

  # HTTP/2 is faster than HTTP/1.1 for browsers. No downside; leave it on.
  enable_http2 = true

  # --- Access logs ---
  # Records every single request to S3: who, when, what URL, what status.
  # Invaluable for debugging and required by most compliance frameworks.
  #
  # dynamic blocks generate a block only when a condition holds. Here, the
  # access_logs block appears only if an S3 bucket was supplied.
  dynamic "access_logs" {
    # A list with one item creates one block; an empty list creates none.
    for_each = var.access_logs_bucket != "" ? [1] : []

    content {
      bucket  = var.access_logs_bucket
      prefix  = var.name_prefix
      enabled = true
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb"
  })
}


# =============================================================================
# PART 3: THE TARGET GROUP
# =============================================================================
# A target group is the list of backend servers the ALB may send traffic to,
# plus the health check that decides which ones are currently fit to receive
# it.
#
# ANALOGY: a substitute teacher list. The ALB checks who actually showed up
# today before assigning anyone a class.
resource "aws_lb_target_group" "keycloak" {
  name = "${var.name_prefix}-tg"

  # The port on the INSTANCE, not on the load balancer. The ALB listens on
  # 443 and forwards to 8080 here.
  port = var.keycloak_http_port

  # Traffic between the ALB and the instance is plain HTTP. That is fine and
  # normal: it never leaves your private VPC, and TLS was already handled at
  # the ALB. This pattern is called "TLS termination at the edge."
  protocol = "HTTP"

  vpc_id = var.vpc_id

  # "instance" targets by EC2 instance ID. Alternatives are "ip" (raw IPs,
  # used for containers or on-prem servers) and "lambda".
  target_type = "instance"

  # How long to keep a connection open to a target that is being removed,
  # so in-flight requests can finish instead of being cut off. This is
  # called "connection draining."
  deregistration_delay = var.deregistration_delay

  # --- Health check configuration ---
  # This block is the most common source of "why is my ALB returning 503?"
  # A 503 almost always means every target is failing its health check.
  health_check {
    enabled = true

    # The URL the ALB requests. Keycloak 25+ serves readiness here on the
    # management port. "Ready" means started AND able to serve traffic;
    # "live" only means the process hasn't crashed.
    path = var.health_check_path

    # Health checks go to the management port (9000), which is separate
    # from the app port. "traffic-port" would reuse the app port instead.
    port = tostring(var.keycloak_management_port)

    protocol = "HTTP"

    # Seconds between checks.
    interval = var.health_check_interval

    # How long to wait for a reply before calling it a failure. Must be
    # less than interval.
    timeout = var.health_check_timeout

    # Consecutive passes needed to mark an unhealthy target healthy again.
    healthy_threshold = var.healthy_threshold

    # Consecutive failures before pulling a target out of rotation.
    # Keycloak takes 30-60 seconds to boot, so don't set this too low or
    # instances get yanked before they finish starting.
    unhealthy_threshold = var.unhealthy_threshold

    # Which HTTP status codes count as healthy. "200" is strict and correct
    # for a health endpoint. You can give a range like "200-299".
    matcher = var.health_check_matcher
  }

  # --- Session stickiness ---
  # Keycloak keeps login state in memory on whichever node served the login.
  # If a follow-up request lands on a different node, the user is logged out
  # unexpectedly. Stickiness pins a browser to one node using a cookie.
  #
  # With a single instance this changes nothing, but it is essential the
  # moment you scale to two, so we set it up correctly from the start.
  stickiness {
    type            = "lb_cookie" # the ALB generates and manages the cookie
    cookie_duration = var.stickiness_duration
    enabled         = var.enable_stickiness
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tg"
  })
}


# =============================================================================
# PART 4: LISTENERS
# =============================================================================
# A listener watches a port on the ALB and says what to do with what arrives.

# --- HTTPS listener on port 443: the real one ---
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"

  # A "security policy" is the list of TLS versions and cipher suites the
  # ALB will accept. This one requires TLS 1.3 or 1.2 and refuses the older,
  # broken versions (TLS 1.0 and 1.1, both formally deprecated).
  #
  # Stricter policies lock out older clients. This one is the current
  # balanced recommendation.
  ssl_policy = var.ssl_policy

  certificate_arn = local.certificate_arn

  # What to do with a matching request. "forward" hands it to a target group.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-https-listener"
  })
}


# --- HTTP listener on port 80: redirect only ---
# Its entire job is to reply "go to the https:// address instead."
# No traffic is ever served here.
resource "aws_lb_listener" "http_redirect" {
  count = var.enable_http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port     = "443"
      protocol = "HTTPS"

      # 301 = "moved permanently," so browsers remember and skip the detour
      # next time. 302 would be temporary and re-checked every visit.
      status_code = "HTTP_301"

      # "#{host}" and "#{path}" are ALB placeholder variables. They copy the
      # original hostname and path into the redirect, so a request for
      # http://site.com/admin/x correctly becomes https://site.com/admin/x
      # instead of dumping everyone on the homepage.
      host = "#{host}"
      path = "/#{path}"
      query = "#{query}"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-http-redirect-listener"
  })
}


# =============================================================================
# PART 5: LISTENER RULES (extra defense on the admin console)
# =============================================================================
# Listener rules run BEFORE the default action and can override it.
# Rules are evaluated in priority order, lowest number first.
#
# The security group already restricts access to your IP. This rule is a
# second, independent check at the HTTP layer. If someone ever loosens the
# security group by accident, this still blocks admin access.
#
# Two locks are better than one, especially when a single careless edit can
# open the first.
resource "aws_lb_listener_rule" "restrict_admin_console" {
  count = var.restrict_admin_paths ? 1 : 0

  listener_arn = aws_lb_listener.https.arn

  # Lower priority number = evaluated earlier. Leaving gaps (100, 200, 300)
  # makes it easy to insert rules later without renumbering everything.
  priority = 100

  # If the conditions match, return a flat 403 instead of forwarding.
  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden - administrative paths are restricted by source IP."
      status_code  = "403"
    }
  }

  # Condition 1: the request path looks like an admin path.
  condition {
    path_pattern {
      values = var.admin_path_patterns
    }
  }

  # Condition 2: the source IP is NOT one of ours.
  #
  # Multiple condition blocks are combined with AND, so this rule fires only
  # when the path is administrative AND the IP is unapproved.
  #
  # IMPORTANT SUBTLETY: source_ip matches the real client IP as seen by the
  # ALB. It deliberately ignores the X-Forwarded-For header, which a client
  # can forge. That is what makes this trustworthy.
  condition {
    not_source_ip {
      values = var.allowed_admin_cidrs
    }
  }
}


# =============================================================================
# PART 6: DNS RECORD
# =============================================================================
# Points your friendly domain name at the load balancer.
resource "aws_route53_record" "keycloak" {
  count = var.create_dns_records && var.domain_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name

  # "A" maps a name to an IPv4 address. Combined with the alias block below,
  # it becomes an AWS-specific "alias record."
  type = "A"

  # An ALIAS record is better than a CNAME for an ALB:
  #   - it works at the domain root (example.com), where CNAMEs are illegal
  #   - Route 53 queries for it are free
  #   - it tracks the ALB's changing IPs automatically
  alias {
    name    = aws_lb.main.dns_name
    zone_id = aws_lb.main.zone_id

    # Health-check the ALB before answering. Only useful with failover
    # routing to a backup site; harmless otherwise.
    evaluate_target_health = true
  }
}
