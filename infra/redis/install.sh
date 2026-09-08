#!/usr/bin/env bash
# Installs and configures Redis for bl8 on a fresh Debian/Ubuntu VM (Proxmox or otherwise).
# Run once, as root, on the dedicated Redis VM:
#
#   sudo ./install.sh
#
# Deliberately does NOT touch any firewall/CIDR rules — network access control (who can even
# reach port 6379) is handled separately, not by this script.
#
# Installs from the official Redis apt repo (packages.redis.io), not the distro's own package —
# Debian/Ubuntu's default repos lag well behind upstream (and pin whatever version shipped with
# that release), so this is the only way to actually land the current stable release rather than
# whatever happens to be in the OS's apt cache.
#
# This also closes a gap flagged in review: redirect/'s internal/linkcache (and ui/'s own
# README) both write link cache entries with no TTL, on the documented assumption that
# eviction is handled by the Redis server's own maxmemory-policy — which nothing anywhere in
# this repo's dev docker-compose actually configures. This script is where that assumption
# finally becomes real, not just a comment.
set -euo pipefail

# maxmemory is deliberately conservative (this cache holds nothing but small link JSON blobs —
# see ui/README.md's Redis section for the exact shape) and left overridable, not hardcoded
# past this script, per the project's own "no hardcoded tunables" convention used everywhere
# else (e.g. redirect/'s own config.go).
MAXMEMORY="${MAXMEMORY:-256mb}"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

apt-get update
apt-get install -y curl gpg lsb-release openssl

# --- Official Redis apt repo, not the distro's own package (see header comment). ---
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /etc/apt/keyrings/redis-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
	>/etc/apt/sources.list.d/redis.list
apt-get update
apt-get install -y redis-server

REDIS_CONF="/etc/redis/redis.conf"
REDIS_PASSWORD=$(openssl rand -base64 32)
# base64 output can contain "/", which would otherwise collide with sed's own "/" delimiter
# below and corrupt the substitution (or worse, silently truncate the password) whenever a
# generated password happens to contain one — escape it so the raw password (used as-is,
# unescaped, in the printed connection strings) never has to avoid that character.
REDIS_PASSWORD_SED_SAFE="${REDIS_PASSWORD//\//\\/}"

# Listen on all interfaces (this VM has no other purpose; access is bounded by whatever
# network-level access control is configured separately, not by binding to loopback only),
# require auth, and set the eviction policy the rest of this system already assumes exists:
# allkeys-lru, so the cache self-manages under MAXMEMORY instead of growing unbounded (the
# noeviction default would instead start rejecting writes once full).
sed -i "s/^bind .*/bind 0.0.0.0 -::1/" "$REDIS_CONF"
sed -i "s/^# *requirepass .*/requirepass ${REDIS_PASSWORD_SED_SAFE}/" "$REDIS_CONF"
if ! grep -q "^requirepass" "$REDIS_CONF"; then
	echo "requirepass ${REDIS_PASSWORD}" >>"$REDIS_CONF"
fi
sed -i "s/^# *maxmemory .*/maxmemory ${MAXMEMORY}/" "$REDIS_CONF"
if ! grep -q "^maxmemory " "$REDIS_CONF"; then
	echo "maxmemory ${MAXMEMORY}" >>"$REDIS_CONF"
fi
sed -i "s/^# *maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
if ! grep -q "^maxmemory-policy " "$REDIS_CONF"; then
	echo "maxmemory-policy allkeys-lru" >>"$REDIS_CONF"
fi
# Protected mode would otherwise refuse any remote connection even with a bind address set and
# a password configured (an extra Redis-specific safety net) — safe to disable given
# network-level access control is expected to already restrict who can reach this port at all.
sed -i "s/^protected-mode .*/protected-mode no/" "$REDIS_CONF"

systemctl enable --now redis-server
systemctl restart redis-server

VM_IP=$(hostname -I | awk '{print $1}')
REDIS_VERSION=$(redis-server --version | grep -oE 'v=[0-9.]+' | cut -d= -f2)

cat <<EOF

Redis ${REDIS_VERSION} is up on ${VM_IP}:6379, requirepass set, maxmemory ${MAXMEMORY} / allkeys-lru.
This script does not restrict who can reach port 6379 — make sure network-level access control
(firewall rules, security group, etc.) is in place before relying on requirepass alone.

Set these as GitHub Actions secrets:

  UI_REDIS_URL=redis://:${REDIS_PASSWORD}@${VM_IP}:6379
  REDIRECT_REDIS_ADDR=${VM_IP}:6379
  REDIRECT_REDIS_PASSWORD=${REDIS_PASSWORD}

(redirect/'s own REDIS_ADDR config var is a bare host:port, not a URL — see redirect/README.md
Environment variables — so its password has to travel as a separate secret; the deploy
workflow passes both into the container.)

This password is shown once — it lives only in redis.conf's requirepass line on this VM beyond
this point. Save it now.
EOF
