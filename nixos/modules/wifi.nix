# WiFi — OPT-IN. Not imported by default (see configuration.nix): prefer
# Ethernet for this appliance. Wireless on a headless box means AP problems
# or a rotated password put you at the physical console. If the machine's
# placement forces WiFi, uncomment the import and read on.
#
# We use plain wpa_supplicant (networking.wireless), not NetworkManager:
# declarative, no per-connection state accumulating outside the repo, and
# fits an appliance that joins exactly one network.
#
# THE PASSWORD IS NOT IN THIS FILE. It lives only on the machine, in
# /etc/nixos/wifi.secrets (never in git; bootstrap.sh doesn't touch it):
#
#   sudo sh -c 'umask 077; echo "home_psk=YOUR-WIFI-PASSWORD" > /etc/nixos/wifi.secrets'
#
{ ... }:

{
  networking.wireless = {
    enable = true;

    # key=value file referenced by the "ext:" values below.
    secretsFile = "/etc/nixos/wifi.secrets";

    networks = {
      # ── CHANGEME (only if you enable WiFi at all) ── your SSID:
      "CHANGEME-ssid" = {
        pskRaw = "ext:home_psk";
      };
    };
  };
}
