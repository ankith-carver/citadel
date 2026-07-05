#!/usr/bin/env bash
# Merge (blockcommit) the active overlay back into the base image, after
# you've verified an upgrade/change is good. This is the "keep it" half of
# the external-snapshot workflow; the VM keeps running throughout.
#
#   ./snapshot-commit.sh
#
# What happens: qemu copies the overlay's blocks down into the base, then
# pivots the VM back onto the base file. Afterwards we delete the snapshot
# metadata and the now-orphaned overlay files.
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

VM="${VM_NAME:-work-vm}"

if [ "$(virsh domstate "$VM" 2>/dev/null)" != "running" ]; then
  echo "error: '$VM' must be RUNNING for a live blockcommit." >&2
  echo "Start it first (or for an offline merge, see docs/operations.md)." >&2
  exit 1
fi

# Disk targets (sda, ...) and their current (overlay) paths, before we touch
# anything — these are the files we'll delete after the pivot.
mapfile -t targets < <(virsh domblklist "$VM" --details | awk '$2 == "disk" { print $3 }')
mapfile -t overlays < <(virsh domblklist "$VM" --details | awk '$2 == "disk" { print $4 }')

if [ "${#targets[@]}" -eq 0 ]; then
  echo "error: no disks found on '$VM'?" >&2
  exit 1
fi

echo "Committing overlays back into base images:"
for i in "${!targets[@]}"; do
  echo "  ${targets[$i]}  <-  ${overlays[$i]}"
done
read -r -p "Proceed? [y/N] " ans
[ "${ans,,}" = "y" ] || exit 1

for t in "${targets[@]}"; do
  # --active: commit the top (running) layer; --pivot: switch the VM onto
  # the base once the copy converges.
  virsh blockcommit "$VM" "$t" --active --verbose --pivot
done

# The snapshot metadata now points at merged-away files — drop it.
for s in $(virsh snapshot-list "$VM" --name); do
  [ -n "$s" ] && virsh snapshot-delete "$VM" "$s" --metadata
done

echo
echo "Disk chain after commit:"
virsh domblklist "$VM"

# Delete orphaned overlay files, but only ones no longer referenced.
for o in "${overlays[@]}"; do
  if [ -f "$o" ] && ! virsh domblklist "$VM" | grep -qF "$o"; then
    rm -v -- "$o"
  fi
done

echo "Done. One flat image again."
