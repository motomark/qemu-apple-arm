

# Ubuntu ARM QEMU Golden Image (Template) Workflow  
**macOS (Apple Silicon) + QEMU**

This guide walks through creating a **reusable Ubuntu ARM VM template** (golden image) using QEMU on macOS (Apple Silicon), with software pre-installed (e.g., Docker).

---

## Overview

We will:

* STEP 1 — Create the base VM (template)
* STEP 2 — Create seed ISO (cloud-init)
* STEP 3 — Boot the template VM
* STEP 4 — Install software
* STEP 5 — CLEAN the template.
* STEP 6 — Lock the template
* STEP 7 — Create a new VM from the template
* STEP 8 — Run the cloned VM

---

## Recommended Directory Layout

```
~/qemu/
├── templates/
│   └── ubuntu-22.04-arm-template.qcow2
├── vms/
│   ├── vm1/
│   │   ├── disk.qcow2
│   │   └── seed.iso
│   └── vm2/
│       ├── disk.qcow2
│       └── seed.iso

```

# STEP 1 — Create the base VM (template)

Download Ubuntu ARM cloud image (once):

```
cd ~/qemu/templates
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
```

Convert it to qcow2 (optional but clean):
```
qemu-img convert -O qcow2 \
jammy-server-cloudimg-arm64.img \
ubuntu-22.04-arm-template.qcow2
```

## STEP 2 — Create seed ISO (cloud-init)

This is why seed.iso exists:

Cloud images do not auto-configure users, SSH, or networking without it.

Create a working directory:
```
mkdir seed
cd seed
```

user-data :
```
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub)

ssh_pwauth: true
disable_root: true

packages:
  - curl
  - ca-certificates
  - gnupg
  - lsb-release

runcmd:
  - systemctl enable systemd-networkd
  - systemctl restart systemd-networkd
```

meta-data :
```
instance-id: template
local-hostname: ubuntu-template
```

Create ISO:
```
mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

You do NOT re-run this unless user-data changes.

## STEP 3 — Boot the template VM

```qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -smp 4 \
  -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-arm-vars.fd \
  -drive if=virtio,file=ubuntu-22.04-arm-template.qcow2,format=qcow2 \
  -drive if=virtio,file=seed.iso,format=raw \
  -nic user,model=virtio-net-pci,hostfwd=tcp::3030-:22 \
  -nographic
```

SSH in:

```
ssh -i ~/.ssh/id_rsa -p 3030 ubuntu@localhost
```

## STEP 4 — Install software (THIS is the magic)

Example: Docker (recommended way on Ubuntu)

```
sudo apt update
sudo apt install -y docker.io docker-compose
sudo usermod -aG docker ubuntu
```

Log out & back in:

```
exit
ssh -i ~/.ssh/id_rsa -p 3030 ubuntu@localhost
```

Verify:

```
docker run hello-world
```

Install anything else you want:
	
* Kubernetes tools
* Java
* Node
* Python
* Dev tools
* Monitoring agents

## STEP 5 — CLEAN the template (critical!)
This is what makes it reusable.
```
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo rm -rf /var/lib/cloud/*
```
Shut Down:
```
sudo poweroff
```

## STEP 6 — Lock the template
Make it read-only to prevent corruption:
```
chmod 444 ~/qemu/templates/ubuntu-22.04-arm-template.qcow2
```

## STEP 7 — Create a new VM from the template (fast)

```
mkdir ~/qemu/vms/vm1
cd ~/qemu/vms/vm1
```

Create an Overlay Disk:
```
qemu-img create \
  -f qcow2 \
  -F qcow2 \
  -b ~/qemu/templates/ubuntu-22.04-arm-template.qcow2 \
  disk.qcow2
```

Create new seed ISO (new hostname, keys, IPs):
```
cp ~/qemu/seed/* .
sed -i '' 's/ubuntu-template/vm1/' meta-data
mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
```
## STEP 8 — Run the cloned VM
```
qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -m 2048 \
  -drive if=virtio,file=disk.qcow2,format=qcow2 \
  -drive if=virtio,file=seed.iso,format=raw \
  -nic user,model=virtio-net-pci,hostfwd=tcp::3031-:22 \
  -nographic
```
SSH:
```
ssh -i ~/.ssh/id_rsa -p 3031 ubuntu@localhost
```

## Why this works so well:
| Feature| Benefit |
| -------- | ------- |
|qcow2 backing file| clones in seconds |
| cloud-init | unique networking + SSH |
|template cleanup | no conflicts |
| read-only base | safe |

