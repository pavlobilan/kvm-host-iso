#!/bin/bash
# Build a Debian ISO for unattended installation of a KVM host.
# Run with one command:
#   curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso.sh | bash
# Or from a clone of the repository: ./build-iso.sh [ISO_FILE_NAME]
# Only the ISO file name is asked during the build (Enter = default); the installer asks the hostname, domain, user, password,
# encryption and system disk, and the first boot asks the disk for VM images.
# The ISO is written to /srv/kvm-iso (override with OUTDIR=...), readable by all users
# and owned by the user who runs the build, also under sudo.
set -euo pipefail

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main}
URL=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/
FILES=(preseed.cfg kvm-setup.sh kvm-setup.service encrypt.templates)
OUTDIR=${OUTDIR:-/srv/kvm-iso}
OWNER=${SUDO_USER:-$(id -un)}
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
umask 022

# Name of the built ISO, asked first: argument, or prompt (Enter = default); ".iso" is added if missing
OUT=${1:-}
if [ -z "$OUT" ]; then
  # Ask on the terminal (stdin is the script itself under curl | bash); no terminal = default name
  if (exec </dev/tty) 2>/dev/null; then
    read -rp "ISO file name (press Enter for debian-<version>-kvmhost.iso): " OUT </dev/tty || OUT=""
  fi
fi
if [ -n "$OUT" ]; then
  case $OUT in *.iso) ;; *) OUT=$OUT.iso ;; esac
  [[ $OUT =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] || { echo "Invalid file name: $OUT (letters, digits, . _ -)" >&2; exit 1; }
fi

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
  echo "Downloading the build files from GitHub..."
  for f in "${FILES[@]}"; do wget -q "$REPO_RAW/$f" -O "$SRCDIR/$f"; done
fi
# Strip Windows line endings in case the files were edited on Windows
for f in "${FILES[@]}"; do sed -i 's/\r$//' "$SRCDIR/$f"; done

# Shared output folder, owned by the user who runs the build
if [ ! -d "$OUTDIR" ] || [ ! -w "$OUTDIR" ]; then
  $SUDO install -d -m 755 -o "$OWNER" -g "$(id -gn "$OWNER")" "$OUTDIR"
fi
cd "$OUTDIR"


# Find the current netinst, download it and verify SHA256
echo "Looking up the current Debian image on cdimage.debian.org..."
SRC=$(wget -qO- "$URL" | grep -o 'debian-[0-9.]*-amd64-netinst\.iso' | head -n1)
[ -n "$SRC" ] || { echo "Could not find netinst at $URL" >&2; exit 1; }

# Default name with the Debian version, if no name was given
OUT=${OUT:-${SRC%-amd64-netinst.iso}-kvmhost.iso}
[ "$OUT" != "$SRC" ] || { echo "The name must differ from the original image $SRC" >&2; exit 1; }

if [ -f "$SRC" ]; then
  echo "Using the already downloaded $SRC"
else
  echo "Downloading $SRC..."
  wget -q --show-progress "$URL$SRC"
fi
echo -n "Verifying original Debian image (SHA256)... "
wget -qO- "${URL}SHA256SUMS" | grep " $SRC\$" | sha256sum --quiet -c - || { echo "Checksum mismatch, delete $SRC and run again" >&2; exit 1; }
echo "OK"

MAP=()

echo "Preparing the installer files..."

# Files added to the installer initrd
EXTRA="$WORK/initrd-extra"
mkdir -p "$EXTRA/usr/share/kvm-host-iso"
cp "$SRCDIR/preseed.cfg" "$EXTRA/preseed.cfg"

# Encryption question: partman hook, copied to /lib/partman/init.d by preseed/early_command
cp "$SRCDIR/encrypt.templates" "$EXTRA/usr/share/kvm-host-iso/encrypt.templates"
cat > "$EXTRA/usr/share/kvm-host-iso/99kvm-encrypt" <<'HOOK'
#!/bin/sh
# Ask once (default No), or take the answer from encrypt.auto, and switch guided partitioning
# between LVM and encrypted LVM
. /usr/share/debconf/confmodule
if [ -f /usr/share/kvm-host-iso/encrypt.auto ]; then
  [ "$(cat /usr/share/kvm-host-iso/encrypt.auto)" = yes ] && RET=true || RET=false
else
  db_x_loadtemplatefile /usr/share/kvm-host-iso/encrypt.templates kvm-host-iso || true
  db_input critical kvm-host-iso/encrypt || true
  db_go || true
  db_get kvm-host-iso/encrypt
fi
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
for i in install.amd/initrd.gz install.amd/gtk/initrd.gz; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null
  chmod u+w "$f"
  (cd "$EXTRA" && find . -mindepth 1 | cpio -o -H newc -R 0:0 --quiet | gzip) >> "$f"
  MAP+=(-map "$f" "/$i")
done

# Boot menus: only the "Install" entry, waiting for Enter (no timeout),
# and locale/keymap passed to the kernel, so the language and keyboard questions are answered before preseed.cfg is read
BOOTARGS="locale=en_US.UTF-8 keymap=us"
for i in boot/grub/grub.cfg isolinux/isolinux.cfg isolinux/menu.cfg isolinux/txt.cfg; do
  f="$WORK/$(echo "$i" | tr / _)"
  xorriso -osirrox on -indev "$SRC" -extract "/$i" "$f" 2>/dev/null || continue
  chmod u+w "$f"
  case $i in
    boot/grub/grub.cfg)
      # UEFI: drop every top-level menuentry/submenu except 'Install' (brace depth tracks nested blocks)
      awk '
        skip { d += gsub(/{/, "{") - gsub(/}/, "}"); if (d <= 0) skip = 0; next }
        /^[[:space:]]*(menuentry|submenu)[[:space:]]/ && $0 !~ /'"'"'Install'"'"'/ {
          d = gsub(/{/, "{") - gsub(/}/, "}"); if (d > 0) skip = 1; next }
        { print }' "$f" > "$f.new" && mv "$f.new" "$f"
      sed -i "s#\(/install.amd/vmlinuz\)#\1 $BOOTARGS#" "$f"
      # Show a message while the kernel and the installer load (the screen is otherwise blank)
      sed -i "/^[[:space:]]*menuentry.*'Install'.*{/a\\    echo 'Loading the installer, please wait...'" "$f"
      printf '\nset timeout=-1\nset default="Install"\n' >> "$f" ;;
    isolinux/isolinux.cfg)
      # BIOS: no timeout (0 = wait for Enter)
      if grep -q '^timeout' "$f"; then sed -i 's/^timeout .*/timeout 0/' "$f"; else echo 'timeout 0' >> "$f"; fi ;;
    isolinux/menu.cfg)
      # BIOS: keep the menu settings and only the text installer (txt.cfg)
      awk '/^include stdmenu.cfg/ { print; print "include txt.cfg"; exit } { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
    isolinux/txt.cfg)
      sed -i "s#^\(\s*append \)#\1$BOOTARGS #" "$f"
      grep -q 'menu default' "$f" || sed -i '/^label install$/a\	menu default' "$f" ;;
  esac
  MAP+=(-map "$f" "/$i")
done

# Write the new ISO, keeping the original boot records
rm -f "$OUT"
[ -f "$OUT" ] && echo "$OUT already exists and will be overwritten."
echo "Building $OUT (about a minute)..."
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
