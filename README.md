
chmod +x launch-ubuntu-arm-ssh.sh
./launch-ubuntu-arm-ssh.sh

ssh ubuntu@localhost -p 2222

# Latest script
```
# Run with the latest script.
sudo chmod +x launch-ubuntu-arm-net.sh
./launch-ubuntu-arm-net.sh

# Log in over ssh from another Terminal using pub key:
sh -i ~/.ssh/id_rsa -p 2222 -o StrictHostKeyChecking=no ubuntu@localhost
```

# Update the seed.iso after each cloud config update
```
mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

# Resolve manual Network config issues (the latest cloud-init config fixes these)
```
ip link
sudo ip link set enp0s1 up
sudo dhclient enp0s1
sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
```

# Template workflow

1. Download Ubuntu Image ([Cloud Image](jammy-server-cloudimg-arm64.img))
2. 





