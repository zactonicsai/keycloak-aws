#!/bin/bash
# =============================================================================
# setup.sh - runs once, as root, when the instance first boots
# =============================================================================
# This is a Terraform TEMPLATE. Before it reaches the server, Terraform
# replaces every $${...} placeholder with a real value.
#
# SYNTAX NOTE: a single $ before { is a Terraform placeholder. To write a
# normal BASH variable you must double the dollar sign: $${VAR}. Get this
# wrong and Terraform tries to interpret your shell variables.
#
# WHERE THE LOGS ARE WHEN THIS GOES WRONG:
#   sudo cat /var/log/setup.log        <- this script, with timing markers
#   sudo journalctl -u keycloak -f     <- Keycloak itself
# =============================================================================

set -euo pipefail

# Send all output to a log file AND the console.
exec > >(tee /var/log/setup.log) 2>&1

# Track elapsed seconds so a slow boot shows WHICH step was slow.
START=$(date +%s)
step() { echo ""; echo "[+$(( $(date +%s) - START ))s] === $* ==="; }

echo "Keycloak setup starting at $(date)"


# -----------------------------------------------------------------------------
step "1. Installing Java"
# -----------------------------------------------------------------------------
# NOTE: we deliberately do NOT run `dnf update -y`. A full OS update takes
# 2-5 minutes and buys almost nothing, because the AMI is already the newest
# Amazon Linux 2023 image. Those minutes used to be the largest chunk of boot
# time. If you need guaranteed-latest patches, use SSM Patch Manager on a
# schedule instead of on the boot critical path.
#
# max_parallel_downloads fetches packages concurrently rather than one at a
# time, which typically halves this step.
dnf install -y \
  --setopt=max_parallel_downloads=10 \
  --setopt=retries=3 \
  java-21-amazon-corretto-headless \
  tar gzip

java -version


# -----------------------------------------------------------------------------
step "2. Creating the keycloak user"
# -----------------------------------------------------------------------------
# NEVER run an internet-facing application as root. If someone finds a bug in
# Keycloak, they inherit whatever powers the process had. An unprivileged
# account with no login shell contains the damage.
useradd -r -s /sbin/nologin -d /opt/keycloak -M keycloak || true


# -----------------------------------------------------------------------------
step "3. Downloading Keycloak ${keycloak_version}"
# -----------------------------------------------------------------------------
mkdir -p /opt/keycloak
cd /tmp

# curl flags: -f fail loudly on HTTP errors instead of saving the error page,
# -sS silent but still show errors, -L follow redirects (GitHub redirects to
# a CDN), --retry survive transient network failures.
curl -fsSL --retry 3 --retry-delay 5 \
  -o kc.tar.gz \
  "https://github.com/keycloak/keycloak/releases/download/${keycloak_version}/keycloak-${keycloak_version}.tar.gz"

# --strip-components=1 drops the top-level folder inside the archive, so
# files land directly in /opt/keycloak.
tar -xzf kc.tar.gz -C /opt/keycloak --strip-components=1
rm -f kc.tar.gz


# -----------------------------------------------------------------------------
step "4. Writing the realm import file"
# -----------------------------------------------------------------------------
# Terraform already decided WHICH realm to use - your file or the built-in
# default - using fileexists() at plan time. Either way the content arrives
# here as realm_json.
mkdir -p /opt/keycloak/data/import

# A QUOTED heredoc delimiter ('REALM_EOF') stops bash from expanding anything
# inside the JSON. Without the quotes, any $ in the realm would be mangled.
cat > /opt/keycloak/data/import/${realm_name}-realm.json << 'REALM_EOF'
${realm_json}
REALM_EOF

echo "Realm file written:"
head -c 200 /opt/keycloak/data/import/${realm_name}-realm.json
echo ""


# -----------------------------------------------------------------------------
step "5. Configuring Keycloak"
# -----------------------------------------------------------------------------
cat > /opt/keycloak/conf/keycloak.conf << 'CONF_EOF'
# --- Database ---
# dev-file is an embedded H2 database on the local disk.
#
# THE DATA DIES WITH THIS INSTANCE. Replace or terminate the instance and
# every user, realm, and session is gone. That is an accepted tradeoff for a
# test deployment. For anything durable you need PostgreSQL on RDS.
db=dev-file

# --- HTTP ---
# We serve plain HTTP. That is correct: the ALB already handled TLS, and this
# traffic never leaves the private subnet.
http-enabled=true
http-port=8080

# Bind to all interfaces so the ALB can reach us. 127.0.0.1 would only accept
# connections from the instance itself.
http-host=0.0.0.0

# --- Proxy ---
# CRITICAL SETTING. Keycloak sits behind a load balancer, so the connection it
# sees comes from the ALB, not the user. Without this, Keycloak builds redirect
# URLs from its own private IP over http:// and login breaks with a redirect
# loop or an "invalid redirect" error.
#
# This is the single most common Keycloak-behind-a-load-balancer failure.
proxy-headers=xforwarded

# Do not enforce a specific hostname. Keeps this working whether you reach it
# by the ALB's DNS name or a custom domain.
hostname-strict=false

# --- Health checks ---
# Enables /health/ready, which the ALB polls. In Keycloak 25+ these live on a
# separate management port so they are not exposed alongside the app.
health-enabled=true
http-management-port=9000
CONF_EOF

chown -R keycloak:keycloak /opt/keycloak


# -----------------------------------------------------------------------------
step "6. Building Keycloak"
# -----------------------------------------------------------------------------
# `kc.sh build` pre-compiles the configuration into an optimized image. It
# takes a minute or two but makes every subsequent start much faster.
sudo -u keycloak /opt/keycloak/bin/kc.sh build


# -----------------------------------------------------------------------------
step "7. Installing the service"
# -----------------------------------------------------------------------------
# systemd is Linux's service manager. Registering Keycloak with it means the
# process starts on boot and restarts automatically if it crashes.
cat > /etc/systemd/system/keycloak.service << 'SERVICE_EOF'
[Unit]
Description=Keycloak
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=keycloak
Group=keycloak

# The admin credentials come from a separate root-only file, written just
# below. They are used only on the very first start, when no admin exists.
EnvironmentFile=/etc/keycloak.env

# -Xms and -Xmx set the starting and maximum Java heap. Setting them EQUAL
# avoids pauses while the JVM resizes the heap under load.
Environment=JAVA_OPTS=-Xms1g -Xmx1g

# --optimized skips re-checking the build, since we built in step 6.
# --import-realm imports every JSON file in data/import at startup.
#
# IMPORTANT: import only runs for realms that do NOT already exist. On a
# restart, an existing realm is left untouched, so your users are safe.
ExecStart=/opt/keycloak/bin/kc.sh start --optimized --import-realm

Restart=on-failure
RestartSec=10
TimeoutStartSec=300

# Java opens many files; the default limit is too low.
LimitNOFILE=102642

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Write the credentials into a separate file that systemd reads.
#
# WHY NOT sed? Because sed treats & in the replacement text as "insert the
# whole matched string," so a password containing & would be silently
# corrupted. Other characters (\, |, newlines) cause similar trouble.
#
# A QUOTED heredoc ('CREDS_EOF') performs no expansion whatsoever, so the
# password lands byte-for-byte no matter what characters it contains.
cat > /etc/keycloak.env << 'CREDS_EOF'
KC_BOOTSTRAP_ADMIN_USERNAME=${admin_username}
KC_BOOTSTRAP_ADMIN_PASSWORD=${admin_password}
CREDS_EOF

# This file holds the admin password, so lock it to root only.
chmod 600 /etc/keycloak.env

systemctl daemon-reload
systemctl enable --now keycloak


# -----------------------------------------------------------------------------
step "8. Waiting for Keycloak to be ready"
# -----------------------------------------------------------------------------
# Poll the health endpoint until it answers. Without this the script exits
# while Keycloak is still starting, and the ALB briefly serves 503s with no
# explanation.
for i in $(seq 1 60); do
  # -o /dev/null discards the body; -w prints just the status code.
  # NOTE the DOUBLED %% - a single % is a Terraform template placeholder.
  CODE=$(curl -s -o /dev/null -w '%%{http_code}' http://localhost:9000/health/ready 2>/dev/null || echo 000)

  if [[ "$${CODE}" == "200" ]]; then
    echo "Keycloak is READY after $(( $(date +%s) - START ))s"
    break
  fi

  echo "  attempt $${i}/60 - status $${CODE}, waiting 10s..."
  sleep 10
done

echo ""
echo "=== Setup finished in $(( $(date +%s) - START ))s ==="
echo "Useful commands:"
echo "  systemctl status keycloak"
echo "  journalctl -u keycloak -f"
echo "  cat /var/log/setup.log"
