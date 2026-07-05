# Alerting: a handful of systemd timers that post to a Slack channel via an
# incoming webhook. This deliberately replaces any kind of event system /
# API / dashboard — the entire alerting stack is this file, and the point is
# that you can read all of it.
#
# Checks:
#   - boot        : "host booted, VM awaiting unlock" (once per boot)
#   - disk        : / above 85% (hourly)
#   - vm-down     : work-vm defined but not running for >10 min (warning —
#                   expected after every reboot until you unlock)
#   - tailscale   : tailscaled not active (every 5 min)
#   - SMART       : smartd failure/warning hook (event-driven, not a timer)
#
# ── Slack setup (once) ──────────────────────────────────────────────────────
# 1. api.slack.com/apps → Create New App → From scratch, in your workspace.
# 2. Incoming Webhooks → activate → Add New Webhook → pick the alerts channel.
# 3. Put the webhook URL on the MACHINE (it's a secret — anyone holding it
#    can post to your workspace; it never goes in this repo):
#
#      sudo sh -c 'umask 077; echo "https://hooks.slack.com/services/T…/B…/…" > /etc/nixos/slack-webhook'
#
# Each recurring check keeps a flag file under /run/citadel-alerts so an
# ongoing problem alerts ONCE, not every timer tick. /run is a tmpfs, so
# flags (and therefore alert state) reset naturally on reboot.
{ config, pkgs, ... }:

let
  # The one knob: where the webhook URL lives on the machine (see header).
  webhookFile = "/etc/nixos/slack-webhook";

  vmName = "work-vm";
  stateDir = "/run/citadel-alerts";

  # slack-send TITLE PRIORITY BODY — the single delivery path all checks use.
  # Slack has no message priority, so it becomes the leading emoji. jq builds
  # the JSON so titles/bodies can safely contain quotes and newlines. Retries
  # cover blips; --max-time keeps a dead network from hanging a unit.
  slackSend = pkgs.writeShellScript "slack-send" ''
    set -euo pipefail
    title="$1" priority="$2" body="$3"
    if [ ! -r ${webhookFile} ]; then
      echo "error: ${webhookFile} missing or unreadable — see nixos/modules/alerts.nix header" >&2
      exit 1
    fi
    case "$priority" in
      urgent) icon=":rotating_light:" ;;
      high)   icon=":warning:" ;;
      *)      icon=":information_source:" ;;
    esac
    text=$(printf '%s *%s*\n%s' "$icon" "$title" "$body")
    ${pkgs.jq}/bin/jq -n --arg text "$text" '{text: $text}' \
      | ${pkgs.curl}/bin/curl -fsS --max-time 15 \
          --retry 5 --retry-delay 10 --retry-all-errors \
          -H "Content-type: application/json" -d @- \
          "$(cat ${webhookFile})" > /dev/null
  '';

  # smartd calls this on any failure/warning, with details in SMARTD_* env
  # vars (see smartd.conf(5) -M exec).
  smartdHook = pkgs.writeShellScript "smartd-slack" ''
    set -euo pipefail
    ${slackSend} "citadel SMART: $SMARTD_FAILTYPE on $SMARTD_DEVICE" urgent \
      "$SMARTD_MESSAGE"
  '';

  # Small helper to declare a oneshot service + timer pair without repeating
  # boilerplate four times.
  check = { name, description, every, script }: {
    services.${name} = {
      inherit description script;
      serviceConfig.Type = "oneshot";
    };
    timers.${name} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = every;
        OnUnitActiveSec = every;
      };
    };
  };

  diskCheck = check {
    name = "alert-disk";
    description = "Slack alert: root filesystem >85% full";
    every = "1h";
    script = ''
      mkdir -p ${stateDir}
      pct=$(${pkgs.coreutils}/bin/df --output=pcent / | ${pkgs.coreutils}/bin/tail -1 | ${pkgs.coreutils}/bin/tr -dc '0-9')
      if [ "$pct" -gt 85 ]; then
        if [ ! -f ${stateDir}/disk ]; then
          ${slackSend} "citadel: disk $pct% full" high \
            "Root filesystem is at $pct%. Guest qcow2 growth or snapshot overlays are the usual suspects — check /var/lib/libvirt/images."
          touch ${stateDir}/disk
        fi
      else
        rm -f ${stateDir}/disk
      fi
    '';
  };

  vmCheck = check {
    name = "alert-vm-down";
    description = "Slack alert: ${vmName} defined but not running >10min";
    every = "5min";
    script = ''
      mkdir -p ${stateDir}
      state=$(${pkgs.libvirt}/bin/virsh domstate ${vmName} 2>/dev/null || echo undefined)
      if [ "$state" = "running" ] || [ "$state" = "undefined" ]; then
        rm -f ${stateDir}/vm-down-since ${stateDir}/vm-down-notified
        exit 0
      fi
      now=$(${pkgs.coreutils}/bin/date +%s)
      if [ ! -f ${stateDir}/vm-down-since ]; then
        echo "$now" > ${stateDir}/vm-down-since
        exit 0
      fi
      since=$(${pkgs.coreutils}/bin/cat ${stateDir}/vm-down-since)
      if [ $((now - since)) -ge 600 ] && [ ! -f ${stateDir}/vm-down-notified ]; then
        # "default" priority, not "high": after a reboot this fires until you
        # unlock, which is expected. It's a reminder, not a page.
        ${slackSend} "citadel: ${vmName} not running" default \
          "State: $state for over 10 minutes. Expected if you haven't unlocked after a reboot; otherwise investigate with: virsh list --all"
        touch ${stateDir}/vm-down-notified
      fi
    '';
  };

  tailscaleCheck = check {
    name = "alert-tailscale";
    description = "Slack alert: tailscaled not active";
    every = "5min";
    script = ''
      mkdir -p ${stateDir}
      if ${pkgs.systemd}/bin/systemctl is-active --quiet tailscaled; then
        rm -f ${stateDir}/tailscale
        exit 0
      fi
      if [ ! -f ${stateDir}/tailscale ]; then
        ${slackSend} "citadel: tailscaled is DOWN" high \
          "Host tailscale is not active — remote access is LAN/guest-tailscale only. systemctl status tailscaled"
        touch ${stateDir}/tailscale
      fi
    '';
  };

  # Boot notification: reminds you the VM is sitting at its LUKS prompt.
  bootNotify = {
    alert-boot = {
      description = "Slack alert: host booted";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true; # once per boot, even if multi-user is re-reached
      };
      script = ''
        ${slackSend} "citadel: host booted" default \
          "Host is up. ${vmName} is awaiting manual start + LUKS unlock (see docs/operations.md)."
      '';
    };
  };
in
{
  systemd.services = bootNotify // diskCheck.services // vmCheck.services // tailscaleCheck.services;
  systemd.timers = diskCheck.timers // vmCheck.timers // tailscaleCheck.timers;

  # Wire smartd (enabled in monitoring.nix) to Slack. "-a" = monitor
  # everything; "-m <nomailer> -M exec" = skip mail, run our hook instead.
  services.smartd.defaults.monitored = "-a -m <nomailer> -M exec ${smartdHook}";
}
