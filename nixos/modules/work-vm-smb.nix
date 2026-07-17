# SMB access to the guest's file share from the office LAN.
#
# The share itself lives INSIDE the guest (Samba setup:
# guest/fedora-notes.md step 6). Over Tailscale, clients reach it directly
# at the guest's tailnet name — the host plays no part. But the guest is
# NAT'd behind virbr0, so LAN clients can't reach it directly; instead of
# injecting DNAT rules into the FORWARD chain (where ordering against
# libvirt's own rules is fragile), the host runs a tiny socket-activated
# TCP proxy: connect to the HOST's LAN IP on 445 and systemd-socket-proxyd
# relays to the guest. When the VM is down the connection simply fails.
#
# Prerequisite (one-time, stateful — like tailscale auth): pin the guest to
# a fixed address so the proxy target is stable:
#
#   virsh domiflist work-vm     # note the MAC of the 'default' network NIC
#   virsh net-update default add ip-dhcp-host \
#     '<host mac="52:54:00:XX:XX:XX" name="work-vm" ip="192.168.122.10"/>' \
#     --live --config
#
# then bounce the guest's connection (or reboot it) to pick up the lease.
{ pkgs, ... }:

let
  # Must match the ip-dhcp-host lease above.
  guestAddr = "192.168.122.10";
in
{
  systemd.sockets.work-vm-smb-proxy = {
    description = "SMB proxy to work-vm (listener)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "445" ];
  };

  systemd.services.work-vm-smb-proxy = {
    description = "SMB proxy to work-vm";
    requires = [ "work-vm-smb-proxy.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min ${guestAddr}:445";
      # Nothing here needs privileges: the socket unit binds 445, the proxy
      # just shuffles bytes.
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
    };
  };

  # Second (and last) service on the physical LAN after SSH — see the note
  # in firewall.nix. Tailscale clients never touch this port; they go
  # straight to the guest.
  networking.firewall.allowedTCPPorts = [ 445 ];
}
