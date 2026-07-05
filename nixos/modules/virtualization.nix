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
