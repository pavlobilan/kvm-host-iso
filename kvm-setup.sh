#!/bin/bash
# First-boot setup of a KVM host after the unattended Debian installation.
# Runs once on tty1 (kvm-setup.service) or manually: sudo kvm-setup
set -euo pipefail

IMAGES=/var/lib/libvirt/images
DONE=/var/lib/kvm-setup.done
VM_ISO_URL=https://cdimage.debian.org/cdimage/archive/latest-oldstable/amd64/iso-cd/
TITLE="KVM host setup"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
[ -e "$DONE" ] && { echo "Setup already completed ($DONE)."; exit 0; }

# First regular user created by the installer
ADMIN=$(getent passwd 1000 | cut -d: -f1)

# System disk, so it is not offered for images
ROOT_DISK=$(lsblk -rsno NAME,TYPE "$(findmnt -no SOURCE /)" | awk '$2=="disk"{print "/dev/"$1; exit}')

# Other disks to choose from
MENU=()
while read -r name size type; do
  [ "$type" = disk ] && [ "$name" != "$ROOT_DISK" ] || continue
  info="$(lsblk -dno MODEL "$name" | xargs) $(lsblk -dno SERIAL "$name" | xargs)"
  MENU+=("$name" "$size $info")
done < <(lsblk -dpno NAME,SIZE,TYPE)

if [ ${#MENU[@]} -eq 0 ]; then
  whiptail --title "$TITLE" --msgbox "No disk found besides the system disk $ROOT_DISK." 8 70
  exit 1
fi

DISK=$(whiptail --title "$TITLE" --menu "Select the disk for VM images (system disk: $ROOT_DISK)" 20 78 10 \
  "${MENU[@]}" 3>&1 1>&2 2>&3) || { echo "Cancelled. Run again: sudo kvm-setup"; exit 1; }

# Encrypt the images disk only when the system disk is encrypted: its key file is stored there
ENCRYPT=no
lsblk -rsno TYPE "$(findmnt -no SOURCE /)" | grep -qx crypt && ENCRYPT=yes
KEYFILE=/etc/cryptsetup-keys.d/vmstore.key

# Ask for a new passphrase twice (recovery key of the encrypted images disk)
ask_new_passphrase() {
  local p2
  while true; do
    PASS=$(whiptail --title "$TITLE" --passwordbox "Passphrase for the VM images disk.\nIt is needed only to keep the data after a reinstall.\n\nPassphrase (8+ characters):" 12 70 3>&1 1>&2 2>&3) || return 1
    if [ ${#PASS} -lt 8 ]; then
      whiptail --title "$TITLE" --msgbox "The passphrase must be at least 8 characters." 8 60; continue
    fi
    p2=$(whiptail --title "$TITLE" --passwordbox "Enter the passphrase again:" 10 70 3>&1 1>&2 2>&3) || return 1
    [ "$PASS" = "$p2" ] && return 0
    whiptail --title "$TITLE" --msgbox "The passphrases do not match." 8 60
  done
}

# Look for an existing vmstore partition (ext4 or LUKS), to optionally keep images after a reinstall
PART=""; PTYPE=""
for p in $(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}'); do
  if [ "$(blkid -s LABEL -o value "$p" || true)" = vmstore ]; then
    PART=$p; PTYPE=$(blkid -s TYPE -o value "$p" || true); break
  fi
done

KEEP=no
if [ -n "$PART" ]; then
  if [ "$PTYPE" = crypto_LUKS ] && [ "$ENCRYPT" = no ]; then
    whiptail --title "$TITLE" --msgbox "Found encrypted vmstore partition $PART, but the system disk is not encrypted, so it cannot be unlocked at boot.\n\nThe disk can only be erased." 12 70
  elif whiptail --title "$TITLE" --yesno \
    "Found existing vmstore partition $PART.\n\nKeep its data?\n(No = erase the whole disk)" 12 70; then
    KEEP=yes
  fi
fi

if [ "$KEEP" = no ]; then
  whiptail --title "$TITLE" --defaultno --yesno "ALL DATA on $DISK will be erased.\n\nContinue?" 10 70 \
    || { echo "Cancelled. Run again: sudo kvm-setup"; exit 1; }
  if [ "$ENCRYPT" = yes ]; then
    ask_new_passphrase || { echo "Cancelled. Run again: sudo kvm-setup"; exit 1; }
  fi
  # Wipe old signatures (VMFS etc.) and create GPT with one partition
  wipefs -a "$DISK"
  parted -s "$DISK" mklabel gpt mkpart vmstore ext4 0% 100%
  udevadm settle
  PART=$(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1; exit}')
  wipefs -a "$PART"
  if [ "$ENCRYPT" = yes ]; then
    printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --label vmstore --batch-mode --key-file=- "$PART"
    PTYPE=crypto_LUKS
  else
    mkfs.ext4 -F -L vmstore "$PART"
    PTYPE=ext4
  fi
elif [ "$PTYPE" = crypto_LUKS ]; then
  # Existing encrypted partition: its passphrase is needed to add the new key file
  while true; do
    PASS=$(whiptail --title "$TITLE" --passwordbox "Passphrase of the existing VM images disk $PART:" 10 70 3>&1 1>&2 2>&3) \
      || { echo "Cancelled. Run again: sudo kvm-setup"; exit 1; }
    printf '%s' "$PASS" | cryptsetup open --test-passphrase --key-file=- "$PART" && break
    whiptail --title "$TITLE" --msgbox "Wrong passphrase." 8 50
  done
fi

if [ "$PTYPE" = crypto_LUKS ]; then
  # Key file on the encrypted system disk unlocks the images disk at boot without a second passphrase
  if [ ! -s "$KEYFILE" ]; then
    install -d -m 700 /etc/cryptsetup-keys.d
    (umask 077; head -c 64 /dev/urandom > "$KEYFILE")
  fi
  cryptsetup open --test-passphrase --key-file "$KEYFILE" "$PART" 2>/dev/null \
    || printf '%s' "$PASS" | cryptsetup luksAddKey --key-file=- "$PART" "$KEYFILE"
  unset PASS
  grep -q '^vmstore ' /etc/crypttab 2>/dev/null \
    || echo "vmstore UUID=$(cryptsetup luksUUID "$PART") $KEYFILE luks,discard" >> /etc/crypttab
  [ -e /dev/mapper/vmstore ] || cryptsetup open --key-file "$KEYFILE" "$PART" vmstore
  [ "$KEEP" = yes ] || mkfs.ext4 -F -L vmstore /dev/mapper/vmstore
  FSDEV=/dev/mapper/vmstore
else
  # Mount by UUID, because sda/sdb names can change
  FSDEV="UUID=$(blkid -s UUID -o value "$PART")"
fi

mkdir -p "$IMAGES"
cp -n /etc/fstab /etc/fstab.bak
grep -q "^$FSDEV " /etc/fstab || echo "$FSDEV $IMAGES ext4 defaults 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$IMAGES" || mount "$IMAGES"

# libvirt access for the user and for Cockpit
usermod -aG libvirt "$ADMIN"
usermod -aG libvirt libvirtdbus

# Disable AppArmor for QEMU: a libvirt bug in Debian 13 makes it block deleting external snapshots
grep -q '^security_driver' /etc/libvirt/qemu.conf || echo 'security_driver = "none"' >> /etc/libvirt/qemu.conf
systemctl restart libvirtd

# Pool "default" in the images directory, autostarted
virsh pool-info default &>/dev/null || virsh pool-define-as default dir --target "$IMAGES"
virsh pool-autostart default
virsh pool-info default | grep -q 'State:.*running' || virsh pool-start default

# Download Debian netinst ISO for VMs and verify SHA256
echo "Downloading Debian netinst ISO for VMs..."
if (cd "$IMAGES" \
    && wget -q --show-progress -r -l1 -nd -np -A 'debian-*-amd64-netinst.iso' "$VM_ISO_URL" \
    && wget -qO- "${VM_ISO_URL}SHA256SUMS" | sha256sum -c --ignore-missing -); then
  virsh pool-refresh default
else
  echo "WARNING: ISO download or checksum check failed, download it later manually."
fi

# Network interface of the default route
IF=$(ip -o route show default | awk '{print $5; exit}')
MAC=$(cat "/sys/class/net/$IF/address")
IP=$(ip -4 -o addr show "$IF" | awk '{print $4; exit}')

# Hand the interface over from ifupdown to NetworkManager and create bridge br0 with its MAC
sed -i -e "s/^allow-hotplug $IF/#&/" -e "s/^auto $IF/#&/" -e "s/^iface $IF/#&/" /etc/network/interfaces
if ! nmcli -g NAME con show | grep -qx br0; then
  # Remove existing ethernet connections so they do not compete with the bridge port
  for c in $(nmcli -g UUID,TYPE con show | awk -F: '$2=="802-3-ethernet"{print $1}'); do
    nmcli con delete "$c"
  done
  nmcli con add type bridge ifname br0 con-name br0 bridge.stp no bridge.mac-address "$MAC" \
    ipv4.method auto ipv4.dhcp-client-id mac ipv6.method ignore
  nmcli con add type bridge-slave ifname "$IF" master br0 con-name "br0-$IF"
fi

touch "$DONE"
systemctl disable kvm-setup.service 2>/dev/null || true

whiptail --title "$TITLE" --msgbox "Setup complete.\n\n\
Reserve an IP on the router for MAC $MAC and clear the Client ID field.\n\
IP before reboot: ${IP:-unknown}\n\n\
After reboot open https://<server-IP>:9090 and turn on administrative access.\n\n\
Press OK to reboot." 16 76
reboot
