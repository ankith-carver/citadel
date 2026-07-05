# Disaster recovery — dead SSD to working machine

Scenario: the NVMe died (or the machine was lost) and you're starting from a
blank disk. Everything needed is: **this repo** + **the latest guest disk
backup** + **your LUKS passphrase**. If any of those three is missing, stop
and understand why before proceeding.

Total honest time estimate: 1–2 hours, most of it copying the qcow2 back.

## 0. What you're rebuilding from

| Piece | Lives where | Restores how |
|---|---|---|
| Host OS + config | this git repo | reinstall NixOS + bootstrap.sh (host has NO unique state worth backing up) |
| hardware-configuration.nix | regenerated fresh | `nixos-generate-config` during install |
| Guest disk (the actual valuable data) | backup target (`scripts/backup.sh`) | restore qcow2 file |
| Guest definition (domain XML) | re-creatable from `guest/create-vm.sh`; ideally also in the backup (`virsh dumpxml`) | define or re-create |
| Tailscale identities | tailnet admin console | re-auth interactively; delete the dead machine's old nodes |
| swtpm (guest TPM) state | backup if captured; otherwise lost | usually fine — Fedora LUKS uses the passphrase, not the TPM |

## 1. Replace hardware, reinstall the host

Follow [install.md](install.md) steps 1–5 exactly (BIOS prep → partition →
install → tailscale up → bootstrap). Two deviations:

- The repo already exists; clone it instead of re-creating anything.
- In the tailscale admin console, remove the dead `citadel` node so the name
  is free for the new one.

At the end of this you have a fully working, empty appliance. ~30 minutes.

## 2. Restore the guest disk

```bash
# from wherever backup.sh ships to — e.g. restic:
# restic restore latest --target /var/lib/libvirt/images --include work-vm.qcow2
# or plain copy from a NAS:
# scp nas:/backups/work-vm.qcow2 /var/lib/libvirt/images/

sudo chown root:root /var/lib/libvirt/images/work-vm.qcow2
qemu-img check /var/lib/libvirt/images/work-vm.qcow2   # must report no errors
```

## 3. Re-define the VM

Option A — dumped XML was in the backup (preferred):

```bash
virsh define work-vm.xml
```

Option B — re-create the definition around the restored disk:

```bash
# create-vm.sh is for fresh installs (it wants an ISO); for a restore,
# import the existing disk with the same spec:
virt-install \
  --name work-vm \
  --memory 49152 --vcpus 10 --cpu host-passthrough \
  --machine q35 --boot uefi \
  --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
  --osinfo detect=on,require=off \
  --controller type=scsi,model=virtio-scsi \
  --disk path=/var/lib/libvirt/images/work-vm.qcow2,format=qcow2,bus=scsi,discard=unmap,cache=none \
  --network network=default,model=virtio \
  --video virtio --graphics spice --channel spicevmc \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --serial pty \
  --import --autoconsole none
```

(If the guest had enrolled anything in the TPM, the fresh swtpm state won't
have it — with the default passphrase-only LUKS setup this doesn't matter.)

## 4. Boot and unlock

```bash
virsh start work-vm
# from the laptop:
virt-viewer --connect qemu+ssh://ankith@citadel/system work-vm
# type the LUKS passphrase
```

Inside the guest, expect two things to need attention:

- **Tailscale**: the node key is from the old life; `sudo tailscale up`
  again and delete the old `work-vm` node in the admin console.
- **Clock skew** on first boot (chrony/guest will sort itself out).

## 5. Verify like a fresh build

Run the full verification list from [install.md](install.md) step 7 —
serial console, guest agent, both tailscales, RDP, reboot drill. Then check
the guest's data is actually the backup you thought it was (open a recent
document; `docker ps -a`).

## What is accepted-lost by design

- Everything written in the guest after the last backup — the backup cadence
  (once `backup.sh` is real) is the knob for how much that can hurt.
- Host-side journal/logs and any manual host tweaks that never made it into
  this repo. If you catch yourself missing one: it belonged in the repo.
