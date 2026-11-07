#!/bin/bash
# Build a fully automatic KVM host ISO: all answers are given as options, nothing is asked
# during installation except the boot menu Enter and, with encryption, the passphrases.
# Run with one command:
#   curl -fsSL https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main/build-iso-auto.sh | bash -s -- \
#     --hostname kvm01 --domain example.com --user admin --system-disk /dev/sda --images-disk /dev/sdb
# The password is asked once during the build and stored in the ISO only as a SHA-512 hash.
set -euo pipefail

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/pavlobilan/kvm-host-iso/main}

usage() {
  cat <<'EOF'
Usage: build-iso-auto.sh --hostname NAME --user NAME --system-disk DEV --images-disk DEV [options]

Required:
  --hostname NAME      Server hostname, e.g. kvm01
  --user NAME          Admin user (in the sudo group), e.g. admin
  --system-disk DEV    Disk for Debian, e.g. /dev/sda (ERASED without confirmation)
  --images-disk DEV    Disk for VM images, e.g. /dev/sdb (ERASED without confirmation)

Optional:
  --domain NAME        Domain, default: localdomain
  --encrypt yes|no     Encrypt both disks, default: no (passphrases are asked during installation)
  --keep-images        Keep an existing vmstore partition on the images disk instead of erasing it
  --password-stdin     Read the password from stdin instead of asking (for scripts)
  -h, --help           Show this help
EOF
}

HOST=""; DOMAIN=localdomain; USERNAME=""; SYSDISK=""; IMGDISK=""; ENCRYPT=no; KEEP=no; PWSTDIN=no
while [ $# -gt 0 ]; do
  case $1 in
    --hostname)       HOST=${2:-}; shift 2 ;;
    --domain)         DOMAIN=${2:-}; shift 2 ;;
    --user)           USERNAME=${2:-}; shift 2 ;;
    --system-disk)    SYSDISK=${2:-}; shift 2 ;;
    --images-disk)    IMGDISK=${2:-}; shift 2 ;;
    --encrypt)        ENCRYPT=${2:-}; shift 2 ;;
    --keep-images)    KEEP=yes; shift ;;
    --password-stdin) PWSTDIN=yes; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Validate the answers before anything is downloaded
fail() { echo "Error: $*" >&2; exit 1; }
[ -n "$HOST" ] && [ -n "$USERNAME" ] && [ -n "$SYSDISK" ] && [ -n "$IMGDISK" ] \
  || { usage >&2; fail "--hostname, --user, --system-disk and --images-disk are required"; }
[[ $HOST =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || fail "invalid hostname: $HOST"
[[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || fail "invalid domain: $DOMAIN"
[[ $USERNAME =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fail "invalid user name: $USERNAME (lowercase letters, digits, - and _)"
case $USERNAME in root|daemon|bin|sys|nobody) fail "reserved user name: $USERNAME" ;; esac
[[ $SYSDISK =~ ^/dev/[A-Za-z0-9/_:.-]+$ ]] || fail "invalid system disk: $SYSDISK"
[[ $IMGDISK =~ ^/dev/[A-Za-z0-9/_:.-]+$ ]] || fail "invalid images disk: $IMGDISK"
[ "$SYSDISK" != "$IMGDISK" ] || fail "the system disk and the images disk must differ"
[[ $ENCRYPT =~ ^(yes|no)$ ]] || fail "--encrypt must be yes or no"

# Password: asked twice on the terminal (not in the command line or shell history)
if [ "$PWSTDIN" = yes ]; then
  IFS= read -r PW || true
else
  while true; do
    read -rsp "Password for $USERNAME: " PW </dev/tty; echo >/dev/tty
    read -rsp "Password again: " PW2 </dev/tty; echo >/dev/tty
    [ "$PW" = "$PW2" ] && break
    echo "The passwords do not match." >/dev/tty
  done
fi
[ -n "$PW" ] || fail "the password must not be empty"

# Hash the password (SHA-512); install openssl if missing
if ! command -v openssl >/dev/null; then
  SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq openssl
fi
KVM_PASSHASH=$(printf '%s' "$PW" | openssl passwd -6 -stdin)
unset PW PW2

export REPO_RAW KVM_PASSHASH
export KVM_USER=$USERNAME KVM_SYSTEM_DISK=$SYSDISK KVM_IMAGES_DISK=$IMGDISK
export KVM_ENCRYPT=$ENCRYPT KVM_KEEP_IMAGES=$KEEP

# Run the main build: from the clone next to this script, or downloaded
SELF=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/build-iso.sh" ]; then
  exec bash "$(dirname "$SELF")/build-iso.sh" "$HOST" "$DOMAIN" </dev/null
else
  curl -fsSL "$REPO_RAW/build-iso.sh" | bash -s -- "$HOST" "$DOMAIN"
fi
