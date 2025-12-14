#!/bin/bash
set -e

# -----------------------------
# Configuration
# -----------------------------
VM_DIR="$HOME/qemu"
IMG_NAME="jammy-server-cloudimg-arm64.img"
QCOW2_NAME="ubuntu-arm64.qcow2"
SEED_ISO="seed.iso"
UBUNTU_URL="https://cloud-images.ubuntu.com/releases/22.04/release/$IMG_NAME"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/edk2-aarch64-vars.fd"

MEM=4096
CPUS=4
SSH_PORT=2222
USE_GUI=true  # Set to false for console only

mkdir -p "$VM_DIR"
cd "$VM_DIR"

# -----------------------------
# Download Ubuntu ARM cloud image
# -----------------------------
if [ ! -f "$IMG_NAME" ]; then
    echo "Downloading Ubuntu ARM64 cloud image..."
    curl -LO "$UBUNTU_URL"
fi

# -----------------------------
# Convert to QCOW2
# -----------------------------
if [ ! -f "$QCOW2_NAME" ]; then
    echo "Converting to QCOW2..."
    qemu-img convert -O qcow2 "$IMG_NAME" "$QCOW2_NAME"
fi

# -----------------------------
# Create writable UEFI vars file if missing
# -----------------------------
if [ ! -f "$EFI_VARS" ]; then
    echo "Creating writable UEFI vars file..."
    cp "$EFI_CODE" "$EFI_VARS"
fi

# -----------------------------
# Create cloud-init config
# -----------------------------
cat > user-data <<'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
ssh_pwauth: true
EOF

echo "instance-id: iid-local01" > meta-data

# -----------------------------
# Generate seed ISO
# -----------------------------
echo "Generating seed.iso..."
if ! command -v mkisofs &>/dev/null; then
    echo "Installing cdrtools for mkisofs..."
    brew install cdrtools
fi

mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock user-data meta-data

# -----------------------------
# Launch QEMU
# -----------------------------
echo "Launching QEMU..."

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
    # Enable SPICE/virtio-gpu for GUI
    QEMU_CMD+=" -device virtio-gpu-pci -display default,show-cursor=on"
else
    QEMU_CMD+=" -nographic"
fi

echo "Run the VM with:"
echo "$QEMU_CMD"

# Execute the command
eval "$QEMU_CMD"