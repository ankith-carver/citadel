#!/usr/bin/env bash
# Backup of the work VM's disk image — STRUCTURED STUB.
#
# ── TODO: the destination is deliberately undecided ─────────────────────────
# Fill in the two CHANGEME blocks below once you pick:
#   destination : second internal disk / NAS / Backblaze B2 / ...
#   tool        : restic (encrypts + dedupes, works with B2) or borg (ditto,
#                 better for local/SSH targets)
# The shape of the script — consistent source, then ship, then prune — is
# already correct; only the shipping mechanism is missing.
set -euo pipefail

export LIBVIRT_DEFAULT_URI="qemu:///system"

VM="${VM_NAME:-work-vm}"
DISK="/var/lib/libvirt/images/${VM}.qcow2"

# ── CHANGEME: destination + tool ────────────────────────────────────────────
BACKUP_TARGET="CHANGEME"       # e.g. /mnt/backup, b2:bucket-name, ssh://nas/...
BACKUP_TOOL="CHANGEME"         # restic | borg

if [ "$BACKUP_TARGET" = "CHANGEME" ] || [ "$BACKUP_TOOL" = "CHANGEME" ]; then
  echo "backup.sh is not configured yet — pick a destination and tool first." >&2
  echo "(See the TODO block at the top of this script.)" >&2
  exit 1
fi

# 1) Get a consistent source to back up.
#    Cleanest: back up while the VM is shut down. If it's running, refuse —
#    a raw copy of a live qcow2 is corrupt-by-design. (A fancier version
#    could snapshot + back up the frozen base; keep it simple until the
#    destination is real.)
if [ "$(virsh domstate "$VM" 2>/dev/null)" = "running" ]; then
  echo "error: '$VM' is running. Shut it down first: virsh shutdown $VM" >&2
  exit 1
fi

# 2) Ship it.
case "$BACKUP_TOOL" in
  restic)
    # TODO: export RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE (password file on
    # the host, outside this repo), then:
    # restic backup "$DISK"
    ;;
  borg)
    # TODO: borg create "$BACKUP_TARGET"::"$VM-{now}" "$DISK"
    ;;
  *)
    echo "error: unknown BACKUP_TOOL '$BACKUP_TOOL'" >&2
    exit 1
    ;;
esac

# 3) Prune old backups.
# TODO: restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
#       (or borg prune equivalents)

# 4) Also worth capturing (tiny, changes rarely):
#    - virsh dumpxml "$VM"          (domain definition)
#    - /var/lib/libvirt/swtpm/      (TPM state)
#    - this git repo itself covers the host config

echo "Backup complete."
