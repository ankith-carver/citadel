#!/usr/bin/env bash
# Interactive installer for citadel. Run as root on the NixOS live ISO,
# AFTER getting online (nmtui / nmcli — see docs/install.md step 3):
#
#   sudo -i
#   nix-shell -p git --run 'git clone https://github.com/ankith-carver/citadel.git /root/citadel'
#   /root/citadel/scripts/install.sh
#
# It asks for every machine-specific value up front (disk, SSH key, WiFi,
# Slack webhook), then partitions, installs, and applies the answers where
# they belong. Every destructive step is confirmed. Replaces docs/install.md
# steps 5–7; the manual commands there remain as reference.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "run as root (sudo -i first)"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode — disable CSM in BIOS (docs/install.md step 1)"
[ -e /etc/NIXOS ] || die "this doesn't look like a NixOS live ISO"
say "Checking network (needed to download packages)..."
ping -c 1 -W 5 cache.nixos.org >/dev/null 2>&1 \
  || die "no internet — connect first: nmtui (or nmcli device wifi connect ...)"
echo "network ok"

# ── Questions, all up front ──────────────────────────────────────────────
say "1/5 Target disk"
lsblk -d -o NAME,SIZE,MODEL
printf '\n'
read -r -p "Disk to WIPE and install to [/dev/nvme0n1]: " DISK
DISK="${DISK:-/dev/nvme0n1}"
[ -b "$DISK" ] || die "$DISK is not a block device"
# nvme0n1 -> partitions nvme0n1p1/p2; sda -> sda1/sda2
case "$DISK" in *nvme*|*mmcblk*) P="p" ;; *) P="" ;; esac

say "2/5 SSH public key (for user ankith; key-only SSH)"
echo "On your laptop: cat ~/.ssh/id_ed25519.pub — paste the whole line here."
read -r -p "public key: " SSH_KEY
case "$SSH_KEY" in
  ssh-*|sk-*) : ;;
  *) die "that doesn't look like a public key (must start with ssh- or sk-)" ;;
esac

say "3/5 WiFi"
read -r -p "Will this machine use WiFi? [y/N]: " WIFI_YN
WIFI_SSID="" WIFI_PSK=""
if [ "${WIFI_YN,,}" = "y" ]; then
  read -r -p "SSID (network name, exact & case-sensitive): " WIFI_SSID
  [ -n "$WIFI_SSID" ] || die "empty SSID"
  case "$WIFI_SSID" in *['#&|"']*) die "SSIDs with #, &, | or \" need manual setup (docs/install.md step 6)" ;; esac
  while :; do
    read -r -s -p "WiFi password (typing is hidden): " WIFI_PSK;  printf '\n'
    read -r -s -p "Retype it: " WIFI_PSK2; printf '\n'
    [ "$WIFI_PSK" = "$WIFI_PSK2" ] && break
    echo "didn't match, try again"
  done
fi

say "4/5 Slack webhook for alerts (optional)"
echo "Setup steps in nixos/modules/alerts.nix header. Enter to skip (add later"
echo "on the host: /etc/nixos/slack-webhook; no rebuild needed)."
read -r -p "webhook URL or Enter: " SLACK_URL

say "5/5 Summary — LAST CHANCE before the disk is wiped"
echo "  disk      : $DISK  (ALL DATA DESTROYED)"
echo "  ssh key   : ${SSH_KEY:0:20}...${SSH_KEY: -15}"
echo "  wifi      : ${WIFI_SSID:-no (ethernet)}"
echo "  slack     : ${SLACK_URL:-skipped}"
read -r -p "Type WIPE to proceed: " CONFIRM
[ "$CONFIRM" = "WIPE" ] || die "aborted, nothing touched"

# ── Partition & mount (docs/install.md step 5) ───────────────────────────
say "Partitioning $DISK (GPT: 1G ESP + ext4 root)..."
umount -R /mnt 2>/dev/null || true
parted -s "$DISK" -- mklabel gpt
parted -s "$DISK" -- mkpart ESP fat32 1MiB 1GiB
parted -s "$DISK" -- set 1 esp on
parted -s "$DISK" -- mkpart root ext4 1GiB 100%
udevadm settle
mkfs.fat -F 32 -n BOOT "${DISK}${P}1"
mkfs.ext4 -F -L nixos "${DISK}${P}2"
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=0077 /dev/disk/by-label/BOOT /mnt/boot

# ── Configuration (docs/install.md step 6) ───────────────────────────────
say "Generating hardware config + installing repo config..."
nixos-generate-config --root /mnt
cp -r "$REPO_DIR/nixos/modules" /mnt/etc/nixos/modules
cp "$REPO_DIR/nixos/configuration.nix" /mnt/etc/nixos/configuration.nix

# SSH key -> base.nix ('#' is safe as sed delimiter: never in base64/comments)
sed -i "s#\"ssh-ed25519 CHANGEME-paste-your-public-key ankith@laptop\"#\"${SSH_KEY}\"#" \
  /mnt/etc/nixos/modules/base.nix
grep -qF "$SSH_KEY" /mnt/etc/nixos/modules/base.nix || die "failed to insert SSH key"

if [ -n "$WIFI_SSID" ]; then
  # set SSID, switch the module on, write the machine-only password file
  sed -i "s#\"CHANGEME-ssid\"#\"${WIFI_SSID}\"#" /mnt/etc/nixos/modules/wifi.nix
  sed -i "s|# \./modules/wifi.nix|./modules/wifi.nix|" /mnt/etc/nixos/configuration.nix
  (umask 077; printf 'home_psk=%s\n' "$WIFI_PSK" > /mnt/etc/nixos/wifi.secrets)
  grep -Eq '^[[:space:]]*\./modules/wifi.nix' /mnt/etc/nixos/configuration.nix \
    || die "failed to enable wifi module"
fi

if [ -n "$SLACK_URL" ]; then
  (umask 077; printf '%s\n' "$SLACK_URL" > /mnt/etc/nixos/slack-webhook)
fi

# the gate that must hold: no placeholders in what we're about to install.
# Comment lines are ignored (only real values count as placeholders), and
# wifi.nix is exempt when wifi is off — the module isn't imported then.
if [ -n "$WIFI_SSID" ]; then
  LEFT=$(grep -rn CHANGEME /mnt/etc/nixos | grep -vE ':[0-9]+:[[:space:]]*#' || true)
else
  LEFT=$(grep -rn CHANGEME /mnt/etc/nixos --exclude=wifi.nix | grep -vE ':[0-9]+:[[:space:]]*#' || true)
fi
[ -z "$LEFT" ] || die "unfilled placeholders remain:
$LEFT"

# ── Install (docs/install.md step 7) ─────────────────────────────────────
say "Running nixos-install (downloads happen here — few minutes)..."
nixos-install --root /mnt --no-root-passwd

say "Set the password for 'ankith' (console + sudo, never SSH):"
nixos-enter --root /mnt -c 'passwd ankith'

say "Done. Next:"
echo "  1. remove the USB stick"
echo "  2. reboot"
echo "  3. from your laptop:  ssh ankith@<this machine's IP>"
echo "  4. continue docs/install.md step 8 (tailscale up, sensors, virsh, ...)"
read -r -p "Reboot now? [y/N]: " RB
[ "${RB,,}" = "y" ] && reboot
