#!/bin/bash
# Build an automatic KVM host ISO: the installer asks only the hostname, domain, user, password and
# whether to encrypt; the disks are given as options.
# Run with one command:
#   curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso-auto.sh | bash -s -- \
#     --system-disk /dev/sda --images-disk /dev/sdb
set -euo pipefail

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main}

usage() {
  cat <<'EOF'
Usage: build-iso-auto.sh --system-disk DEV --images-disk DEV [options]

Required:
  --system-disk DEV    Disk for Debian, e.g. /dev/sda (ERASED without confirmation)
  --images-disk DEV    Disk for VM images, e.g. /dev/sdb (ERASED without confirmation)

Optional:
  --keep-images        Keep an existing vmstore partition on the images disk instead of erasing it
  -h, --help           Show this help

The installer asks the hostname, domain, user name, password and whether to encrypt the disks.
EOF
}

SYSDISK=""; IMGDISK=""; KEEP=no
while [ $# -gt 0 ]; do
  case $1 in
    --system-disk) SYSDISK=${2:-}; shift 2 ;;
    --images-disk) IMGDISK=${2:-}; shift 2 ;;
    --keep-images) KEEP=yes; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Validate the options before anything is downloaded
fail() { echo "Error: $*" >&2; exit 1; }
[ -n "$SYSDISK" ] && [ -n "$IMGDISK" ] || { usage >&2; fail "--system-disk and --images-disk are required"; }
[[ $SYSDISK =~ ^/dev/[A-Za-z0-9/_:.-]+$ ]] || fail "invalid system disk: $SYSDISK"
[[ $IMGDISK =~ ^/dev/[A-Za-z0-9/_:.-]+$ ]] || fail "invalid images disk: $IMGDISK"
[ "$SYSDISK" != "$IMGDISK" ] || fail "the system disk and the images disk must differ"

export REPO_RAW KVM_AUTO=yes
export KVM_SYSTEM_DISK=$SYSDISK KVM_IMAGES_DISK=$IMGDISK KVM_KEEP_IMAGES=$KEEP

# Run the main build: from the clone next to this script, or downloaded
SELF=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/build-iso.sh" ]; then
  exec bash "$(dirname "$SELF")/build-iso.sh" </dev/null
else
  curl -fsSL "$REPO_RAW/build-iso.sh" | bash
fi
