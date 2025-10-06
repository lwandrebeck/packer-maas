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
* [A Custom Preseed for Debian and PVE8 (Important - See below)]

## Supported Debian & PVE Versions

The builds and deployment has been tested on MAAS 3.3.5 with Jammy ephemeral images,
in BIOS and UEFI modes. The process currently works with the following Debian series:

* Debian 10 (Buster)
* Debian 11 (Bullseye)
* Debian 12 (Bookworm)
* Debian 13 (Trixie)
* Proxmox VE 8 (Based on Bookworm) - Build tested on 24.04 with MAAS 3.5.4 only.
* Proxmox VE 9 (Based on Trixie) - Build tested on 24.04 with MAAS 3.6.1 only.

## Supported Architectures

Currently amd64 (x86_64) and arm64 (aarch64) architectures are supported with amd64
being the default for Debian. Proxmox VE is x86_64 only.

## Known Issues

* UEFI images from Debian 10 (Buster) and 11 (Bullseye) are usable on both BIOS and 
UEFI systems. However for Debian 12 (Bookworm) explicit images are required to
support BIOS and UEFI modes. See BOOT make parameter for more details.
* PVE8 does not come with network bridge preconfigured.
* PVE8 with proxmox-kernel-6.11 is untested as of now.
* PVE9 does not come with network bridge preconfigured.

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

### Building the PVE8 image
Use the pve8.sh script so it turns Bookworm into PVE8 with 6.8 kernel.

ovmf_suffix is defined here so building image works when using 24.04.
```shell
packer init .
packer build -var kernel=proxmox-default-kernel -var customize_script=pve8.sh \
    -var debian_series=bookworm -var debian_version=12 -var ovmf_suffix=_4M .
```
Use the opt-in 6.11 kernel instead (untested but should work)
```shell
packer init .
packer build -var kernel=proxmox-kernel-6.11 -var customize_script=pve8.sh \
    -var debian_series=bookworm -var debian_version=12 -var ovmf_suffix=_4M .
```
#### pve8.sh customization script
- adds no-subscription repository
- adds proxmox pgp key
- upgrades system
- removes debian kernel and os-prober
- installs proxmox-default-kernel proxmox-ve postfix open-iscsi chrony
- comments out pve-enterprise repo (or apt will complain)
- updates grub

### Building the PVE9 image
Use the pve9.sh script so it turns Trixie into PVE9 with 6.14 kernel.

ovmf_suffix is defined here so building image works when using 24.04.
```shell
packer init .
packer build -var kernel=proxmox-default-kernel -var customize_script=pve9.sh \
    -var debian_series=trixie -var debian_version=13 -var ovmf_suffix=_4M .
```
#### pve9.sh customization script
- adds no-subscription repository
- adds proxmox pgp key
- apt modernize-sources to migrate pre-existing repositories.
- upgrades system
- removes debian kernel and os-prober
- installs proxmox-default-kernel proxmox-ve postfix open-iscsi chrony
- comments out pve-enterprise repo (or apt will complain)
- updates grub

#### Uploading the PVE image
```shell
sudo maas ${LOGIN} boot-resources create name='custom/pve8' title='PVE8' \
architecture='amd64/generic' filetype='tgz' content@=debian-custom-cloudimg.tar.gz -k
```

#### curtin_userdata file naming
In order to get PVE properly configured when deploying, one must have a properly
named `curtin_userdata_` file for PVE.

file naming is:
- custom due to `name='custom…'`
- amd64 due to `architecture='amd64'`
- generic due to `architecture='…/generic'`
- pve8 due to `name='…/pve8'`
So be **sure** to have a file named
`/var/snap/maas/current/preseeds/curtin_userdata_custom_amd64_generic_pve8` if
using MAAS Snap and using the same `boot-resources create` command as above, adapt
otherwise.

this does one particular important thing under the hood:
- Link the ipv4 and hostname given by MAAS in /etc/hosts so services start properly. That’s not
perfect and will *very* likely break if you have several links UP, defined bonds, are ipv6 only… (late_8)
Any enhancement on that point is welcome.

#### Deploying PVE8 image
You’ll need to check Cloud-init user-data and use the following script:
```yaml
#cloud-config
chpasswd:
  list: |
     root:CHANGE_ME
     cloud-user:CHANGE_ME
  expire: False
manage_etc_hosts: False
```
Once that done you should have a properly running PVE8 machine, and be able to
log in with root account on https://MAAS_provided_IP:8006

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
