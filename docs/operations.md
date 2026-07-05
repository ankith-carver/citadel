# Operations — day-2 runbook

## The unlock flow (after every host boot)

The host boots unattended; the guest waits encrypted until you show up.
Expect the "host booted, VM awaiting unlock" ntfy, then:

```bash
# 1. host is reachable over tailscale (or LAN if you're home)
ssh ankith@citadel

# 2. start the VM — it boots to the LUKS passphrase prompt
virsh start work-vm

# 3. from the laptop, open the graphical console and type the passphrase
virt-viewer --connect qemu+ssh://ankith@citadel/system work-vm

# 4. once GNOME is up, switch to RDP (guest's tailscale name) and close SPICE
```

Notes:

- The "work-vm not running" ntfy warning fires if you leave it locked >10
  min. That's a reminder, not an incident.
- No RDP until the guest has booted past LUKS and (for session RDP) logged
  in — that's why the unlock goes through SPICE.

## Access ladder (when something is broken)

Try in order; each rung survives the failure of the one above:

1. **RDP** to guest tailscale name — normal work.
2. **SPICE**: `virt-viewer --connect qemu+ssh://ankith@citadel/system work-vm`
   — works when guest networking/tailscale is broken.
3. **Serial**: `ssh ankith@citadel` then `virsh console work-vm` — works when
   guest graphics are broken (exit with `Ctrl+]`).
4. **Host over LAN**: when host tailscale is down (you got the ntfy).
5. **Physical**: iGPU console in the corner of the room. The last rung.

## Safe rebuild discipline (host)

The host is remote-managed; a bad config that kills SSH or networking means a
walk to the machine. The discipline:

1. Edit config **in the repo**, commit.
2. `./scripts/bootstrap.sh` — it syncs to `/etc/nixos` and runs
   **`nixos-rebuild test` first**: activates the config *without* making it
   the boot default. If the machine wedges, a power cycle boots the previous
   generation. This is non-negotiable for remote changes.
3. Confirm you still have SSH (open a *second* session before risky changes;
   keep the first as a lifeline).
4. Only then let bootstrap.sh run `nixos-rebuild switch`.
5. **Never GC right after a change** (`nix-collect-garbage -d` deletes the
   old generations you'd roll back to). Automatic GC keeps 30 days
   (base.nix); let it do its job. Sit on changes for at least a few days
   before any manual GC.

### Upgrading NixOS (host)

```bash
# minor updates within the channel
sudo nix-channel --update && sudo nixos-rebuild test   # then switch

# release upgrades (e.g. 26.05 -> 26.11): read the release notes first,
# snapshot the guest (paranoia — host upgrades shouldn't touch it, but it
# costs nothing), then:
sudo nix-channel --add https://channels.nixos.org/nixos-26.11 nixos
sudo nix-channel --update && sudo nixos-rebuild test   # then switch
# system.stateVersion stays at 26.05 FOREVER. That's correct. Don't "fix" it.
```

## Snapshot-before-upgrade (guest)

Before anything risky inside the guest (kernel updates, big dnf upgrades,
Docker storage changes):

```bash
~/citadel/scripts/snapshot.sh pre-dnf     # label of your choice
# ... do the risky thing inside the guest, use it for a day or two ...
~/citadel/scripts/snapshot-commit.sh      # happy: merge overlay back
```

Don't accumulate overlays: each one is another file in the chain and another
thing the disk-space alert will eventually complain about. One snapshot at a
time, commit or roll back within days.

## Rollback

### Host (NixOS generations)

- **At the boot menu** (physical console or just power-cycle after a failed
  `test`): pick the previous generation from systemd-boot's list.
- **From a shell**:

  ```bash
  sudo nixos-rebuild switch --rollback
  ```

- List generations: `sudo nix-env --list-generations -p /nix/var/nix/profiles/system`

### Guest (snapshot revert)

External snapshots don't support live `snapshot-revert`; the revert is
"point the domain back at the base image":

```bash
virsh shutdown work-vm            # wait for it to stop
virsh domblklist work-vm          # note the overlay path (…work-vm.SNAPNAME)

# put the domain back on the base image
virt-xml work-vm --edit --disk path=/var/lib/libvirt/images/work-vm.qcow2

# discard the bad overlay + its metadata
virsh snapshot-delete work-vm --metadata SNAPNAME
rm /var/lib/libvirt/images/work-vm.SNAPNAME

virsh start work-vm               # boots as if the upgrade never happened
```

Everything written inside the guest *after* the snapshot is gone — that's
the point. Documents that must survive a rollback should already be synced
somewhere (backups are the other half of this, `scripts/backup.sh`).

## Routine health

```bash
virsh list --all                   # VM state
df -h /                            # disk (alert fires at 85%)
sudo smartctl -a /dev/nvme0n1      # SMART detail beyond smartd's alerts
sensors                            # temps
sudo fwupdmgr get-updates          # firmware (apply during a maintenance window)
systemctl --failed                 # anything red on the host
journalctl -u alert-vm-down -e     # if an alert misbehaves, its log is here
```
