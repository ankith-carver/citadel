# Tailscale on the HOST. The guest runs its own, independent tailscaled —
# that's deliberate: if the VM (or its network) is wedged you can still reach
# the host, and if the host tailscale breaks while the VM is up you can still
# reach the guest.
#
# No auth key lives in this repo. Authentication is a one-time interactive
# `sudo tailscale up` on first boot (docs/install.md step 5); the node key is
# then persisted in /var/lib/tailscale.
{ config, ... }:

{
  services.tailscale.enable = true;

  # Let tailscale's UDP port through so direct (non-DERP-relayed) connections
  # work. The tailscale0 interface itself is trusted in firewall.nix.
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];
}
