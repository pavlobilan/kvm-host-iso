# kvm-host-iso

<!-- iso-link-start -->
**Latest ISO:** [debian-13.7.0-kvmhost-github-4.iso](https://github.com/pavlobilan/kvm-host-iso/releases/download/iso/debian-13.7.0-kvmhost-github-4.iso) ([SHA256SUMS](https://github.com/pavlobilan/kvm-host-iso/releases/download/iso/SHA256SUMS))
<!-- iso-link-end -->

The ISO is [rebuilt automatically](https://github.com/pavlobilan/kvm-host-iso/releases/latest) after every change of the scripts and weekly with the latest Debian stable release; the link above is updated with it. The file is named `debian-<version>-kvmhost-github-<build number>.iso`. Only the latest build is kept; check the download with `SHA256SUMS` from the same page.

Builds a Debian ISO that installs a KVM host.

## Build it yourself

Run on any Debian/Ubuntu machine or in WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
```

At the start the script asks the ISO file name; press Enter to keep the default `debian-<version>-kvmhost.iso`. A file with the same name is overwritten. The ISO is saved to the shared folder `/srv/kvm-iso`:

```
/srv/kvm-iso/debian-<version>-kvmhost.iso
```

Nothing else is asked during the build, so one ISO can be used for any number of servers.

## What is asked

In the installer:

- hostname (default `kvmhost`) and domain;
- user name and password (the user is added to the `sudo` group, root login is disabled);
- whether to encrypt the disks (default **No**) and, if yes, the passphrase;
- the system disk.

On the first boot:

- the disk for VM images, and a confirmation that it will be erased;
- with encryption, a passphrase for the images disk.

## What is configured automatically

- LVM on the whole system disk (encrypted LVM if chosen);
- SSH, sudo, full upgrade, time zone Europe/Kyiv;
- KVM, libvirt, Cockpit;
- the images disk formatted as ext4 (label `vmstore`) and mounted at `/var/lib/libvirt/images`;
- libvirt storage pool `default`;
- AppArmor for QEMU stays on; VMs may access all files in `/var/lib/libvirt/images`, so deleting external snapshots works;
- login on serial port `ttyS0`;
- boot progress shown on the console (systemd status lines);
- GRUB menu of the installed system shown for 2 s;
- bridge `br0` under NetworkManager with the NIC's MAC and a MAC-based DHCP Client ID;
- the Cockpit address with the IP and port on the console login screen.

## Install

1. Attach the ISO to the VM as a CD, or write it to a USB stick (Rufus: DD mode, or `dd`).
2. Boot from it and press Enter: the boot menu has only **Install**. It waits without a timeout, so a disk left attached does not start a new installation.
3. Answer the installer questions. The rest of the installation runs without questions; at the end the installer ejects the ISO and reboots the server. Remove a USB stick if you used one.
4. On the first boot, select the disk for VM images on the console (tty1) and confirm erasing it. If the disk already has a `vmstore` partition from a previous installation, you can keep its data instead.
5. The console shows the MAC and waits without a timeout. Reserve an IP for this MAC on the router and clear the Client ID field there (after the move to `br0` the server sends a new Client ID, and a reservation with the old one may leave it without an IP), then press Enter to reboot.
6. After the reboot the console login screen shows the Cockpit address and the same reminder, e.g. `Cockpit: https://192.0.2.10:9090`.
7. Open the Cockpit address, log in and turn on administrative access.

If the first-boot setup was cancelled, run it again with `sudo kvm-setup`.

With encryption, the images disk is unlocked at boot by a key file on the system disk; its passphrase is needed only to keep the data after a reinstall. The system disk passphrase is asked on every boot.

## Check

```bash
# Images directory is on the selected disk
findmnt /var/lib/libvirt/images

# Pool "default" is active and autostarted
sudo virsh pool-list --all

# br0 has the IP
ip -br a show br0
```

## Build details

The script installs `xorriso`, `cpio` and `wget` if they are missing, creates `/srv/kvm-iso` (with `sudo` the first time), downloads the current Debian netinst, verifies its SHA256 and builds the ISO. The folder and files are readable by all users and owned by the user who runs the build, also when run with `sudo -i`.

| File | Location |
| --- | --- |
| Built ISO | `/srv/kvm-iso/<name>.iso`, default `debian-<version>-kvmhost.iso` |
| Original Debian netinst (kept for the next build) | `/srv/kvm-iso/debian-<version>-amd64-netinst.iso` |

To use another folder, set `OUTDIR`, e.g. `curl ... | OUTDIR=/data/iso bash`.

In WSL, open the folder in Windows Explorer at `\\wsl$\<distribution>\srv\kvm-iso`, or copy the ISO to Windows:

```bash
# Copy the ISO to the Windows Downloads folder (replace <WINUSER> with the folder name in C:\Users)
cp /srv/kvm-iso/debian-<version>-kvmhost.iso /mnt/c/Users/<WINUSER>/Downloads/
```

From a clone:

```bash
git clone https://github.com/pavlobilan/kvm-host-iso.git
cd kvm-host-iso
./build-iso.sh            # asks the ISO file name
./build-iso.sh kvm-test   # writes /srv/kvm-iso/kvm-test.iso without asking
```

## Files

| File | Purpose |
| --- | --- |
| `build-iso.sh` | Builds the ISO: embeds `preseed.cfg` into the installer initrd and adds the first-boot files |
| `preseed.cfg` | Installer answers |
| `installer.templates` | Installer texts: whether to encrypt the disks, and which disk is the system disk |
| `kvm-setup.sh` | First-boot setup, installed as `/usr/local/sbin/kvm-setup` |
| `kvm-setup.service` | Runs `kvm-setup` once on tty1 |
