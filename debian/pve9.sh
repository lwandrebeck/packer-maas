#!/bin/bash
cat > /etc/apt/sources.list.d/pve-install-repo.sources << EOL
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL
wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O /usr/share/keyrings/proxmox-archive-keyring.gpg
apt modernize-sources
apt update && apt full-upgrade -y
apt remove linux-image-amd64 'linux-image-6.1*' os-prober -y
apt install proxmox-default-kernel proxmox-ve postfix open-iscsi chrony -y
sed -i 's@deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise@# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise@' /etc/apt/sources.list.d/pve-enterprise.list
update-grub
