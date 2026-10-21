# Debian & Proxmox VE Packer Templates for MAAS

## Introduction

The Packer templates in this directory creates Debian & PVE images for use with MAAS.

## Prerequisites (to create the image)

* A machine running Ubuntu 18.04+ with the ability to run KVM virtual machines.
* qemu-utils, libnbd-bin, nbdkit and fuse2fs
* qemu-system
* ovmf
* cloud-image-utils
* [Packer](https://www.packer.io/intro/getting-started/install.html), v1.7.0 or newer

## Requirements (to deploy the image)

* [MAAS](https://maas.io) 3.2+
* [Curtin](https://launchpad.net/curtin) 21.0+
* [A Custom Preseed for Debian and PVE (Important - See below)]

## Supported Debian & PVE Versions

The builds and deployment has been tested on MAAS 3.3.5 with Jammy ephemeral images,
in BIOS and UEFI modes. The process currently works with the following Debian series:

* Debian 10 (Buster)
* Debian 11 (Bullseye)
* Debian 12 (Bookworm)
* Debian 13 (Trixie)
* Proxmox VE 9 (Based on Trixie) - Built on Ubuntu 22.04, deployed in UEFI mode with MAAS 3.7.4
  (resolute ephemeral) on bare metal, with a MAAS defined `vmbr0` bridge.

## Supported Architectures

Currently amd64 (x86_64) and arm64 (aarch64) architectures are supported with amd64
being the default for Debian. Proxmox VE is x86_64 only.

## Known Issues

* UEFI images from Debian 10 (Buster) and 11 (Bullseye) are usable on both BIOS and 
UEFI systems. However for Debian 12 (Bookworm) explicit images are required to
support BIOS and UEFI modes. See BOOT make parameter for more details.
* PVE images get their `vmbr0` bridge from MAAS: create it on the node before
deploying, see [Deploying the PVE image](#deploying-the-pve-image).

## debian-cloudimg.pkr.hcl

This template builds a tgz image from the official Debian cloud images. This
results in an image that is very close to the ones that are on
<https://images.maas.io/>.

### Building the Debian image

The build the image you give the template a script which has all the
customizations:

```shell
packer init .
packer build -var customize_script=my-changes.sh -var debian_series=bookworm \
    -var debian_version=12 .
```

`my-changes.sh` is a script you write which customizes the image from within
the VM. For example, you can install packages using `apt-get`, call out to
ansible, or whatever you want.

Using make:

```shell
make debian SERIES=bookworm
```

### Building the Proxmox VE 9 image

`pve.sh` turns the Debian 13 (Trixie) cloud image into Proxmox VE 9. Using make:

```shell
make pve    # pve9-custom-cloudimg.tar.gz
```

Or directly with packer (add `-var ovmf_suffix=_4M` on Ubuntu 24.04+):

```shell
packer init .
packer build -var customize_script=pve.sh -var kernel=proxmox-default-kernel \
    -var debian_series=trixie -var debian_version=13 -var disk_size=8G \
    -var filename=pve9-custom-cloudimg.tar.gz .
```

`pve.sh` follows the official "Install Proxmox VE on Debian" procedure and:

- adds the `pve-no-subscription` repository and the Proxmox archive key,
- installs `proxmox-default-kernel proxmox-ve postfix open-iscsi chrony ifupdown2`
  (postfix as "Local only"),
- purges the Debian kernels and os-prober,
- disables the enterprise repositories,
- lets root log in over SSH with the MAAS user's keys (no password),
- leaves ifupdown2 as the only network stack (disables systemd-networkd and
  systemd-resolved, removes the build VM's netplan config),
- makes cloud-init render the MAAS network configuration for ifupdown2 and
  stop managing `/etc/hosts`,
- installs the `pve-maas-interfaces` and `pve-maas-network` first boot
  services, see below,
- wipes the cluster database generated during the build, so that every
  deployed node gets its own root CA, certificates and authkey.

#### First boot services

Both run once, on the first boot after deployment.

`pve-maas-interfaces` runs after cloud-init wrote the MAAS network
configuration and before networking starts. cloud-init can only write it to
`/etc/network/interfaces.d/50-cloud-init`, which Proxmox VE neither sources nor
shows in its GUI, so the service moves it into `/etc/network/interfaces` and
disables cloud-init's network configuration: from then on the network belongs
to PVE.

`pve-cluster` only starts if the hostname resolves to a non-loopback address,
and Proxmox VE expects a static `/etc/resolv.conf`. Since the node's final
address is only known once the MAAS network configuration is applied,
`pve-maas-network` runs after the network is up and before `pve-cluster`, and:

- writes `/etc/resolv.conf` from the `dns-nameservers`/`dns-search` MAAS put
  in `/etc/network/interfaces`,
- maps the hostname (and FQDN, from the first search domain) to the address of
  the default route (IPv4, then IPv6, then the first global address),
- updates postfix's hostname accordingly.

Both are implemented by `/usr/local/sbin/pve-maas-network`, their logs are
available with `journalctl -u pve-maas-interfaces -u pve-maas-network`.

#### Uploading the PVE image

```shell
maas ${LOGIN} boot-resources create name='custom/pve9' title='Proxmox VE 9' \
    architecture='amd64/generic' base_image='ubuntu/resolute' filetype='tgz' \
    content@=pve9-custom-cloudimg.tar.gz
```

`base_image` must be an OS MAAS knows: use the Ubuntu series of your
commissioning/ephemeral image. MAAS checks the deployment kernel against it,
so a base older than `default_min_hwe_kernel` makes the deployment fail with
`<series> has no kernels available which meet min_hwe_kernel(...)`. It does not
change what is installed.

#### curtin_userdata for PVE

MAAS picks the preseed matching the boot resource,
`curtin_userdata_<os>_<arch>_<subarch>_<release>`, so with the command above
(`custom`, `amd64/generic`, `pve9`) copy the provided
`curtin_userdata_custom_amd64_generic_pve9` to
`/var/snap/maas/current/preseeds/` (snap) or `/etc/maas/preseeds/` (deb).
Adapt the file name if you use another boot resource name.

#### Deploying the PVE image

Proxmox VE guests need a bridge. Rather than converting the network after
deployment, let MAAS configure it: on the machine's *Network* tab create a
bridge named `vmbr0` on the interface to use, with the subnet and IP mode you
want, then deploy. With the CLI:

```shell
maas ${LOGIN} interfaces create-bridge ${SYSTEM_ID} name=vmbr0 parent=${IFACE_ID}
maas ${LOGIN} interface link-subnet ${SYSTEM_ID} vmbr0 subnet=${SUBNET} mode=auto
```

No user-data is needed: the image lets `root` log in over SSH with the SSH keys
of the MAAS user deploying the machine (SSH password authentication is
disabled). Root has no password, set one to use the web interface (PAM
realm), which is then available at `https://<node IP>:8006`:

```shell
ssh root@<node IP> passwd
```

#### Accessing external files from your script

If you want to put or use some files in the image, you can put those in the `http` directory.

Whatever file you put there, you can access from within your script like this:

```shell
wget http://${PACKER_HTTP_IP}:${PACKER_HTTP_PORT}:/my-file
```

### Installing a kernel for Debian

If you do want to force an image to always use a specific kernel, you can
include it in the image.

The easiest way of doing this is to use the `kernel` parameter:

```shell
packer init .
packer build -var kernel=linux-image-amd64 -var customize_script=my-changes.sh .
```

You can also install the kernel manually in your `my-changes.sh` script.

### Custom Preseed for Debian

As mentioned above, Debian images require a custom preseed file to be present in the
preseeds directory of MAAS region controllers. 

When used snaps, the path is /var/snap/maas/current/preseeds/curtin_userdata_custom

Example ready to use preesed files has been included with this repository. Please
see curtin_userdata_custom_amd64 and curtin_userdata_custom_arm64.

**Please be aware** this could potentially create a conflict with the rest of custom
images present in your setup. To work around a conflict, it is possible to rename the
preseed file something similar to curtin_userdata_custom_amd64_generic_debian-10 assuming
the architecture was set to amd64/generic and the uploaded **name** was set to custom/debian-10.

In other words, depending on the image name parameter used during the import, the preseed
file(s) can be renamed to apply in a targetted manner.

For more information about the preseed file naming schema, see
[Custom node setup (Preseed)](https://github.com/CanonicalLtd/maas-docs/blob/master/en/nodes-custom.md) and
[Preseed filenames](https://github.com/canonical/maas/blob/master/src/maasserver/preseed.py#L756).

### Makefile Parameters

#### PACKER_LOG

Enable (1) or Disable (0) verbose packer logs. The default value is set to 0.

#### SERIES

Specify the Debian Series to build. The default value is set to Bookworm (12).

#### BOOT

Supported boot mode baked into the image. The default is set to uefi. Please
see the Known Issues section for more details. This parameter is only valid 
for amd64 architecture.

#### ARCH

Target image architecture. Supported values are amd64 (default) and arm64.

#### TIMEOUT

The timeout to apply when building the image. The default value is set to 1h.

### Default Username

The default username is ```debian```

## Uploading images to MAAS

TGZ image

```shell
maas $PROFILE boot-resources create \
    name='custom/debian-12' \
    title='Debian 12 Custom' \
    architecture='amd64/generic' \
    filetype='tgz' \
    content@=debian-custom-cloudimg.tar.gz
```
