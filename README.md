# kvm-host-iso

Builds a Debian netinst ISO that installs a KVM host with minimal input. You only enter:

- the username and password (in the installer);
- the system disk (in the installer);
- the disk for VM images (on the console after the first boot).

Everything else is configured automatically:

- LVM on the whole system disk;
- SSH, sudo, full upgrade, time zone Europe/Kyiv;
- KVM, libvirt, Cockpit;
- the images disk formatted as ext4 (label `vmstore`) and mounted by UUID at `/var/lib/libvirt/images`;
- libvirt storage pool `default`;
- Debian netinst ISO for new VMs;
- login on serial port `ttyS0` (`serial-getty@ttyS0`);
- bridge `br0` under NetworkManager with the NIC's MAC and a MAC-based DHCP Client ID.

## Build the ISO

On any Debian/Ubuntu machine or in WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
```

The script installs `xorriso`, `cpio` and `wget` if they are missing, asks for the hostname and domain, downloads the current Debian netinst, verifies its SHA256 and writes `~/kvm-iso/<hostname>-debian-<version>-amd64-netinst.iso`.

From a clone, the hostname and domain can be passed as arguments:

```bash
git clone https://github.com/pavlobilan/kvm-host-iso.git
cd kvm-host-iso
./build-iso.sh kvm01 example.com
```

## Install

1. Attach the ISO to the VM as a CD, or write it to a USB stick (Rufus: DD mode, or `dd`).
2. Boot from it and choose **Install** or **Graphical install**.
3. Enter the username and the password twice, then select the system disk. Installation continues unattended until the "Installation complete" screen; press **Continue** and the server powers off.
4. Detach the ISO (or change the boot order) and power the server on.

## First boot

The setup runs on the server console (tty1), not over SSH.

1. Select the disk for VM images. The system disk is not listed.
2. If the disk already has a `vmstore` partition, choose **Yes** to keep its data or **No** to erase it.
3. Confirm erasing the disk.
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
