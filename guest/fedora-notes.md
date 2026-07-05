# Fedora guest setup checklist

Everything to do inside `work-vm` after the interactive Fedora Workstation
install. Work through it top to bottom; each item says how to verify itself.

## During install (Anaconda)

- [ ] **Enable full-disk encryption** when picking storage — check "Encrypt
      my data". Fedora's default layout (btrfs on top of LUKS2) is exactly
      what we want. Pick a strong passphrase; you'll type it at the SPICE
      console after every host reboot.
- [ ] Username `ankith`.
- [ ] Keep the defaults otherwise. **SELinux stays on** — never disable it to
      "fix" something; fix the label instead (`ausearch -m avc -ts recent`).

## First boot

### 1. Update and reboot once

```bash
sudo dnf upgrade --refresh -y && sudo systemctl reboot
```

### 2. Guest agent + SPICE agent

Usually preinstalled on Workstation; make sure:

```bash
sudo dnf install -y qemu-guest-agent spice-vdagent
sudo systemctl enable --now qemu-guest-agent
```

Verify from the HOST: `virsh qemu-agent-command work-vm '{"execute":"guest-ping"}'`
→ `{"return":{}}`. This is what lets snapshots quiesce and `virsh shutdown`
work cleanly.

### 3. LUKS discard passthrough

The virtual disk already passes discard through (`discard=unmap`); LUKS
guest-side blocks it by default. Allow it so `fstrim` can shrink the qcow2:

```bash
# find the LUKS UUID
sudo blkid -t TYPE=crypto_LUKS
# add discard to /etc/crypttab (4th column), e.g.:
#   luks-<uuid> UUID=<uuid> none discard
sudo vi /etc/crypttab
# rebuild the initramfs so early boot picks it up
sudo dracut -f
```

After the next reboot, verify: `sudo fstrim -av` reports trimmed bytes, and
`lsblk -D` shows nonzero DISC-GRAN on the dm-crypt device. (fstrim.timer is
enabled by default on Fedora — weekly trim is automatic.)

> Security note: discard on LUKS leaks *which* blocks are free, not their
> contents. Acceptable for this threat model; the win is the qcow2 not
> growing monotonically.

### 4. Tailscale (guest's own, independent of the host's)

```bash
sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up   # authenticate interactively; no keys in the repo
```

Verify: the VM shows up in the tailnet under its own name; `tailscale ip -4`.

### 5. GNOME RDP (primary remote access)

GNOME's built-in RDP, reached over the **guest's** tailscale address. Enable
the user-session sharing via Settings → System → Remote Desktop → Desktop
Sharing (set it to require a password), or headlessly:

```bash
grdctl rdp set-credentials  # prompts for the RDP username/password to require
grdctl rdp enable
systemctl --user enable --now gnome-remote-desktop
```

Also enable **Remote Login** (Settings → System → Remote Desktop → Remote
Login) so RDP works at the GDM login screen, not just inside your session.

Firewall: `sudo firewall-cmd --add-service=rdp --permanent && sudo firewall-cmd --reload`.
That's safe because the only route to the guest is NAT + tailscale anyway.

Verify from the laptop with any RDP client (Windows App / Remmina /
FreeRDP): `work-vm.<tailnet>.ts.net:3389`.

Caveat to remember: RDP needs the session running — right after a host
reboot the VM sits at the LUKS prompt, where only SPICE (fallback) works.

### 6. Serial console (last resort access)

Make `virsh console work-vm` actually show something:

```bash
sudo grubby --update-kernel=ALL --args="console=tty0 console=ttyS0,115200n8"
sudo systemctl enable --now serial-getty@ttyS0.service
sudo systemctl reboot
```

Verify from the HOST: `virsh console work-vm` → login prompt (exit with
`Ctrl+]`). **Do this before declaring the build done** — it's the access
path that still works when graphics and networking don't.

### 7. Quality-of-life for a VM desktop

```bash
# never auto-suspend — it's a VM, "suspend" just means "confusingly gone"
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
# no lock-screen fade-to-blank surprises during long builds (optional)
gsettings set org.gnome.desktop.session idle-delay 0
```

### 8. Your actual work environment

Docker, IDEs, company tooling — all guest-side, per company docs. Nothing on
the host, ever.

## Ongoing habits

- **Weekly**: `sudo dnf upgrade --refresh` inside the guest. Before kernel or
  big upgrades, snapshot from the host first: `scripts/snapshot.sh pre-dnf`
  (see docs/operations.md).
- SELinux stays enforcing. `getenforce` should always say `Enforcing`.
- After confirming an upgrade is good for a few days, merge the snapshot back
  with `scripts/snapshot-commit.sh` so overlays don't pile up.
