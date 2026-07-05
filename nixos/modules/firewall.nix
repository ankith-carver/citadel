# Firewall: SSH from the LAN, everything from the tailnet, nothing else.
{ ... }:

{
  networking.firewall = {
    enable = true;

    # SSH is the only service exposed on the physical LAN.
    allowedTCPPorts = [ 22 ];

    # Anything arriving over Tailscale is already authenticated by the
    # tailnet, so the interface is trusted wholesale.
    trustedInterfaces = [ "tailscale0" ];

    # Tailscale's return traffic can arrive on a different interface than the
    # kernel's strict reverse-path filter expects; "loose" is the documented
    # setting for running tailscaled cleanly.
    checkReversePath = "loose";
  };

  # NOTE: the guest's NAT network (virbr0) is managed by libvirt, which
  # inserts its own forwarding rules alongside these. Nothing to do here.
  # The guest's own exposure (RDP) happens over the guest's tailscale, inside
  # the VM — the host firewall never sees it.
}
