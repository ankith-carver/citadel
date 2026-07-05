# Install runbook — bare metal to working appliance

From an empty machine to: NixOS host on Tailscale, `work-vm` created, LUKS
set up, serial console verified. Every command is copy-pasteable. Steps 2–5
are done over SSH from your laptop.

**Before starting** — fill every placeholder (`grep -rn CHANGEME .` in this
repo must return nothing, except `scripts/backup.sh` which is a known stub):

- [ ] SSH public key in `nixos/modules/base.nix`
- [ ] Slack incoming webhook created for your alerts channel (setup steps in
      the header of `nixos/modules/alerts.nix`) — the URL goes on the machine
      during install, never in the repo
- [ ] Repo pushed somewhere reachable from the new machine (or be ready to
      copy it over the LAN)

## 1. BIOS prep

Enter UEFI setup (usually `Del` at power-on):

1. **Enable SVM** (AMD virtualization; often under Advanced → CPU
   Configuration). Without it KVM does not exist.
2. **Disable CSM** — pure UEFI boot; systemd-boot doesn't do legacy BIOS.
3. **Restore on AC Power Loss = Power On** — the machine is headless in a
   corner; after a power cut it must come back without a human.
4. While you're in there: Secure Boot off (stock NixOS doesn't sign its
   bootloader).

## 2. Boot the installer, get SSH in

1. Flash the **minimal** NixOS 26.05 ISO from <https://nixos.org/download/>
   to a USB stick and boot it.
2. On the console, give the live user a password so SSH allows you in:

   ```
   passwd
   ip a        # note the LAN IP, e.g. 192.168.1.50
   ```

   *If the machine is WiFi-only* (wire it if you can — see
   `nixos/modules/wifi.nix` for why), get the installer online first:

   ```
   sudo systemctl start wpa_supplicant
   wpa_cli
   > add_network
   > set_network 0 ssid "your-ssid"
   > set_network 0 psk "your-password"
   > enable_network 0
   > quit
   ```

3. From the laptop:

   ```
   ssh nixos@192.168.1.50
   sudo -i
   ```

## 3. Partition and mount

GPT, 1 GiB ESP, rest ext4, everything referenced by label (so the config
never hardcodes a device path).

```bash
DISK=/dev/nvme0n1        # <- adjust if your disk differs (lsblk to check)

parted "$DISK" -- mklabel gpt
parted "$DISK" -- mkpart ESP fat32 1MiB 1GiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- mkpart root ext4 1GiB 100%

mkfs.fat -F 32 -n BOOT "${DISK}p1"
mkfs.ext4 -L nixos "${DISK}p2"

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=0077 /dev/disk/by-label/BOOT /mnt/boot
```

## 4. Configure and install

```bash
# generate hardware-configuration.nix (keep) + a default configuration.nix (replace)
nixos-generate-config --root /mnt

# fetch this repo (git is on the minimal ISO via nix-shell)
nix-shell -p git --run "git clone https://CHANGEME-your-repo-url /mnt/root/citadel"

# replace the generated configuration with ours; keep the generated hardware config
cp -r /mnt/root/citadel/nixos/modules /mnt/etc/nixos/modules
cp /mnt/root/citadel/nixos/configuration.nix /mnt/etc/nixos/configuration.nix

# sanity check: your real SSH key must be in there
grep -rn CHANGEME /mnt/etc/nixos && echo "STOP - fix placeholders" || echo ok

# put the Slack webhook URL on the machine (secret — lives here, not in git)
# so the very first boot can post its "host booted" message:
sh -c 'umask 077; echo "https://hooks.slack.com/services/T00/B00/CHANGEME" > /mnt/etc/nixos/slack-webhook'
```

*WiFi-only machines: do this BEFORE nixos-install*, or the first boot comes
up with no network and you're on the physical console:

```bash
# 1. uncomment ./modules/wifi.nix in /mnt/etc/nixos/configuration.nix
#    and set your SSID in /mnt/etc/nixos/modules/wifi.nix
# 2. create the secrets file on the machine (never in git):
sh -c 'umask 077; echo "home_psk=YOUR-WIFI-PASSWORD" > /mnt/etc/nixos/wifi.secrets'
```

```bash
nixos-install --no-root-passwd

# set ankith's password (console + sudo use it; SSH never does)
nixos-enter --root /mnt -c 'passwd ankith'

reboot
```

Pull the USB stick out while it reboots.

## 5. First boot

SSH in as `ankith` (key auth) at the same LAN IP, then:

```bash
# 1. join the tailnet (interactive browser auth; no keys stored anywhere)
sudo tailscale up
tailscale ip -4          # note it; from now on use this instead of the LAN IP

# 2. detect motherboard sensors; if it suggests modules (e.g. nct6775),
#    add them to nixos/modules/monitoring.nix later
sudo sensors-detect --auto
sensors

# 3. libvirt is alive and empty
virsh list --all

# 4. the "host booted" message should already be in your Slack channel —
#    if not, check the webhook file and the service log:
systemctl status alert-boot

# 5. make the machine's repo clone your working one and wire the remote
git clone https://CHANGEME-your-repo-url ~/citadel
```

From here on, config changes = edit in the repo → `./scripts/bootstrap.sh`
(it syncs to /etc/nixos and enforces test-before-switch).

## 6. Create the guest

```bash
# fetch the Fedora Workstation ISO onto the host
cd /var/lib/libvirt/images
sudo curl -LO https://download.fedoraproject.org/pub/fedora/linux/releases/42/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-42-1.1.iso  # check for current version

~/citadel/guest/create-vm.sh /var/lib/libvirt/images/Fedora-Workstation-Live-x86_64-42-1.1.iso
```

From the **laptop**, open the installer console:

```bash
virt-viewer --connect qemu+ssh://ankith@citadel/system work-vm
```

Walk the Fedora installer. The one thing that matters: **enable full-disk
encryption** at the storage step. Then work through every checkbox in
[guest/fedora-notes.md](../guest/fedora-notes.md).

## 7. Verify before declaring the build done

All of these must pass:

```bash
# serial console reaches the guest (the everything-is-broken access path)
virsh console work-vm        # login prompt appears; exit with Ctrl+]

# guest agent responds
virsh qemu-agent-command work-vm '{"execute":"guest-ping"}'

# both tailscale layers are up independently
tailscale status | grep -E 'citadel|work-vm'

# RDP from the laptop to the guest's tailscale name works
# SPICE fallback works: virt-viewer --connect qemu+ssh://ankith@citadel/system work-vm

# reboot drill: reboot the host, wait for "host booted" in Slack,
# then run the unlock flow in docs/operations.md end to end
sudo reboot
```

When the reboot drill works from your phone/laptop without touching the
physical machine, the appliance is done.
