# kvm-host-iso

Builds a Debian ISO that installs a KVM host with minimal input.

Run on any Debian/Ubuntu machine or in WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
```

The ISO is saved to the shared folder `/srv/kvm-iso`:

```
/srv/kvm-iso/debian-<version>-<hostname>.iso
```

For example, `/srv/kvm-iso/debian-13.7.0-kvm01.iso`. All users can read it (e.g. download it with WinSCP), and the user who ran the command owns it, also when run with `sudo -i`. The last line of the output, `Done: ...`, shows the full path.

## What it does

During installation you only enter:

- the username and password (in the installer);
- the system disk (in the installer);
- whether to encrypt the disks (in the installer, default **No**) and, if yes, the passphrases;
- the disk for VM images (on the console after the first boot).

Everything else is configured automatically:

- LVM on the whole system disk (encrypted LVM if chosen);
- SSH, sudo, full upgrade, time zone Europe/Kyiv;
- KVM, libvirt, Cockpit;
- the images disk formatted as ext4 (label `vmstore`) and mounted by UUID at `/var/lib/libvirt/images`;
- libvirt storage pool `default`;
- Debian netinst ISO for new VMs;
- login on serial port `ttyS0` (`serial-getty@ttyS0`);
- bridge `br0` under NetworkManager with the NIC's MAC and a MAC-based DHCP Client ID.

## Build details

The script installs `xorriso`, `cpio` and `wget` if they are missing, creates `/srv/kvm-iso` (with `sudo` the first time), asks for the hostname and domain, downloads the current Debian netinst, verifies its SHA256 and builds the ISO.

| File | Location |
| --- | --- |
| Built ISO | `/srv/kvm-iso/debian-<version>-<hostname>.iso` |
| Original Debian netinst (kept for the next build) | `/srv/kvm-iso/debian-<version>-amd64-netinst.iso` |

To use another folder, set `OUTDIR`, e.g. `curl ... | OUTDIR=/data/iso bash`.

```bash
# List the built ISO files
ls -lh /srv/kvm-iso/*.iso
```

In WSL, open the folder in Windows Explorer at `\\wsl$\<distribution>\srv\kvm-iso`, or copy the ISO to Windows:

```bash
# Copy the ISO to the Windows Downloads folder (replace <WINUSER> with the folder name in C:\Users)
cp /srv/kvm-iso/debian-<version>-<hostname>.iso /mnt/c/Users/<WINUSER>/Downloads/
```

From a clone, the hostname and domain can be passed as arguments:

```bash
git clone https://github.com/pavlobilan/kvm-host-iso.git
cd kvm-host-iso
./build-iso.sh kvm01 example.com
```

## Install

1. Attach the ISO to the VM as a CD, or write it to a USB stick (Rufus: DD mode, or `dd`).
2. Boot from it and press Enter: **Install** is preselected. The menu waits without a timeout, so a disk left attached does not start a new installation.
3. Enter the username and the password twice, answer the encryption question (Enter keeps **No**), then select the system disk. With encryption, the installer also asks for the disk passphrase. Installation continues unattended until the "Installation complete" screen; press **Finish** and the server powers off.
4. Power the server on. The installer ejects the CD at the end; remove a USB stick if you used one.

## First boot

The setup runs on the server console (tty1), not over SSH.

1. Select the disk for VM images. The system disk is not listed.
2. If the disk already has a `vmstore` partition, choose **Yes** to keep its data or **No** to erase it.
3. Confirm erasing the disk. If the system disk is encrypted, enter a passphrase for the images disk: it is unlocked at boot by a key file on the system disk, and the passphrase is needed only to keep its data after a reinstall.
4. Wait for the Debian ISO for VMs to download.
5. The final screen shows the MAC address. Reserve an IP for this MAC on the router and clear the Client ID field there.
6. Press **OK**. The server reboots and gets the reserved IP on `br0`.

If the setup was cancelled, run it again with `sudo kvm-setup`.

## Check

```bash
# Images directory is on the selected disk
findmnt /var/lib/libvirt/images

# Pool "default" is active and autostarted
sudo virsh pool-list --all

# br0 has the reserved IP
ip -br a show br0
```

Then open `https://<server-IP>:9090`, log in and turn on administrative access.

## Files

| File | Purpose |
| --- | --- |
| `build-iso.sh` | Builds the ISO: embeds `preseed.cfg` into the installer initrd and adds the first-boot files |
| `preseed.cfg` | Installer answers |
| `kvm-setup.sh` | First-boot setup, installed as `/usr/local/sbin/kvm-setup` |
| `kvm-setup.service` | Runs `kvm-setup` once on tty1 |
| `finish.templates` | Title, text and button of the last installer screen |
| `encrypt.templates` | Installer question whether to encrypt the disks |
