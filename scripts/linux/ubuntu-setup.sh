#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/lab.conf <<EOF
[Resolve]
DNS=${dc_ip}
Domains=${domain_name}
FallbackDNS=8.8.8.8
EOF
systemctl restart systemd-resolved || true

apt-get update && apt-get -y upgrade
apt-get install -y git python3-pip python3-venv openssh-server software-properties-common curl ca-certificates
systemctl enable --now ssh || systemctl enable --now sshd || true

# Ensure sshd permits password auth
# Some GCE images set password auth off in drop-ins; force-enable via drop-in
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-password-auth.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
# Also patch main config if the directive exists
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
systemctl restart ssh || systemctl restart sshd || true

# Set password for 'ubuntu' user
echo "ubuntu:${ubuntu_password}" | chpasswd


# Optional static hosts entries for lab names (belt-and-suspenders)
if [ "${add_hosts_entries}" = "true" ]; then
  sed -i '/my-lab\.local/d' /etc/hosts
  cat >> /etc/hosts <<EOF
${dc_ip} dc.my-lab.local dc
${ca_ip} ca.my-lab.local ca
${ws_ip} wrkst.my-lab.local wrkst
EOF
fi


# Install Python 3.12 and pip for 3.12 (idempotent)
if ! command -v python3.12 >/dev/null 2>&1; then
  if ! grep -Rqs "deadsnakes" /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y ppa:deadsnakes/ppa || true
  fi
  apt-get update
  apt-get install -y python3.12 python3.12-venv || true
fi

# Ensure pip for Python 3.12
if ! /usr/bin/python3.12 -m pip --version >/dev/null 2>&1; then
  curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
  /usr/bin/python3.12 /tmp/get-pip.py
fi



