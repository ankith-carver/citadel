# citadel

A personal **virtualization appliance**: a headless NixOS host whose only job
is to run a single KVM work VM. This repo is the source of truth for the whole
machine — NixOS configuration, guest provisioning, operational scripts, and
runbooks. When the host changes, the change lands here first.

## Philosophy

- **The host is an appliance.** SSH, Tailscale, libvirt/KVM, monitoring,
  alerting, backups. Nothing else — no desktop, no browsing, no dev work.
- **Everything real happens in the guest.** A Fedora Workstation VM
  (`work-vm`) with full-disk LUKS runs the desktop, IDEs, Docker, company
  tooling, documents.
- **Host is unencrypted, guest is encrypted.** The host holds nothing
  sensitive; the guest's LUKS passphrase is entered manually (via SPICE
  console) after every host boot.
- **Two independent escape hatches.** Tailscale runs in host *and* guest
  separately, so a failure in one layer doesn't lock you out of the other.
- **Boring tools.** `virsh` over SSH is the management plane. Alerting is a
  handful of systemd timers posting to a Slack channel. No custom APIs, no
  dashboards.

## Quick links

| I want to… | Go to |
|---|---|
| Install from scratch | [docs/install.md](docs/install.md) |
| Day-2 ops: unlock flow, rebuilds, snapshots, rollback | [docs/operations.md](docs/operations.md) |
| Recover from a dead SSD | [docs/recovery.md](docs/recovery.md) |
| Create the work VM | [guest/create-vm.sh](guest/create-vm.sh) |
| Set up the Fedora guest | [guest/fedora-notes.md](guest/fedora-notes.md) |

## Hardware

- AMD Ryzen 9 9900X (12c/24t), 64 GB RAM
- Single NVMe SSD (`/dev/nvme0n1` — adjust in [docs/install.md](docs/install.md) if different)
- iGPU only (stays with the host for emergency console; no passthrough)
- UEFI, TPM 2.0

## VM shape (decided; see guest/ for implementation)

- 10 vCPUs (`host-passthrough`), 48 GB fixed memory — no ballooning, no huge
  pages, no CPU pinning
- qcow2 on host ext4, virtio-scsi with `discard=unmap`
- virtio-gpu 2D only; UEFI + emulated TPM 2.0 (swtpm)
- Remote access: GNOME RDP over guest Tailscale (primary), SPICE via
  virt-viewer (fallback), `virsh console` (last resort)
- External snapshots only, merged back with blockcommit — see
  [scripts/](scripts/)

## Placeholders you MUST fill before installing

Everything secret or machine-specific is a clearly marked `CHANGEME`:

| Placeholder | Where |
|---|---|
| Your SSH public key | `nixos/modules/base.nix` |
| Slack webhook URL (secret — machine only) | `/etc/nixos/slack-webhook` on the host; setup in `nixos/modules/alerts.nix` header |
| Backup destination + tool | `scripts/backup.sh` (stub — undecided) |
| Target disk (if not `/dev/nvme0n1`) | `docs/install.md` partitioning step |
| WiFi SSID + secrets file (only if WiFi-only — prefer Ethernet) | `nixos/modules/wifi.nix` (opt-in import) + `/etc/nixos/wifi.secrets` on the machine |
| Fedora ISO path / guest disk size | `guest/create-vm.sh` (env vars) |

Tailscale is authenticated interactively (`tailscale up`) on host and guest —
no auth keys are stored anywhere in this repo.

`grep -rn CHANGEME .` should return nothing before you install.

## Repo layout

```
nixos/            NixOS config: configuration.nix + small single-purpose modules
guest/            work-vm creation script, reference domain XML, Fedora setup notes
scripts/          snapshot / blockcommit / backup stub / post-install bootstrap
docs/             install, operations, recovery runbooks
```

## v2 ideas (deliberately not in v1)

- Migrate from channels + `/etc/nixos` to flakes for exact nixpkgs pinning.
  v1 uses plain channels because it's simpler while learning Nix; the module
  layout won't need to change.
- Implement `scripts/backup.sh` once the destination (second disk / NAS / B2)
  is decided.
