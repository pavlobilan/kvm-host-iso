#!/bin/bash
# Build a Debian ISO for unattended installation of a KVM host.
# Run with one command:
#   curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
# Or from a clone of the repository: ./build-iso.sh [HOSTNAME] [DOMAIN]
# The ISO is written to /srv/kvm-iso (override with OUTDIR=...), readable by all users
# and owned by the user who runs the build, also under sudo.
set -euo pipefail

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main}
URL=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/
FILES=(preseed.cfg kvm-setup.sh kvm-setup.service finish.templates encrypt.templates)
OUTDIR=${OUTDIR:-/srv/kvm-iso}
OWNER=${SUDO_USER:-$(id -un)}
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
umask 022

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SRCDIR="$WORK/src"
mkdir -p "$SRCDIR"

# Repository files: from the clone next to the script, or downloaded when run via curl | bash
SELF=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ -f "$(dirname "$SELF")/preseed.cfg" ]; then
  for f in "${FILES[@]}"; do cp "$(dirname "$SELF")/$f" "$SRCDIR/"; done
  FETCH=no
else
  FETCH=yes
fi

# Install missing packages needed for the build
NEED=()
for c in xorriso cpio wget gzip; do command -v "$c" >/dev/null || NEED+=("$c"); done
if [ ${#NEED[@]} -gt 0 ]; then
  echo "Installing: ${NEED[*]}"
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${NEED[@]}"
fi

if [ "$FETCH" = yes ]; then
  for f in "${FILES[@]}"; do wget -q "$REPO_RAW/$f" -O "$SRCDIR/$f"; done
fi
# Strip Windows line endings in case the files were edited on Windows
for f in "${FILES[@]}"; do sed -i 's/\r$//' "$SRCDIR/$f"; done

# Shared output folder, owned by the user who runs the build
if [ ! -d "$OUTDIR" ] || [ ! -w "$OUTDIR" ]; then
  $SUDO install -d -m 755 -o "$OWNER" -g "$(id -gn "$OWNER")" "$OUTDIR"
fi
cd "$OUTDIR"

# Hostname and domain: from arguments or prompt (via /dev/tty, since stdin is the script under curl | bash)
HOST=${1:-}; DOMAIN=${2:-}
[ -n "$HOST" ]   || read -rp "Hostname [kvm01]: " HOST </dev/tty
[ -n "$DOMAIN" ] || read -rp "Domain [example.com]: " DOMAIN </dev/tty
HOST=${HOST:-kvm01}; DOMAIN=${DOMAIN:-example.com}
[[ $HOST =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "Invalid hostname: $HOST" >&2; exit 1; }
[[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid domain: $DOMAIN" >&2; exit 1; }

# Find the current netinst, download it and verify SHA256
SRC=$(wget -qO- "$URL" | grep -o 'debian-[0-9.]*-amd64-netinst\.iso' | head -n1)
[ -n "$SRC" ] || { echo "Could not find netinst at $URL" >&2; exit 1; }
[ -f "$SRC" ] || wget "$URL$SRC"
echo -n "Verifying original Debian image (SHA256)... "
wget -qO- "${URL}SHA256SUMS" | grep " $SRC\$" | sha256sum --quiet -c - || { echo "Checksum mismatch, delete $SRC and run again" >&2; exit 1; }
echo "OK"
OUT=${SRC%-amd64-netinst.iso}-$HOST.iso

# Files added to the installer initrd
EXTRA="$WORK/initrd-extra"
mkdir -p "$EXTRA/usr/lib/finish-install.d" "$EXTRA/usr/share/kvm-host-iso"
# preseed.cfg with the hostname and domain
sed -e "s/kvm01/$HOST/g" -e "s/example\.com/$DOMAIN/" "$SRCDIR/preseed.cfg" > "$EXTRA/preseed.cfg"
# Custom title, text and "Finish" button for the last screen, loaded just before 20final-message shows it
cp "$SRCDIR/finish.templates" "$EXTRA/usr/share/kvm-host-iso/finish.templates"
cat > "$EXTRA/usr/lib/finish-install.d/19kvm-final-message" <<'HOOK'
#!/bin/sh
. /usr/share/debconf/confmodule
db_x_loadtemplatefile /usr/share/kvm-host-iso/finish.templates d-i || true
db_settitle kvm-host-iso/title || true
HOOK
chmod 755 "$EXTRA/usr/lib/finish-install.d/19kvm-final-message"
# Encryption question: partman hook, copied to /lib/partman/init.d by preseed/early_command
cp "$SRCDIR/encrypt.templates" "$EXTRA/usr/share/kvm-host-iso/encrypt.templates"
cat > "$EXTRA/usr/share/kvm-host-iso/99kvm-encrypt" <<'HOOK'
#!/bin/sh
# Ask once (default No) and switch guided partitioning between LVM and encrypted LVM
. /usr/share/debconf/confmodule
db_x_loadtemplatefile /usr/share/kvm-host-iso/encrypt.templates kvm-host-iso || true
db_input critical kvm-host-iso/encrypt || true
db_go || true
db_get kvm-host-iso/encrypt
if [ "$RET" = true ]; then
  db_set partman-auto/method crypto
  db_set partman-auto/init_automatically_partition some_device_crypto
else
  db_set partman-auto/method lvm
  db_set partman-auto/init_automatically_partition some_device_lvm
fi
exit 0
HOOK

# Append the extra files to the initrd of the text and graphical installers
MAP=()
for i in install.amd/initrd.gz install.amd/gtk/initrd.gz; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null
  chmod u+w "$f"
  (cd "$EXTRA" && find . -mindepth 1 | cpio -o -H newc -R 0:0 --quiet | gzip) >> "$f"
  MAP+=(-map "$f" "/$i")
done

# Boot menus: start "Install" immediately without showing the menu
# and pass locale/keymap to the kernel, so the language and keyboard questions are answered before preseed.cfg is read
BOOTARGS="locale=en_US.UTF-8 keymap=us"
for i in boot/grub/grub.cfg isolinux/isolinux.cfg isolinux/txt.cfg isolinux/gtk.cfg; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null || continue
  chmod u+w "$f"
  case $i in
    boot/grub/grub.cfg)
      sed -i "s#\(/install.amd/vmlinuz\)#\1 $BOOTARGS#" "$f"
      printf '\nset timeout=0\nset timeout_style=hidden\nset default="Install"\n' >> "$f" ;;
    isolinux/isolinux.cfg)
      if grep -q '^timeout' "$f"; then sed -i 's/^timeout .*/timeout 1/' "$f"; else echo 'timeout 1' >> "$f"; fi ;;
    isolinux/txt.cfg|isolinux/gtk.cfg)
      sed -i "s#^\(\s*append \)#\1$BOOTARGS #" "$f"
      # Make text "Install" the default entry in the BIOS menu
      if [ "$i" = isolinux/gtk.cfg ]; then sed -i '/menu default/d' "$f"; else sed -i '/^label install$/a\	menu default' "$f"; fi ;;
  esac
  MAP+=(-map "$f" "/$i")
done

# Write the new ISO, keeping the original boot records
rm -f "$OUT"
xorriso -indev "$SRC" -outdev "$OUT" "${MAP[@]}" \
  -map "$SRCDIR/kvm-setup.sh" /kvm-setup.sh \
  -map "$SRCDIR/kvm-setup.service" /kvm-setup.service \
  -boot_image any replay 2>/dev/null

# Give the files to the user who runs the build (matters when run as root or via sudo)
if [ "$(id -u)" -eq 0 ]; then
  chown "$OWNER": "$OUTDIR" "$OUTDIR/$SRC" "$OUTDIR/$OUT"
fi
chmod 644 "$OUTDIR/$SRC" "$OUTDIR/$OUT"

# Final message: green check mark and text, then the path in white (colors only in a terminal)
if [ -t 1 ]; then G=$'\e[1;32m'; W=$'\e[1;37m'; N=$'\e[0m'; else G=; W=; N=; fi
echo
echo "${G}✓  The ISO image has been saved to the folder:${N}"
echo "   ${W}$OUTDIR/$OUT${N}"
echo
