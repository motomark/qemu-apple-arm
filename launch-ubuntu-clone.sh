#!/bin/bash
set -e

# -----------------------------
# CONFIGURATION
# -----------------------------
VM_DIR="$HOME/git/qemu-apple-arm"
TEMPLATE="$VM_DIR/ubuntu-arm-template.qcow2"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/edk2-arm-vars.fd"
RAM=4096
CPUS=4
SSH_BASE_PORT=2222
USE_GUI=false

mkdir -p "$VM_DIR"
cd "$VM_DIR"

# -----------------------------
# Check template
# -----------------------------
if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template missing: $TEMPLATE"
    exit 1
fi

if [ ! -f "$EFI_CODE" ]; then
    echo "ERROR: UEFI firmware missing: $EFI_CODE"
    exit 1
fi

# -----------------------------
# Create writable UEFI vars if missing
# -----------------------------
if [ ! -f "$EFI_VARS" ]; then
    cp "$EFI_CODE" "$EFI_VARS"
fi

# -----------------------------
# Create a new VM disk from template
# -----------------------------
TIMESTAMP=$(date +%s)
DISK_NAME="$VM_DIR/ubuntu-arm-$TIMESTAMP.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$TEMPLATE" "$DISK_NAME"

# -----------------------------
# Assign SSH port based on timestamp
# -----------------------------
SSH_PORT=$((SSH_BASE_PORT + (TIMESTAMP % 1000)))

# -----------------------------
# Ensure SSH key exists
# -----------------------------
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
fi
PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")

# -----------------------------
# Create cloud-init ISO for this clone
# -----------------------------
SEED_ISO="$VM_DIR/seed-$TIMESTAMP.iso"

cat > user-data <<EOF
#cloud-config
hostname: ubuntu-arm-$TIMESTAMP
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
  # Netplan
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

  # Bring NIC up
  - path: /etc/systemd/system/bring-up-nic.service
    content: |
      [Unit]
      Description=Bring up virtio NIC
      After=network-pre.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/sbin/ip link set $(ip -o link show | awk -F': ' '/virtio_net/ {print $2}') up
      ExecStart=/sbin/dhclient $(ip -o link show | awk -F': ' '/virtio_net/ {print $2}')
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

  # Install Docker via Snap
  - path: /etc/systemd/system/install-docker-snap.service
    content: |
      [Unit]
      Description=Install Docker via Snap
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/bash -c "
        timeout 60 bash -c 'until ping -c1 8.8.8.8 &>/dev/null; do sleep 1; done'
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
  - echo "Launching VM on SSH port $SSH_PORT..."
EOF

echo "instance-id: ubuntu-arm-$TIMESTAMP" > meta-data

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

echo "Launching VM on SSH port $SSH_PORT..."
eval "$QEMU_CMD"