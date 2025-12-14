#!/bin/bash
set -e

# -----------------------------
# CONFIGURATION
# -----------------------------
VM_DIR="$HOME/kvm"
IMG_NAME="jammy-server-cloudimg-amd64.img"
DISK_NAME="ubuntu-x86.qcow2"
SEED_ISO="seed.iso"

EFI_CODE="/usr/share/OVMF/OVMF_CODE.fd"
EFI_VARS="$VM_DIR/OVMF_VARS.fd"

RAM=4096
CPUS=4
SSH_PORT=2222
USE_GUI=false

mkdir -p "$VM_DIR"
cd "$VM_DIR"

# -----------------------------
# Check prerequisites
# -----------------------------
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    exit 1
fi

if ! lsmod | grep -q kvm; then
    echo "ERROR: KVM not loaded"
    exit 1
fi

# -----------------------------
# Download base image
# -----------------------------
if [ ! -f "$IMG_NAME" ]; then
    echo "Downloading Ubuntu cloud image..."
    wget https://cloud-images.ubuntu.com/jammy/current/$IMG_NAME
fi

# -----------------------------
# Create QCOW2 disk
# -----------------------------
if [ ! -f "$DISK_NAME" ]; then
    echo "Creating QCOW2 disk..."
    qemu-img convert -O qcow2 "$IMG_NAME" "$DISK_NAME"
fi

# -----------------------------
# Create writable UEFI vars
# -----------------------------
if [ ! -f "$EFI_VARS" ]; then
    cp "$EFI_CODE" "$EFI_VARS"
fi

# -----------------------------
# Ensure SSH key exists
# -----------------------------
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
fi

PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")

# -----------------------------
# Cloud-init user-data
# -----------------------------
cat > user-data <<EOF
#cloud-config
hostname: ubuntu-x86
manage_etc_hosts: true

users:
  - name: ubuntu
    ssh_authorized_keys:
      - $PUBKEY
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false

ssh_pwauth: true

packages:
  - curl
  - ca-certificates
  - gnupg
  - snapd

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
  - snap install docker
  - snap alias docker.docker docker
  - usermod -aG docker ubuntu
EOF

# -----------------------------
# Cloud-init meta-data
# -----------------------------
cat > meta-data <<EOF
instance-id: ubuntu-x86
local-hostname: ubuntu-x86
EOF

# -----------------------------
# Create cloud-init ISO
# -----------------------------
cloud-localds "$SEED_ISO" user-data meta-data

# -----------------------------
# Launch QEMU (KVM)
# -----------------------------
QEMU_CMD="qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -cpu host \
  -smp $CPUS \
  -m $RAM \
  -drive if=pflash,format=raw,readonly=on,file=$EFI_CODE \
  -drive if=pflash,format=raw,file=$EFI_VARS \
  -drive if=virtio,file=$DISK_NAME,format=qcow2 \
  -drive if=virtio,file=$SEED_ISO,format=raw \
  -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=net0"

if [ "$USE_GUI" = true ]; then
    QEMU_CMD+=" -display gtk"
else
    QEMU_CMD+=" -nographic"
fi

echo "Launching VM..."
exec $QEMU_CMD