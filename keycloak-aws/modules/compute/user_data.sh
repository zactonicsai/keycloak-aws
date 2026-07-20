#!/bin/bash
# =============================================================================
# user_data.sh - runs ONCE as root when the instance first boots
# =============================================================================
# This is a Terraform TEMPLATE file. Before it reaches the server, Terraform
# replaces every $${...} placeholder with a real value.
#
# IMPORTANT SYNTAX NOTE: in a Terraform template, a single $ followed by {
# is a Terraform placeholder. To write a normal BASH variable, you must
# double the dollar sign: $${BASH_VAR}. Get this wrong and Terraform will
# try to interpret your shell variables and fail with a confusing error.
#
# WHERE TO FIND THE LOGS WHEN THIS GOES WRONG:
#   sudo cat /var/log/user-data.log       <- our own detailed log
#   sudo cat /var/log/cloud-init-output.log
#   sudo journalctl -u keycloak -f        <- Keycloak's own logs
# =============================================================================

set -euo pipefail

# Send everything printed by this script to a log file AND the console.
# exec redirects the rest of the script's output. tee writes to both places.
exec > >(tee /var/log/user-data.log) 2>&1

echo "==================================================================="
echo "Keycloak bootstrap starting at $(date)"
echo "==================================================================="

# -----------------------------------------------------------------------------
# CONFIGURATION (filled in by Terraform)
# -----------------------------------------------------------------------------
KEYCLOAK_VERSION="${keycloak_version}"
ADMIN_USERNAME="${admin_username}"
SECRET_ARN="${secret_arn}"
AWS_REGION="${aws_region}"
REALM_NAME="${realm_name}"
HTTP_PORT="${http_port}"
MANAGEMENT_PORT="${management_port}"
HOSTNAME_URL="${hostname_url}"
JAVA_HEAP="${java_heap}"
DB_VENDOR="${db_vendor}"

# Where things live on disk.
KEYCLOAK_HOME="/opt/keycloak"
KEYCLOAK_USER="keycloak"
REALM_IMPORT_DIR="$${KEYCLOAK_HOME}/data/import"


# -----------------------------------------------------------------------------
# STEP 1: UPDATE THE OS AND INSTALL DEPENDENCIES
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 1: Installing packages ---"

# dnf is the package manager on Amazon Linux 2023 (the successor to yum).
# -y answers "yes" to every prompt, since nobody is here to type.
dnf update -y

# What each package is for:
#   java-21-amazon-corretto-headless - the Java runtime Keycloak needs.
#     Corretto is Amazon's free, long-term-supported build of OpenJDK.
#     "headless" omits GUI libraries we will never use on a server.
#   jq       - a command line JSON parser, used to read the secret
#   tar/gzip - to unpack the Keycloak download
#   awscli   - to talk to Secrets Manager
dnf install -y \
  java-21-amazon-corretto-headless \
  jq \
  tar \
  gzip \
  awscli

echo "Java version installed:"
java -version


# -----------------------------------------------------------------------------
# STEP 2: CREATE A DEDICATED SERVICE USER
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 2: Creating the keycloak service user ---"

# NEVER run an internet-facing application as root. If someone finds a bug in
# Keycloak, they get whatever powers the process had. Running as an
# unprivileged user with no login shell contains the damage.
#
#   -r  = system account (low UID, no aging rules)
#   -s /sbin/nologin = nobody can log in as this user
#   -d  = home directory
if ! id "$${KEYCLOAK_USER}" &>/dev/null; then
  useradd -r -s /sbin/nologin -d "$${KEYCLOAK_HOME}" -M "$${KEYCLOAK_USER}"
  echo "Created user $${KEYCLOAK_USER}"
else
  echo "User $${KEYCLOAK_USER} already exists, skipping"
fi


# -----------------------------------------------------------------------------
# STEP 3: DOWNLOAD AND UNPACK KEYCLOAK
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 3: Downloading Keycloak $${KEYCLOAK_VERSION} ---"

mkdir -p "$${KEYCLOAK_HOME}"
cd /tmp

DOWNLOAD_URL="https://github.com/keycloak/keycloak/releases/download/$${KEYCLOAK_VERSION}/keycloak-$${KEYCLOAK_VERSION}.tar.gz"
echo "Fetching: $${DOWNLOAD_URL}"

# curl flags:
#   -f  fail loudly on an HTTP error instead of saving the error page
#   -sS silent, but still show errors
#   -L  follow redirects (GitHub redirects downloads to a CDN)
#   --retry 3 retry transient network failures
curl -fsSL --retry 3 --retry-delay 5 \
  -o keycloak.tar.gz \
  "$${DOWNLOAD_URL}"

# --strip-components=1 removes the top-level folder inside the archive, so
# files land directly in /opt/keycloak instead of /opt/keycloak/keycloak-26.x
tar -xzf keycloak.tar.gz -C "$${KEYCLOAK_HOME}" --strip-components=1
rm -f keycloak.tar.gz

# Hand ownership to the service user.
chown -R "$${KEYCLOAK_USER}:$${KEYCLOAK_USER}" "$${KEYCLOAK_HOME}"

echo "Keycloak unpacked to $${KEYCLOAK_HOME}"


# -----------------------------------------------------------------------------
# STEP 4: FETCH THE ADMIN PASSWORD FROM SECRETS MANAGER
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 4: Retrieving admin credentials ---"

# This works with no keys or passwords stored on the box: the instance uses
# its IAM role, which AWS injects automatically and rotates for us.
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$${SECRET_ARN}" \
  --region "$${AWS_REGION}" \
  --query SecretString \
  --output text)

# jq -r pulls a field and prints it raw (no surrounding quotes).
ADMIN_PASSWORD=$(echo "$${SECRET_JSON}" | jq -r '.password')

if [[ -z "$${ADMIN_PASSWORD}" || "$${ADMIN_PASSWORD}" == "null" ]]; then
  echo "FATAL: could not read the admin password from Secrets Manager."
  echo "Check that the instance role has secretsmanager:GetSecretValue AND kms:Decrypt."
  exit 1
fi

echo "Admin credentials retrieved successfully (value not logged)."


# -----------------------------------------------------------------------------
# STEP 5: WRITE THE REALM FILE
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 5: Writing the realm import file ---"

# Terraform already decided WHICH realm JSON to use: either the file you
# supplied, or the built-in default. That decision happened at plan time
# using fileexists(). By the time this script runs, realm_json holds the
# winning content either way.
mkdir -p "$${REALM_IMPORT_DIR}"

# A quoted heredoc ('KEYCLOAK_REALM_EOF') stops bash from trying to expand
# anything inside the JSON. Without the quotes, any $ in the realm file
# would be mangled.
cat > "$${REALM_IMPORT_DIR}/$${REALM_NAME}-realm.json" << 'KEYCLOAK_REALM_EOF'
${realm_json}
KEYCLOAK_REALM_EOF

# Validate the JSON before handing it to Keycloak. Catching a syntax error
# here gives a clear message; letting Keycloak choke on it gives a Java
# stack trace nobody wants to read.
if ! jq empty "$${REALM_IMPORT_DIR}/$${REALM_NAME}-realm.json" 2>/dev/null; then
  echo "FATAL: the realm file is not valid JSON."
  echo "First 40 lines for debugging:"
  head -40 "$${REALM_IMPORT_DIR}/$${REALM_NAME}-realm.json"
  exit 1
fi

echo "Realm file written and validated:"
jq -r '"  realm name: \(.realm)\n  enabled: \(.enabled)\n  clients: \(.clients | length)\n  roles: \(.roles.realm | length // 0)"' \
  "$${REALM_IMPORT_DIR}/$${REALM_NAME}-realm.json"

chown -R "$${KEYCLOAK_USER}:$${KEYCLOAK_USER}" "$${REALM_IMPORT_DIR}"


# -----------------------------------------------------------------------------
# STEP 6: CONFIGURE KEYCLOAK
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 6: Writing keycloak.conf ---"

cat > "$${KEYCLOAK_HOME}/conf/keycloak.conf" << KEYCLOAK_CONF_EOF
# ---------------------------------------------------------------------------
# Keycloak configuration - generated by Terraform user_data
# ---------------------------------------------------------------------------

# --- Database ---
# dev-file is an embedded H2 database written to local disk.
#
# IT IS FINE FOR TESTING AND WRONG FOR PRODUCTION, because:
#   - the data dies with the instance
#   - it cannot be shared, so you can never run more than one node
#   - it is not backed up
#
# For production set db_vendor to "postgres" and point it at RDS.
db=$${DB_VENDOR}

# --- HTTP settings ---
# We serve plain HTTP here. That is correct: the ALB already terminated TLS,
# and this traffic never leaves the private subnet.
http-enabled=true
http-port=$${HTTP_PORT}

# Bind to all interfaces so the ALB can reach us. 127.0.0.1 would only
# accept connections from the instance itself.
http-host=0.0.0.0

# --- Proxy settings ---
# CRITICAL SETTING. Keycloak sits behind a load balancer, so the connection
# it sees comes from the ALB, not the user. Without this, Keycloak builds
# redirect URLs using its own private IP and http://, and login breaks with
# a redirect loop or an "invalid redirect" error.
#
# "xforwarded" tells Keycloak to trust the X-Forwarded-For / -Proto / -Host
# headers the ALB sets, so it knows the real client IP and that the original
# request was HTTPS.
proxy-headers=xforwarded

# --- Hostname ---
# The public URL users type. Keycloak stamps this into tokens and redirects.
# Getting it wrong is the single most common Keycloak deployment failure.
hostname=$${HOSTNAME_URL}

# Allow the admin console to be served on the same hostname.
hostname-strict=false

# --- Health and metrics ---
# Turns on /health/ready and /health/live, which the ALB polls.
health-enabled=true
metrics-enabled=true

# In Keycloak 25+, health and metrics move to a separate management port
# so they are not exposed alongside the application.
http-management-port=$${MANAGEMENT_PORT}

# --- Logging ---
log=console,file
log-file=/var/log/keycloak/keycloak.log
log-level=INFO
log-console-output=default
KEYCLOAK_CONF_EOF

mkdir -p /var/log/keycloak
chown -R "$${KEYCLOAK_USER}:$${KEYCLOAK_USER}" /var/log/keycloak "$${KEYCLOAK_HOME}/conf"


# -----------------------------------------------------------------------------
# STEP 7: BUILD KEYCLOAK
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 7: Running the Keycloak build step ---"

# `kc.sh build` pre-compiles the configuration into an optimized image.
# It takes a minute but makes every subsequent start much faster.
# Re-run it any time you change database or feature settings.
sudo -u "$${KEYCLOAK_USER}" \
  JAVA_OPTS="-Xms$${JAVA_HEAP} -Xmx$${JAVA_HEAP}" \
  "$${KEYCLOAK_HOME}/bin/kc.sh" build

echo "Build complete."


# -----------------------------------------------------------------------------
# STEP 8: CREATE THE SYSTEMD SERVICE
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 8: Installing the systemd service ---"

# systemd is Linux's service manager. Registering Keycloak with it means the
# process starts on boot and restarts automatically if it crashes.
cat > /etc/systemd/system/keycloak.service << KEYCLOAK_SERVICE_EOF
[Unit]
Description=Keycloak Identity and Access Management
# Do not start until the network is actually usable.
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$${KEYCLOAK_USER}
Group=$${KEYCLOAK_USER}

# --- Bootstrap admin credentials ---
# These environment variables create the very first admin account.
# They are only used on the first start, when no admin exists yet.
# (In Keycloak 26+ these replaced the older KEYCLOAK_ADMIN variables.)
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=$${ADMIN_USERNAME}
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=$${ADMIN_PASSWORD}

# --- Java memory settings ---
# -Xms is the starting heap, -Xmx the maximum. Setting them EQUAL avoids
# pauses while the JVM resizes the heap during traffic spikes.
Environment=JAVA_OPTS=-Xms$${JAVA_HEAP} -Xmx$${JAVA_HEAP} -XX:+UseG1GC

# --- The start command ---
# --optimized skips re-checking the build, since we built in step 7.
# --import-realm imports every JSON file in data/import on startup.
#
# IMPORTANT: import only runs for realms that DO NOT already exist. On a
# restart, an existing realm is left untouched rather than overwritten, so
# your users and settings are safe.
ExecStart=$${KEYCLOAK_HOME}/bin/kc.sh start --optimized --import-realm

# Restart on failure, waiting 10 seconds between attempts.
Restart=on-failure
RestartSec=10

# Give Keycloak up to 5 minutes to start before systemd calls it hung.
TimeoutStartSec=300

# --- Security hardening ---
# NoNewPrivileges stops the process from ever gaining more permissions.
NoNewPrivileges=true
# PrivateTmp gives the service its own /tmp, isolated from other processes.
PrivateTmp=true
# ProtectSystem=strict makes the whole filesystem read-only...
ProtectSystem=strict
# ...except these specific paths, which Keycloak genuinely needs to write.
ReadWritePaths=$${KEYCLOAK_HOME}/data /var/log/keycloak
ProtectHome=true

# Java opens many files; the default limit is too low under load.
LimitNOFILE=102642

[Install]
WantedBy=multi-user.target
KEYCLOAK_SERVICE_EOF

# Lock down the unit file, because it contains the admin password.
chmod 600 /etc/systemd/system/keycloak.service

# Reload systemd so it notices the new file.
systemctl daemon-reload

# enable = start automatically on every boot. start = start it right now.
systemctl enable keycloak
systemctl start keycloak

echo "Keycloak service started."


# -----------------------------------------------------------------------------
# STEP 9: WAIT FOR KEYCLOAK TO COME UP
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 9: Waiting for Keycloak to report healthy ---"

# Poll the health endpoint until it answers or we give up.
# Without this the script exits while Keycloak is still starting, and the
# ALB briefly serves 503s with no explanation.
MAX_ATTEMPTS=60
ATTEMPT=0

while [[ $${ATTEMPT} -lt $${MAX_ATTEMPTS} ]]; do
  # -o /dev/null throws away the body; -w '%%{http_code}' prints just the
  # status code. Note the DOUBLED %% — a single % is a template placeholder.
  HTTP_CODE=$(curl -s -o /dev/null -w '%%{http_code}' \
    "http://localhost:$${MANAGEMENT_PORT}/health/ready" 2>/dev/null || echo "000")

  if [[ "$${HTTP_CODE}" == "200" ]]; then
    echo "Keycloak is READY (attempt $${ATTEMPT})."
    break
  fi

  ATTEMPT=$((ATTEMPT + 1))
  echo "  attempt $${ATTEMPT}/$${MAX_ATTEMPTS} - status $${HTTP_CODE}, waiting 10s..."
  sleep 10
done

if [[ $${ATTEMPT} -ge $${MAX_ATTEMPTS} ]]; then
  echo "WARNING: Keycloak did not report ready within 10 minutes."
  echo "Recent service logs:"
  journalctl -u keycloak -n 50 --no-pager
fi


# -----------------------------------------------------------------------------
# STEP 10: VERIFY THE REALM IMPORTED
# -----------------------------------------------------------------------------
echo ""
echo "--- STEP 10: Verifying realm import ---"

# grep -q is quiet; we only care whether it matched.
if journalctl -u keycloak --no-pager | grep -q "Imported realm"; then
  echo "Realm import confirmed in the logs."
  journalctl -u keycloak --no-pager | grep -i "realm" | tail -5
else
  echo "Note: no explicit import message found."
  echo "This is EXPECTED on a restart, because Keycloak skips realms that already exist."
fi


# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "Bootstrap finished at $(date)"
echo "  Realm:       $${REALM_NAME}"
echo "  App port:    $${HTTP_PORT}"
echo "  Health port: $${MANAGEMENT_PORT}"
echo "  Hostname:    $${HOSTNAME_URL}"
echo ""
echo "Useful commands:"
echo "  systemctl status keycloak"
echo "  journalctl -u keycloak -f"
echo "  cat /var/log/user-data.log"
echo "==================================================================="
