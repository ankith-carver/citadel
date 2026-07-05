# Install runbook — bare metal to working appliance

From an empty machine to: NixOS host on Tailscale, `work-vm` created, LUKS
set up, serial console verified. Every command is copy-pasteable. Steps 4–8
are done over SSH from your laptop; you only need the physical console for
BIOS setup and the first minutes of the installer.

## 0. Before you start

**You need:**

- [ ] A USB stick (≥ 2 GB, will be wiped)
- [ ] Ethernet to the machine if at all possible; otherwise the WiFi
      SSID + password (WiFi steps are marked throughout)
- [ ] A laptop on the same network
- [ ] A Slack incoming webhook URL for the alerts channel (setup steps in
      the header of `nixos/modules/alerts.nix`)

**Fill every placeholder** — `grep -rn CHANGEME .` in this repo must return
nothing except `scripts/backup.sh` (a known stub) and, if you're not using
WiFi, `nixos/modules/wifi.nix` (not imported by default):

- [ ] Your SSH public key in `nixos/modules/base.nix` (`cat ~/.ssh/id_ed25519.pub`
      on the laptop; `ssh-keygen -t ed25519` first if you don't have one)
- [ ] Repo pushed somewhere reachable, or be ready to copy it over the LAN
- [ ] WiFi-only: your SSID in `nixos/modules/wifi.nix` and the module
      import uncommented in `nixos/configuration.nix`

## 1. BIOS prep

Enter UEFI setup (usually `Del` at power-on):

1. **Enable SVM** (AMD virtualization; often under Advanced → CPU
   Configuration). Without it KVM does not exist.
2. **Disable CSM** — pure UEFI boot; systemd-boot doesn't do legacy BIOS.
3. **Restore on AC Power Loss = Power On** — the machine is headless in a
   corner; after a power cut it must come back without a human.
4. **Secure Boot off** — stock NixOS doesn't sign its bootloader.

## 2. Flash the installer USB (on the Mac)

```bash
# download the minimal 26.05 ISO (~1 GB)
curl -LO https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso

# find the USB stick's disk number — READ THE SIZES, picking wrong erases a real disk
diskutil list

# assuming it's /dev/disk4:
diskutil unmountDisk /dev/disk4
sudo dd if=latest-nixos-minimal-x86_64-linux.iso of=/dev/rdisk4 bs=4m status=progress
diskutil eject /dev/disk4
```

(`rdisk` instead of `disk` is just the faster raw device; on Linux the
equivalent is `sudo dd if=….iso of=/dev/sdX bs=4M status=progress conv=fsync`.)

## 3. Boot the installer and get it online

Plug the USB into the machine, power on, pick the USB from the boot menu
(often `F8`/`F11`). You land in a shell as the `nixos` user.

**Ethernet:** you're already online (DHCP happens automatically). Skip ahead.

**WiFi only:** the installer runs **NetworkManager** — use it and nothing
else:

```bash
nmcli device wifi connect "your-ssid" password "your-password"
```

**Prefer a UI?** `nmtui` is a full menu interface that works on the plain
console (this is the path that was actually used to build this machine):

1. Run `nmtui`
2. Arrow keys → **Activate a connection** → Enter
3. Pick your SSID from the list → Enter
4. Type the WiFi password → OK
5. The list shows a `*` next to the connected network → **Back** → **Quit**

**Do NOT touch wpa_supplicant/wpa_cli directly on the ISO.** A wpa_supplicant
unit is visibly running, but it's NetworkManager's D-Bus-managed backend: it
has no control socket (`wpa_cli` fails with `could not connect: (nil)`), a
hand-started second supplicant collides with it (`Match already configured`),
and killing it just makes NM respawn it. That path is hours of pain that
`nmcli` replaces with one command. (Reference: NixOS manual,
"Networking in the installer".)

If `nmcli` reports no WiFi device at all: check
`dmesg | grep -iE 'wifi|wlan|firmware'` for missing firmware and try
`sudo rfkill unblock all`.

Wait a few seconds, then verify (works for either connection type):

```bash
ip a                     # note the machine's LAN IP, e.g. 192.168.1.50
ping -c 2 nixos.org      # internet works
```

## 4. SSH in from the laptop

The live session's `nixos` user has no password, and SSH refuses logins for
passwordless accounts — so give it a throwaway one. On the machine's console:

```
[nixos@nixos:~]$ sudo passwd nixos
New password:              <- type a throwaway password; nothing echoes while you type
Retype new password:       <- same again
passwd: password updated successfully
```

Anything goes — it protects a RAM-only session on your LAN for an hour and
evaporates on reboot. It is NOT related to any password of the installed
system (those come in step 7).

Get the machine's IP if you don't already have it:

```bash
ip a show wlp13s0 | grep 'inet '     # or your ethernet interface
```

From the laptop (password = the one you just set):

```bash
ssh nixos@192.168.1.50
sudo -i
```

Everything from here on happens in this root shell. Two sanity checks
before touching the disk:

```bash
# 1. we really booted UEFI (if this fails, CSM is still on — back to step 1)
[ -d /sys/firmware/efi ] && echo "UEFI ok" || echo "STOP: legacy BIOS boot"

# 2. the target disk is what we think it is
lsblk -o NAME,SIZE,MODEL
```

## 5. Partition and mount

GPT, 1 GiB ESP, rest ext4, everything referenced by label (so the config
never hardcodes a device path). No swap partition by design: 64 GB RAM, and
the appliance workload is one VM with a fixed 48 GB — if that math ever
stops working, the answer is config, not swap.

**This erases the disk.** Adjust `DISK` if yours differs.

```bash
DISK=/dev/nvme0n1

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

## 6. Bring in the configuration

```bash
# generate hardware-configuration.nix (we keep) + a default configuration.nix (we replace)
nixos-generate-config --root /mnt

# fetch this repo (git isn't on the minimal ISO; nix-shell gets it ephemerally)
nix-shell -p git --run "git clone https://CHANGEME-your-repo-url /mnt/root/citadel"

# replace the generated configuration with ours; keep the generated hardware config
cp -r /mnt/root/citadel/nixos/modules /mnt/etc/nixos/modules
cp /mnt/root/citadel/nixos/configuration.nix /mnt/etc/nixos/configuration.nix

# sanity check: your real SSH key must be in there
grep -rn CHANGEME /mnt/etc/nixos && echo "STOP - fix placeholders" || echo ok
```

Now the two machine-only secrets, so the first boot comes up connected and
talking (these live in `/etc/nixos/` on the machine, never in git):

```bash
# Slack webhook — lets the very first boot post "host booted"
sh -c 'umask 077; echo "https://hooks.slack.com/services/T…/B…/…" > /mnt/etc/nixos/slack-webhook'

# WiFi only — without this the first boot has no network and you're back
# on the physical console:
sh -c 'umask 077; echo "home_psk=YOUR-WIFI-PASSWORD" > /mnt/etc/nixos/wifi.secrets'
# (and confirm the wifi.nix import really is uncommented:)
grep wifi /mnt/etc/nixos/configuration.nix
```

## 7. Install

```bash
nixos-install --no-root-passwd
```

This builds the full system from the config (takes a few minutes —
downloads happen here), installs systemd-boot into the ESP, and wires the
`nixos` channel to 26.05 (inherited from the ISO). `--no-root-passwd`
because root has no password on this machine: SSH root login is disabled in
`ssh.nix`, and physical/sudo access goes through `ankith`.

```bash
# set ankith's password — used for sudo and the physical console, never SSH
nixos-enter --root /mnt -c 'passwd ankith'

reboot
```

Pull the USB out while it reboots (or just leave it — the ESP outranks it
in boot order; don't lose the stick either way).

## 8. First boot

The "host booted" message should appear in your Slack channel within a
minute of boot — that's alerting verified before you've even logged in.
Then SSH in as `ankith` (key auth) at the same LAN IP:

```bash
ssh ankith@192.168.1.50
```

Work down this list:

```bash
# 0. basics look right
hostname                      # citadel
[ -d /sys/firmware/efi ] && echo UEFI
sudo nix-channel --list       # nixos https://channels.nixos.org/nixos-26.05
# WiFi-only: confirm which link carries you
networkctl                    # wlan0 'routable', or your ethernet if wired

# 1. join the tailnet (interactive browser auth; no keys stored anywhere)
sudo tailscale up
tailscale ip -4               # note it; from now on prefer this over the LAN IP

# 2. detect motherboard sensors; if it suggests modules (e.g. nct6775),
#    add them to nixos/modules/monitoring.nix later rather than /etc answers
sudo sensors-detect --auto
sensors

# 3. libvirt is alive and empty
virsh list --all

# 4. if the Slack boot message never arrived, debug it now, not later:
systemctl status alert-boot
sudo cat /etc/nixos/slack-webhook   # typo'd URL is the usual culprit

# 5. make the machine's repo clone your working one
git clone https://CHANGEME-your-repo-url ~/citadel
```

From here on, config changes = edit in the repo → `./scripts/bootstrap.sh`
(it syncs to /etc/nixos and enforces test-before-switch — see
[operations.md](operations.md)).

## 9. Create the guest

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
[guest/fedora-notes.md](../guest/fedora-notes.md) — guest agent, LUKS
discard, the guest's own tailscale, GNOME RDP, serial console.

## 10. Verify before declaring the build done

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
