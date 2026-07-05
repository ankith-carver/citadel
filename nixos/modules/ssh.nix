# SSH: keys only, no root. This is the primary management plane for the whole
# appliance (virsh runs over it), so it stays strict.
{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      # Root never logs in remotely; use ankith + sudo.
      PermitRootLogin = "no";
      # Two settings because OpenSSH has two prompts that feel like
      # "password login": classic password auth, and keyboard-interactive
      # (PAM-driven challenge). Both off -> keys are the only way in.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
