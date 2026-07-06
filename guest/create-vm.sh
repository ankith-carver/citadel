#!/usr/bin/env bash
# Create the work VM. Run ON THE HOST as ankith (libvirtd group — no sudo).
#
#   ./create-vm.sh /var/lib/libvirt/images/Fedora-Workstation-Live-x86_64.iso
#
# Implements the decided spec (see README / guest/work-vm.xml.example):
# fixed 48G RAM, 10 vCPU host-passthrough, UEFI + swtpm TPM2, virtio-scsi
# qcow2 with discard=unmap, virtio-gpu 2D, SPICE, serial console, no
# ballooning, no autostart. Fedora's installer is interactive on purpose:
# that's where you set up LUKS.
set -euo pipefail

# ── Knobs ────────────────────────────────────────────────────────────────
VM_NAME="${VM_NAME:-work-vm}"
MEMORY_MIB="${MEMORY_MIB:-49152}"        # 48 GiB, fixed. No ballooning.
VCPUS="${VCPUS:-10}"                     # of 24 threads; rest stays with host
DISK_SIZE_GB="${DISK_SIZE_GB:-500}"      # qcow2 is sparse; this is the cap
DISK_PATH="${DISK_PATH:-/var/lib/libvirt/images/${VM_NAME}.qcow2}"

ISO_PATH="${1:?usage: $0 /path/to/Fedora-Workstation-Live-x86_64.iso}"

export LIBVIRT_DEFAULT_URI="qemu:///system"

if [ ! -r "$ISO_PATH" ]; then
  echo "error: cannot read ISO at $ISO_PATH" >&2
  exit 1
fi

if virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "error: domain '$VM_NAME' already exists. Remove it first:" >&2
  echo "  virsh undefine $VM_NAME --nvram --tpm" >&2
  exit 1
fi

# The default NAT network is defined on NixOS but autostart is declared in
# virtualization.nix (tmpfiles symlink) — this start is only for the first
# run after enabling that, before any reboot has let autostart do its thing.
if ! virsh net-info default | grep -q '^Active:.*yes'; then
  echo "starting libvirt default network..."
  virsh net-start default
fi

# What each block means:
#   --cpu host-passthrough  guest sees the real Zen 5 CPU (best perf; we never
#                           migrate this VM so portability doesn't matter)
#   --boot uefi             libvirt picks an OVMF firmware automatically
#   --tpm ...emulator       swtpm-backed TPM 2.0 device
#   --controller/--disk     virtio-scsi so discard=unmap flows guest fstrim ->
#                           qcow2 hole-punching -> host ext4
#   --video virtio          virtio-gpu, plain 2D (no VirGL/3D — no GPU here)
#   --graphics spice        console for install + LUKS unlock; reached via
#                           virt-viewer over SSH, never a network listener
#   --memballoon none       fixed memory, nothing to balloon
#   --autoconsole none      headless host — connect from the laptop instead
virt-install \
  --name "$VM_NAME" \
  --memory "$MEMORY_MIB" \
  --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --osinfo detect=on,require=off \
  --machine q35 \
  --boot uefi \
  --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
  --controller type=scsi,model=virtio-scsi \
  --disk "path=${DISK_PATH},size=${DISK_SIZE_GB},format=qcow2,bus=scsi,discard=unmap,cache=none" \
  --network network=default,model=virtio \
  --video virtio \
  --graphics spice \
  --channel spicevmc \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --serial pty \
  --cdrom "$ISO_PATH" \
  --autoconsole none

cat <<EOF

'$VM_NAME' created and booting the installer.

Next, from your laptop:
  virt-viewer --connect "qemu+ssh://ankith@$(hostname)/system" $VM_NAME

Then walk the Fedora installer (choose full-disk encryption!) and follow
guest/fedora-notes.md for everything after the first boot.
EOF
