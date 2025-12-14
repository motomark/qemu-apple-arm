#!/bin/bash
set -e

# -----------------------------
# Configuration
# -----------------------------
VM_DIR="$HOME/qemu"
IMG_NAME="jammy-server-cloudimg-arm64.img"
QCOW2_NAME="ubuntu-arm64.qcow2"
SEED_ISO="seed.iso"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/edk2-aarch64-vars.fd"

MEM=4096
CPUS=4
SSH_PORT=2222
USE_GUI=false    # false = console only; true = GUI window

mkdir -p "$VM_DIR"
cd "$VM_DIR"

# -----------------------------
# Validate required files exist
# -----------------------------
if [ ! -f "$IMG_NAME" ]; then
    echo "ERROR: Missing cloud image:"
    echo "$VM_DIR/$IMG_NAME"
    echo "Please manually download it (offline machine cannot download automatically)."
    exit 1
fi

if [ ! -f "$EFI_CODE" ]; then
    echo "ERROR: Missing UEFI firmware:"
    echo "$EFI_CODE"
    echo "Install QEMU with: brew install qemu"
    exit 1
fi

# -----------------------------
# Convert to QCOW2 if needed
# -----------------------------
if [ ! -f "$QCOW2_NAME" ]; then
    echo "Converting raw cloud-image to QCOW2..."
    qemu-img convert -O qcow2 "$IMG_NAME" "$QCOW2_NAME"
fi

# -----------------------------
# Create writable UEFI vars
# -----------------------------
if [ ! -f "$EFI_VARS" ]; then
    echo "Creating writable UEFI VARS..."
    cp "$EFI_CODE" "$EFI_VARS"
fi

# -----------------------------
# Ensure SSH key exists (offline-safe)
# -----------------------------
if [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    echo "No SSH key found — generating offline keypair..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
fi

PUBKEY=$(cat "$HOME/.ssh/id_rsa.pub")

# -----------------------------
# Create cloud-init configuration
# -----------------------------
echo "Creating cloud-init user-data and meta-data..."

cat > user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
ssh_pwauth: true
EOF

echo "instance-id: iid-local01" > meta-data

# -----------------------------
# Generate cloud-init ISO (offline)
# -----------------------------
if ! command -v mkisofs &> /dev/null; then
    echo "ERROR: mkisofs not installed. Install offline with:"
    echo "brew install cdrtools"
    exit 1
fi

echo "Building cloud-init seed ISO..."
mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock user-data meta-data

# -----------------------------
# Launch QEMU (offline)
# -----------------------------
echo "Launching offline Ubuntu VM..."

QEMU_CMD="qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -smp $CPUS \
  -m $MEM \
  -drive if=pflash,format=raw,readonly=on,file=$EFI_CODE \
  -drive if=pflash,format=raw,file=$EFI_VARS \
  -drive if=virtio,file=$QCOW2_NAME,format=qcow2 \
  -drive if=virtio,file=$SEED_ISO,format=raw \
  -nic user,model=virtio-net-pci,hostfwd=tcp::$SSH_PORT-:22"

if [ "$USE_GUI" = true ]; then
    QEMU_CMD+=" -device virtio-gpu-pci -display default,show-cursor=on"
else
    QEMU_CMD+=" -nographic"
fi

echo "$QEMU_CMD"
eval "$QEMU_CMD"