#!/bin/bash

# ============================================================
# K3s Reinstall Script
# Usage: bash reinstall_k3s.sh [IP_ADDRESS]
# If no IP is provided, the DEFAULT_VM_IP below is used.
# ============================================================

# ---- EDIT THIS FIELD to set a default VM IP ----
DEFAULT_VM_IP="10.2.0.255"
# -------------------------------------------------

# ---- EDIT THIS to change the SSH user ----
SSH_USER="ubuntu"
# ------------------------------------------

# ---- EDIT THIS to set a custom SSH key path (leave empty to use default) ----
SSH_KEY=""
# ------------------------------------------------------------------------------

# ---- EDIT: Certificate content for private registry ----
REG_CA_CERT="-----BEGIN CERTIFICATE-----
MIIFdTCCA12gAwIBAgIUaijJzh7/YXch+cp8Fm6DYboBYoUwDQYJKoZIhvcNAQEN
BQAwSjELMAkGA1UEBhMCVVMxETAPBgNVBAoMCGFwcHNjb2RlMREwDwYDVQQLDAhQ
ZXJzb25hbDEVMBMGA1UEAwwMYXBwc2NvZGUuY29tMB4XDTI1MDExMTA0MzMyOFoX
DTM1MDEwOTA0MzMyOFowSjELMAkGA1UEBhMCVVMxETAPBgNVBAoMCGFwcHNjb2Rl
MREwDwYDVQQLDAhQZXJzb25hbDEVMBMGA1UEAwwMYXBwc2NvZGUuY29tMIICIjAN
BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxZsZsi4FfK5hutO99APlmws3vvdG
yI9QpMUvKCMPyWivJeg9lkgsddOAEjDsIdM76hAof8g7z488hHRH2/qeha2t3esf
vZLoU2ewawcR24zis0pPc78mDoQX8SE/MxPsjSIbTuqzFWtE70Mry3+xTlXSKjX5
szU13BJ9vXN2qifKcwkFq2A3qLENZqOjeYOznRbqpkLMfU2zmqWenaxr8JHwiuJl
Rfdl8X2IhGyy/yG3yHtmTePWcMwnaU9WgvROtC5vglWvumf2XPi+PQn7zF4D4ybg
R6dsNLm12RTGV9daOGzQ5h8W8iNd4tydYzoELVQmPGNoYm4QqT3pwLweduUD4jOe
/tL5C/znAUYG/Md4LFm+6Bm8ktqORdc1sX0RdziKs5Xbnb/VKPUfMVAr6K6ShKJD
5BLWoRJe9e4FRviJk5Tis29/qxj81jOEd+romhf5Di9DWfmAMx5SicJmV2Ag4mAu
GK7Rrvlqza09zc/ITMz1NCL0GWQ9u/bPoYJWw+xFxVrAjgrow8KhsyKEIgL311MQ
MPODZVbfd00eOpnd0SPzaPaJdKbYxABoGZlF2tdpGQRSNUpOjYQ6xC5dRadoVY2g
NhGAV+BDYcpmCVK4i3QR1093ACl8868KAHnRfeZOYOfo2LJcHPCjCMzVVRsXHxHv
VwiMsPDHQVxUJvkCAwEAAaNTMFEwHQYDVR0OBBYEFKFvJ8xHpfrvymY5wwmLn/2l
m1MyMB8GA1UdIwQYMBaAFKFvJ8xHpfrvymY5wwmLn/2lm1MyMA8GA1UdEwEB/wQF
MAMBAf8wDQYJKoZIhvcNAQENBQADggIBAA68oplyuHziv86lADoqVGaXwHxjhZ5S
ALSJks1D/19yvY0t52Fq0KIxuirZtfCdu/BYW8RxmeLFcRbvtdLMMFP3tlAzzppj
PlEgH4t6awUczKM9CBp08aXSNWeBErWPqB1J1UqkPiCC8Hs0E8LelmPSzDkoAjvC
H+S7jHcTOZVrtAUzhdOFUrA5ryTmat+THcAxYaOC/91QCYcCAujhgrzABZAeKcjx
4K+VgvpRbBsb4kvxb/S3jNIzFBZQoS6/OJAuOU4rkWyRFJwDCaXd45pu4nHqa6JV
ZGXi2DuTgrvyb2itYpFruFJBvBUzrUYY+w9hnqn9cIvBrgnN7lVldff1gbKoKl7i
gyRJXTaYIAUFWEgmnIBHsvj6tzAzlfP4Xp5be/pBRjnmU7wLU5vfM0tzspCUrlon
BrCAaC4vxknck8tAZDiYFhejTfVPMNWBMFoloquPToYbZest5TO6CNiRJd2lWTRX
gIC23XGEUl+N0lpRZpbd/ZmPxqoTJTtgXHKFLg6AogWfTvjCDdeZkZMFIJARS/cq
lrhrdyYB/Yd1YzPQRU88GbqC/Bkof1aIoFJrD3/2q8HB352erzQvvVeUr1AibtVn
fAEYssuxg4/fYX4KNbNTnqGd0Cezy/kIYwY5sn2FIiUIit+e4Lh33gXq6ReCX3Hb
lcI02rEEYenJ
-----END CERTIFICATE-----"
# --------------------------------------------------------

# ---- EDIT: Registry config (host/tls settings) ----
REGISTRY_HOST="0.1.acdc.appscode.ninja"
# ----------------------------------------------------

# Resolve IP: use argument if provided, else fall back to default
VM_IP="${1:-$DEFAULT_VM_IP}"

# Build SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

echo "=============================================="
echo " K3s Reinstall Script"
echo " Target VM : ${SSH_USER}@${VM_IP}"
echo "=============================================="
echo ""

# Verify SSH connectivity before proceeding
echo "[*] Checking SSH connectivity to ${VM_IP}..."
if ! ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "echo 'SSH OK'" &>/dev/null; then
  echo "[ERROR] Cannot reach ${VM_IP} via SSH. Check IP, key, or network."
  exit 1
fi
echo "[OK] SSH connection successful."
echo ""

# ---------------------------------------------------------------
# Build the remote script as a heredoc and pipe it over SSH
# ---------------------------------------------------------------
ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" bash -s << REMOTE_SCRIPT

set -e  # Exit immediately on any error

echo ""
echo "=============================="
echo " STEP 1: Uninstalling K3s"
echo "=============================="
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  sudo bash /usr/local/bin/k3s-uninstall.sh
  echo "[OK] K3s uninstalled."
else
  echo "[WARN] k3s-uninstall.sh not found — skipping uninstall (K3s may not have been installed)."
fi

echo ""
echo "=============================="
echo " STEP 2: Kernel / inotify tuning"
echo "=============================="
echo 'fs.inotify.max_user_instances=100000' | sudo tee -a /etc/sysctl.conf
echo 'fs.inotify.max_user_watches=100000'   | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
echo "[OK] sysctl values applied."

echo ""
echo "=============================="
echo " STEP 3: Private Registry Config"
echo "=============================="
sudo mkdir -p /etc/rancher/k3s

sudo tee /etc/rancher/k3s/reg-ca.crt > /dev/null << 'CERT_EOF'
${REG_CA_CERT}
CERT_EOF

sudo tee /etc/rancher/k3s/registries.yaml > /dev/null << 'REG_EOF'
configs:
  ${REGISTRY_HOST}:
    tls:
      ca_file: /etc/rancher/k3s/reg-ca.crt
REG_EOF

echo "[OK] Registry config written."

echo ""
echo "=============================="
echo " STEP 4: Installing K3s"
echo "=============================="
export SERVER_IP=\$(curl -4 -s ifconfig.me)
echo "[*] Detected public IP: \$SERVER_IP"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=metrics-server" sh -s - --tls-san "\$SERVER_IP"
echo "[OK] K3s installed."

echo ""
echo "=============================="
echo " STEP 5: Shell aliases & KUBECONFIG"
echo "=============================="
grep -qxF "alias k=kubectl" ~/.bashrc         || echo 'alias k=kubectl'                          >> ~/.bashrc
grep -qxF "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" ~/.bashrc \
  || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "[OK] Aliases and KUBECONFIG set."

echo ""
echo "=============================="
echo " STEP 6: Wait for CoreDNS"
echo "=============================="
echo "[*] Waiting for CoreDNS deployment to be created (timeout 60s)..."
sudo kubectl wait --for=create -n kube-system deploy/coredns --timeout=60s || true
echo "[*] Waiting for CoreDNS to be available..."
sudo kubectl wait --for=condition=available -n kube-system deploy/coredns --timeout=120s || true
echo "[OK] CoreDNS is running."

echo ""
echo "=============================="
echo " STEP 7: Installing Helm"
echo "=============================="
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "[OK] Helm installed: \$(helm version --short)"

echo ""
echo "=============================="
echo " STEP 8: Kubeconfig"
echo "=============================="
echo "[*] Cluster kubeconfig (copy this for remote access):"
echo "------------------------------------------------------"
sudo cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/${VM_IP}/g"
echo "------------------------------------------------------"
echo ""
echo "[DONE] K3s reinstall complete on \$(hostname) (${VM_IP})"

REMOTE_SCRIPT

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo ""
  echo "[ERROR] Remote script failed with exit code $EXIT_CODE."
  exit $EXIT_CODE
fi


# Save kubeconfig locally next to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_KUBECONFIG="${SCRIPT_DIR}/k3s.yaml"

echo ""
echo "[*] Saving kubeconfig to ${LOCAL_KUBECONFIG} ..."
ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" \
  "sudo cat /etc/rancher/k3s/k3s.yaml | sed \"s/127.0.0.1/${VM_IP}/g\"" \
  > "${LOCAL_KUBECONFIG}"
echo "[OK] Kubeconfig saved to ${LOCAL_KUBECONFIG}"

echo ""
echo "[DONE] All steps completed successfully for ${VM_IP}."
