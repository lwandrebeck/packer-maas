#!/bin/bash -ex
#
# pve.sh - Turn a Debian 13 (Trixie) cloud image into Proxmox VE 9, ready for
# MAAS deployment.
#
# See https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
if [ "${VERSION_CODENAME}" != "trixie" ]; then
    echo "Proxmox VE 9 must be built from trixie, not '${VERSION_CODENAME}'" >&2
    exit 1
fi

cat > /etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg

# pve-cluster refuses to start unless the hostname resolves to a non-loopback
# address, which makes the proxmox-ve postinst fail. Provide one for the build.
cp --preserve /etc/hosts /run/hosts.pve-build
BUILD_IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([^ ]*\).*/\1/p')
sed -i "1i ${BUILD_IP} $(hostname)" /etc/hosts

debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Local only
EOF

apt-get update
apt-get full-upgrade -y
apt-get install -y proxmox-default-kernel
apt-get install -y proxmox-ve postfix open-iscsi chrony ifupdown2

# Remove the Debian kernels (mandatory per Proxmox docs) and os-prober.
DEBIAN_KERNELS=$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' 'linux-image-*' |
    awk '$2 == "installed" && $1 !~ /-pve/ { print $1 }')
apt-get purge -y ${DEBIAN_KERNELS} os-prober
apt-get autoremove -y --purge

# Disable the enterprise repositories, they need a subscription.
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.sources; do
    if grep -q enterprise.proxmox.com "$f" && ! grep -q '^Enabled:' "$f"; then
        echo 'Enabled: false' >> "$f"
    fi
done
shopt -u nullglob

update-grub

# PVE manages networking through ifupdown2 and /etc/network/interfaces only.
# Drop the build VM's netplan/networkd/resolved setup so nothing else fights
# over the interfaces, and the pending network change PVE would apply at boot.
systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service systemd-resolved.service
rm -f /etc/netplan/*.yaml /etc/network/interfaces.new

# Make cloud-init render the MAAS network config for ifupdown2. /etc/hosts is
# handled by pve-maas-network below, cloud-init must leave it alone.
# PVE is administered as root: give root the MAAS user's SSH keys too. Its
# password stays locked, SSH password authentication stays off.
cat > /etc/cloud/cloud.cfg.d/99-pve.cfg <<EOF
manage_etc_hosts: false
disable_root: false
ssh_pwauth: false
system_info:
  network:
    renderers: ['eni']
EOF

# First boot helper, run in two steps:
# - "interfaces": cloud-init can only write /etc/network/interfaces.d/50-cloud-init,
#   which neither PVE's interfaces file nor its GUI read. Move it into
#   /etc/network/interfaces before networking starts and hand the network
#   over to PVE for good.
# - "hosts": MAAS only tells the node its address through the network config,
#   so /etc/hosts and /etc/resolv.conf are written once the network is up and
#   before pve-cluster starts.
cat > /usr/local/sbin/pve-maas-network <<'EOF'
#!/bin/sh
# pve-maas-network - Make a MAAS deployed node usable by Proxmox VE.
set -e

interfaces() {
    ci=/etc/network/interfaces.d/50-cloud-init
    [ -f "$ci" ] || return 0
    {
        grep -q '^iface lo ' "$ci" || printf 'auto lo\niface lo inet loopback\n\n'
        # Drop comments and the "dns {...}" python dict some cloud-init
        # versions emit next to the dns-* options.
        grep -v -e '^#' -e '^[[:space:]]*dns {' "$ci" | sed 's/^\([[:space:]]*\)bridge_/\1bridge-/'
    } > /etc/network/interfaces
    rm -f "$ci"
    printf 'network:\n  config: disabled\n' > /etc/cloud/cloud.cfg.d/99-pve-network.cfg
}

words() {
    sed -n "s/^[[:space:]]*$1[[:space:]]\+//p" /etc/network/interfaces |
        tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

hosts() {
    # PVE wants a static resolv.conf, cloud-init only puts DNS in interfaces.
    nameservers=$(words dns-nameservers | head -n 3)
    search=$(words dns-search | tr '\n' ' ')
    if [ -n "$nameservers" ]; then
        rm -f /etc/resolv.conf
        {
            [ -n "$search" ] && echo "search $search"
            for ns in $nameservers; do echo "nameserver $ns"; done
        } > /etc/resolv.conf
    fi

    short=$(hostname -s)
    domain=$(sed -n 's/^\(search\|domain\)[[:space:]]\+\([^[:space:]]*\).*/\2/p' /etc/resolv.conf | head -n 1)
    fqdn=$short
    [ -n "$domain" ] && fqdn="$short.$domain"

    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')
    [ -n "$ip" ] || ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')
    [ -n "$ip" ] || ip=$(ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1]; exit }')
    if [ -z "$ip" ]; then
        echo "pve-maas-network: no global address found" >&2
        exit 1
    fi

    # Replace any entry for this host, including Debian's 127.0.1.1 one.
    sed -i "/[[:space:]]$short\([.[:space:]]\|\$\)/d" /etc/hosts
    if [ "$fqdn" = "$short" ]; then
        echo "$ip $short" >> /etc/hosts
    else
        echo "$ip $fqdn $short" >> /etc/hosts
    fi

    echo "$fqdn" > /etc/mailname
    postconf -e "myhostname=$fqdn" || true
}

case "$1" in
interfaces | hosts) "$1" ;;
*)
    echo "usage: $0 interfaces|hosts" >&2
    exit 2
    ;;
esac
touch "/var/lib/pve-maas-network.$1.done"
EOF
chmod 755 /usr/local/sbin/pve-maas-network

cat > /etc/systemd/system/pve-maas-interfaces.service <<EOF
[Unit]
Description=Move the MAAS network config into /etc/network/interfaces for Proxmox VE
ConditionPathExists=!/var/lib/pve-maas-network.interfaces.done
DefaultDependencies=no
After=local-fs.target cloud-init-local.service
Before=network-pre.target networking.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-maas-network interfaces
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pve-maas-network.service <<EOF
[Unit]
Description=Configure /etc/hosts and DNS for Proxmox VE from MAAS network config
ConditionPathExists=!/var/lib/pve-maas-network.hosts.done
Wants=network-online.target
After=network-online.target cloud-init.service
Before=pve-cluster.service postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-maas-network hosts
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable pve-maas-interfaces.service pve-maas-network.service

# Every deployed node must get its own cluster database, root CA, node
# certificates and authkey: drop what was generated for the build VM.
# pve-cluster recreates them on first boot (pvecm updatecerts).
systemctl stop pve-cluster.service
rm -rf /var/lib/pve-cluster/config.db* /etc/pve/* /var/lib/rrdcached/db/pve2-*

mv /run/hosts.pve-build /etc/hosts
# Replace the systemd-resolved stub link, pve-maas-network fills it on first boot.
rm -f /etc/resolv.conf
: > /etc/resolv.conf
apt-get clean
