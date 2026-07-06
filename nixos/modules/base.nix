# Baseline system identity: who logs in, what time it is, how much history
# the machine keeps.
{ config, pkgs, ... }:

{
  time.timeZone = "Asia/Kolkata";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.ankith = {
    isNormalUser = true;
    # wheel    -> sudo
    # libvirtd -> talk to the system libvirt daemon without sudo
    #             (virsh, virt-install, virt-viewer all just work)
    extraGroups = [ "wheel" "libvirtd" ];
    openssh.authorizedKeys.keys = [
      # ── REQUIRED ── paste your real public key BEFORE installing.
      # SSH is key-only (see ssh.nix); leave this placeholder in and you will
      # be locked out of remote access after first boot.
      "ssh-ed25519 CHANGEME-paste-your-public-key ankith@laptop"
    ];
  };

  # Mutable users (the default) means `passwd` works normally on the machine.
  # The account password is set during install and used only for sudo and the
  # physical console — never for SSH.

  # Keep the Nix store from growing forever. Old system generations are what
  # let you roll back from the boot menu, so we keep a month of them, GC'd
  # weekly. NEVER run GC right after a risky change — see docs/operations.md.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # Hard-link identical files in the store; costs nothing, saves gigabytes.
  nix.settings.auto-optimise-store = true;

  # The boot menu lists at most this many generations (disk in the ESP is
  # finite). GC above is what actually deletes them from the store.
  boot.loader.systemd-boot.configurationLimit = 15;

  # Small, boring toolbox for an appliance. Dev tools live in the guest.
  environment.systemPackages = with pkgs; [
    git
    htop
    tmux
    vim
  ];
}
