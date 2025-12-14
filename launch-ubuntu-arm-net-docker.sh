#!/bin/bash
set -e

# -----------------------------
# CONFIGURATION
# -----------------------------
VM_DIR="$HOME/qemu"
IMG_NAME="jammy-server-cloudimg-arm64.img"
DISK_NAME="ubuntu-arm.qcow2"
SEED_ISO="seed.iso"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/edk2-arm-vars.fd"

RAM=4096
CPUS=4
SSH_PORT=2222
USE_GUI=false

mkdir -p "$VM_DIR"
cd "$VM_DIR"

# -----------------------------
# Check base image
# -----------------------------
if [ ! -f "$IMG_NAME" ]; then
    echo "ERROR: Cloud image missing: $VM_DIR/$IMG_NAME"
    exit 1
fi

if [ ! -f "$EFI_CODE" ]; then
    echo "ERROR: UEFI firmware missing: $EFI_CODE"
    exit 1
fi

# -----------------------------
# Create QCOW2 disk if missing
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
# Cloud-init configuration
# -----------------------------
cat > user-data <<EOF
#cloud-config
hostname: ubuntu-arm
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

write_files:
  # Netplan configuration
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          all:
            match:
              driver: virtio_net
            dhcp4: true
            optional: true
            nameservers:
              addresses: [8.8.8.8,8.8.4.4]

  # Systemd unit to bring NIC up
  - path: /etc/systemd/system/bring-up-nic.service
    content: |
      [Unit]
      Description=Force bring-up virtio network interface
      After=network-pre.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/sbin/ip link set $(ip -o link show | awk -F': ' '/virtio_net/ {print $2}') up
      ExecStart=/sbin/dhclient $(ip -o link show | awk -F': ' '/virtio_net/ {print $2}')
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

  # Systemd unit to install Docker via Snap
  - path: /etc/systemd/system/install-docker-snap.service
    content: |
      [Unit]
      Description=Install Docker via Snap after network is online
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/bash -c "
        echo 'Waiting for network...'
        timeout 60 bash -c 'until ping -c1 8.8.8.8 &>/dev/null; do sleep 1; done'
        echo 'Installing Docker via Snap...'
        snap install docker
        snap alias docker.docker docker
        usermod -aG docker ubuntu
      "
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl enable bring-up-nic.service
  - systemctl enable install-docker-snap.service
EOF

echo "instance-id: ubuntu-arm" > meta-data

# -----------------------------
# Create cloud-init ISO
# -----------------------------
mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock user-data meta-data

# -----------------------------
# Launch QEMU
# -----------------------------
QEMU_CMD="qemu-system-aarch64 \
  -machine virt,accel=hvf \
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
    QEMU_CMD+=" -device virtio-gpu-pci -display default,show-cursor=on"
else
    QEMU_CMD+=" -nographic"
fi

echo "Launching VM..."
eval "$QEMU_CMD"