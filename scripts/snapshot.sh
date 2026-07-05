#!/usr/bin/env bash
# Create an EXTERNAL snapshot of the work VM. Run on the host before OS
# upgrades, driver installs, or any big change inside the guest.
#
#   ./snapshot.sh [label]        e.g. ./snapshot.sh pre-dnf
#
# External snapshot = the current qcow2 is frozen as a read-only base and a
# new overlay file becomes the active disk. Rolling back = revert to the
# base; keeping the change = merge the overlay back with snapshot-commit.sh.
# We NEVER use internal qcow2 snapshots (slow, fragile, invisible on disk).
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

VM="${VM_NAME:-work-vm}"
LABEL="${1:-manual}"
SNAP="${LABEL}-$(date +%Y%m%d-%H%M%S)"

if ! virsh dominfo "$VM" &>/dev/null; then
  echo "error: domain '$VM' does not exist" >&2
  exit 1
fi

# Quiesce (freeze guest filesystems via qemu-guest-agent) when we can — the
# snapshot is then filesystem-consistent, not just crash-consistent.
QUIESCE=()
if virsh qemu-agent-command "$VM" '{"execute":"guest-ping"}' &>/dev/null; then
  QUIESCE=(--quiesce)
else
  echo "note: guest agent not responding (VM off or agent missing);"
  echo "      snapshot will be crash-consistent, which is still fine."
fi

virsh snapshot-create-as "$VM" "$SNAP" \
  --disk-only --atomic "${QUIESCE[@]}"

echo
echo "External snapshot '$SNAP' created. Disk chain is now:"
virsh domblklist "$VM"
echo
echo "  keep the change  -> ./snapshot-commit.sh   (merges overlay back)"
echo "  roll back        -> see docs/operations.md (guest rollback)"
