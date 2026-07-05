# Host health: disk SMART, time sync, temperature sensors, firmware updates.
# The alert *delivery* (Slack) lives in alerts.nix; this module just turns the
# underlying services on.
{ pkgs, ... }:

{
  # SMART monitoring of the NVMe. Failure/warning notifications are wired to
  # Slack in alerts.nix (smartd calls an exec hook there).
  services.smartd.enable = true;

  # chrony over systemd-timesyncd: a real NTP daemon, better at keeping time
  # sane across suspends and long uptimes. Enabling it automatically disables
  # timesyncd.
  services.chrony.enable = true;

  # Firmware updates (UEFI capsules, NVMe firmware) via `fwupdmgr`.
  # Usage: fwupdmgr refresh && fwupdmgr get-updates && fwupdmgr update
  services.fwupd.enable = true;

  # `sensors` for CPU temps etc. Run `sudo sensors-detect` once on first boot
  # (docs/install.md); if it suggests kernel modules (typically nct6775 for
  # this class of board), add them here:
  # boot.kernelModules = [ "nct6775" ];
  environment.systemPackages = with pkgs; [
    lm_sensors
    smartmontools   # smartctl for manual inspection; smartd runs regardless
  ];
}
