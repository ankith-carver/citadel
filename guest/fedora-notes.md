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

### 4. Hostname, THEN Tailscale (guest's own, independent of the host's)

Set the hostname first — installs from the live ISO inherit `localhost-live`,
and your tailnet device name and RDP address come from the hostname at the
moment you run `tailscale up` (hit on the real build: the VM joined the
tailnet as `localhost-live`):

```bash
sudo hostnamectl set-hostname work-vm

sudo dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up   # authenticate interactively; no keys in the repo
```

Verify: the VM shows up in the tailnet as `work-vm`; `tailscale ip -4`.
(Joined under the wrong name already? `sudo tailscale set --hostname work-vm`.)

### 5. GNOME RDP (primary remote access)

GNOME's built-in RDP, reached over the **guest's** tailscale address.
**Use the Settings UI, not grdctl** — the UI generates the required TLS
certificate automatically; the CLI does not and fails cryptically
(`RDP server certificate is invalid`). In the desktop:

1. **Settings → System → Remote Desktop → Desktop Sharing**: toggle ON
2. **Remote Control: ON** (otherwise you can see but not click — the
   view-only default bit us on the real build)
3. **Login Details**: username `ankith` + a NEW random password from your
   password manager. This RDP credential is separate from the account
   password by design (different doors, different keys); you save it once in
   the laptop's RDP client and never type it again.

Then open the firewall — **this is the step that actually blocks
connections when skipped** (Fedora's high-port default masks it in `nc`
tests, but the RDP handshake fails):

```bash
sudo firewall-cmd --add-service=rdp --permanent && sudo firewall-cmd --reload
```

Verify from the laptop with any RDP client (Windows App / Remmina /
FreeRDP): `work-vm.<tailnet>.ts.net:3389`, or the `tailscale ip -4` address.
Accept the self-signed-certificate warning once.

**Remote Login** (the adjacent Settings tab) serves the GDM *login screen*
over RDP — needed only if you DON'T use auto-login (§5b). With auto-login
on, Desktop Sharing always has a session to attach to; skip Remote Login.

Caveat to remember: no RDP until the guest is past the LUKS prompt — that
early phase belongs to the VNC/serial console.

Headless/scripted fallback (must generate the cert yourself, and mind
view-only):

```bash
mkdir -p ~/.local/share/gnome-remote-desktop
openssl req -new -newkey rsa:4096 -days 720 -nodes -x509 -subj /CN=work-vm \
  -out ~/.local/share/gnome-remote-desktop/rdp-tls.crt \
  -keyout ~/.local/share/gnome-remote-desktop/rdp-tls.key
grdctl rdp set-tls-cert ~/.local/share/gnome-remote-desktop/rdp-tls.crt
grdctl rdp set-tls-key  ~/.local/share/gnome-remote-desktop/rdp-tls.key
grdctl rdp set-credentials
grdctl rdp disable-view-only
grdctl rdp enable
systemctl --user enable --now gnome-remote-desktop
```

### 5b. Auto-login + keyring (one secret per boot)

Optional but recommended for this setup: after the LUKS passphrase, go
straight to the desktop.

1. **Settings → System → Users → Unlock → Automatic Login: ON**
2. **Blank the login keyring — REQUIRED once auto-login is on**, or RDP
   breaks on every reboot: gnome-remote-desktop stores its credentials in
   the keyring, auto-login leaves the keyring locked (nobody typed the
   account password), and the service logs
   `Credentials are not set, denying client` (hit on the real build).
   Fix: **Passwords and Keys** app → right-click **Login** → Change
   Password → old = account password, new = **empty** → confirm.
3. Optional, same spirit: Settings → Privacy & Security → Screen Lock →
   Automatic Screen Lock OFF.

Security note: the keyring's at-rest protection is redundant here — it
lives inside the LUKS disk, and unlike macOS's Keychain, GNOME's keyring
does no per-item/per-app mediation anyway (any process in your session can
read an unlocked keyring). Real secrets deserve their own encryption
(password-manager CLI, age, ssh-agent), not the login keyring.

The account password still exists and is still needed for `sudo`.

### 6. Serial console (last resort access)

Make `virsh console work-vm` actually show something:

```bash
sudo grubby --update-kernel=ALL --args="console=tty0 console=ttyS0,115200n8"
sudo systemctl enable --now serial-getty@ttyS0.service
sudo systemctl reboot
```

Verify from the HOST: `virsh console work-vm` → press Enter → login prompt
(exit with `Ctrl+]`). Careful: "Connected to domain" appears even when the
guest side is NOT configured — that's just the host attaching to the cable.
A blank console that ignores Enter means these steps haven't taken effect;
a login prompt is the pass condition. **Do this before declaring the build
done** — it's the access path that still works when graphics and networking
don't, and it makes the reboot ritual pure SSH: `virsh start work-vm` →
`virsh console work-vm` → LUKS passphrase appears here during boot → type
it → `Ctrl+]` → RDP.

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
