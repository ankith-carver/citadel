# libvirt/KVM — the reason this machine exists.
#
# Decisions encoded here (see README for the full rationale):
#   - UEFI guests via OVMF, emulated TPM 2.0 via swtpm
#   - NO GPU passthrough / VFIO anywhere; guest gets virtio-gpu (2D)
#   - the VM does NOT autostart: after a host boot it needs a human at the
#     SPICE console to type the LUKS passphrase anyway, so starting it is
#     part of the manual unlock flow (docs/operations.md)
{ pkgs, ... }:

{
  virtualisation.libvirtd = {
    enable = true;

    # "ignore" = leave VMs alone on host boot (manual unlock flow).
    onBoot = "ignore";
    # On host shutdown, try a clean guest shutdown instead of pausing to
    # disk. The guest is a full OS with Docker etc. — let it stop properly.
    onShutdown = "shutdown";

    qemu = {
      # Emulated TPM 2.0 for the guest (Fedora can use it; future-proofs for
      # anything that wants measured boot).
      swtpm.enable = true;
      # UEFI (OVMF) needs no option here: since NixOS 25.11 all OVMF firmware
      # images ship with QEMU by default, and libvirt auto-selects one when a
      # guest asks for firmware="efi".
      # Don't run guests as root.
      runAsRoot = false;
    };
  };

  # libvirt's default NAT network (virbr0, guests on 192.168.122.0/24): the
  # NixOS module copies the package's default.xml definition into
  # /var/lib/libvirt/qemu/networks/ but NOT the autostart symlink next to it,
  # so the network exists yet never starts (verified in the 26.05 module
  # source; cost a debugging session on the real build). Declare the
  # autostart symlink ourselves — exactly what `virsh net-autostart` would
  # create imperatively:
  systemd.tmpfiles.rules = [
    "d /var/lib/libvirt/qemu/networks/autostart 0755 root root -"
    "L /var/lib/libvirt/qemu/networks/autostart/default.xml - - - - /var/lib/libvirt/qemu/networks/default.xml"
  ];

  # Plain `virsh` as a user talks to the unprivileged per-user SESSION daemon
  # — where there are no VMs, no networks, and no permission to make bridges.
  # Everything on this machine lives in the SYSTEM daemon; make that the
  # default so interactive virsh does the expected thing.
  environment.variables.LIBVIRT_DEFAULT_URI = "qemu:///system";

  # CLI tooling only — the host is headless.
  #   virt-manager  -> provides virt-install / virt-clone (we never run the GUI)
  #   virt-viewer   -> here mainly for completeness; you normally run it on
  #                    the laptop and let it tunnel over SSH
  environment.systemPackages = with pkgs; [
    virt-manager
    virt-viewer
  ];

  # qemu-guest-agent lives INSIDE the guest (guest/fedora-notes.md). Host side
  # needs nothing extra: libvirt wires up the virtio channel from the XML.
}
