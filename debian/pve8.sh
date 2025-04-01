#!/bin/bash
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-install-repo.list
wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
apt update && apt full-upgrade -y
apt remove linux-image-amd64 'linux-image-6.1*' os-prober -y
apt install proxmox-default-kernel proxmox-ve postfix open-iscsi chrony -y
sed -i 's@deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise@# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise@' /etc/apt/sources.list.d/pve-enterprise.list
update-grub
