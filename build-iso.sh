#!/bin/bash
# Build a Debian ISO for unattended installation of a KVM host.
# Run with one command:
#   curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
# Or from a clone of the repository: ./build-iso.sh [HOSTNAME] [DOMAIN]
set -euo pipefail

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main}
URL=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/
FILES=(preseed.cfg kvm-setup.sh kvm-setup.service finish.templates)

# Work next to the script; when run via curl | bash, work in ~/kvm-iso
SELF=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ -f "$(dirname "$SELF")/preseed.cfg" ]; then
  cd "$(dirname "$SELF")"; FETCH=no
else
  mkdir -p ~/kvm-iso && cd ~/kvm-iso; FETCH=yes
fi

# Install missing packages needed for the build
NEED=()
for c in xorriso cpio wget gzip; do command -v "$c" >/dev/null || NEED+=("$c"); done
if [ ${#NEED[@]} -gt 0 ]; then
  echo "Installing: ${NEED[*]}"
  SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${NEED[@]}"
fi

# Download the latest repository files when run via curl | bash
if [ "$FETCH" = yes ]; then
  for f in "${FILES[@]}"; do wget -q "$REPO_RAW/$f" -O "$f"; done
fi
# Strip Windows line endings in case the files were edited on Windows
sed -i 's/\r$//' "${FILES[@]}"

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
OUT=$HOST-$SRC

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Files added to the installer initrd
EXTRA="$WORK/initrd-extra"
mkdir -p "$EXTRA/usr/lib/finish-install.d" "$EXTRA/usr/share/kvm-host-iso"
# preseed.cfg with the hostname and domain
sed -e "s/kvm01/$HOST/g" -e "s/example\.com/$DOMAIN/" preseed.cfg > "$EXTRA/preseed.cfg"
# Custom text for the "Installation complete" screen, loaded just before 20final-message shows it
cp finish.templates "$EXTRA/usr/share/kvm-host-iso/finish.templates"
cat > "$EXTRA/usr/lib/finish-install.d/19kvm-final-message" <<'HOOK'
#!/bin/sh
. /usr/share/debconf/confmodule
db_x_loadtemplatefile /usr/share/kvm-host-iso/finish.templates d-i || true
HOOK
chmod 755 "$EXTRA/usr/lib/finish-install.d/19kvm-final-message"

# Append the extra files to the initrd of the text and graphical installers
MAP=()
for i in install.amd/initrd.gz install.amd/gtk/initrd.gz; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null
  chmod u+w "$f"
  (cd "$EXTRA" && find . -mindepth 1 | cpio -o -H newc -R 0:0 --quiet | gzip) >> "$f"
  MAP+=(-map "$f" "/$i")
done

# Boot menus: preselect "Install" without a timeout (nothing starts if the disk is left attached)
# and pass locale/keymap to the kernel, so the language and keyboard questions are answered before preseed.cfg is read
BOOTARGS="locale=en_US.UTF-8 keymap=us"
for i in boot/grub/grub.cfg isolinux/isolinux.cfg isolinux/txt.cfg isolinux/gtk.cfg; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null || continue
  chmod u+w "$f"
  case $i in
    boot/grub/grub.cfg)
      sed -i "s#\(/install.amd/vmlinuz\)#\1 $BOOTARGS#" "$f"
      printf '\nset timeout=-1\nset default="Install"\n' >> "$f" ;;
    isolinux/isolinux.cfg)
      if grep -q '^timeout' "$f"; then sed -i 's/^timeout .*/timeout 0/' "$f"; else echo 'timeout 0' >> "$f"; fi ;;
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
  -map kvm-setup.sh /kvm-setup.sh \
  -map kvm-setup.service /kvm-setup.service \
  -boot_image any replay 2>/dev/null

echo
echo "Done: $(pwd)/$OUT"
