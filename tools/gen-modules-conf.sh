#!/bin/bash
# Regenerates the autoload module list from ./modules.conf.in.
#
# FreeSWITCH ships an autoload list (conf/vanilla/autoload_configs/modules.conf.xml)
# that names every module upstream knows about, including the ones we do not
# compile. At startup each of those produces a [CRIT] "Error Loading module"
# line, which is noise that hides real failures. Generating the autoload list
# from the same file that drives the build keeps the two in sync.
#
# Built but not autoloaded:
#   Modules listed in NOT_AUTOLOAD_MODULES below are still compiled into the
#   image, but are left out of the startup list. Use this for modules that
#   cannot work until the user supplies configuration, so that the default
#   image does not log connection errors on every boot. They can be enabled by
#   adding a <load module="..."/> line to your own modules.conf.xml.
#
# Run from the repository root.
set -euo pipefail

SRC=${1:-modules.conf.in}
OUT=${2:-conf-templates/autoload_configs/modules.conf.xml}

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

# Modules that are compiled but deliberately kept out of the startup list.
#
# A module is excluded for one of three reasons:
#
# 1. It fails its load routine unless the user supplies configuration that
#    upstream does not ship, so every default boot logs a [CRIT]:
#
#      mod_lcr         needs an ODBC DSN and an lcr.conf.xml
#      mod_fail2ban    opens fail2ban.conf, which does not exist by default
#      mod_json_cdr    opens json_cdr.conf, which does not exist by default
#      mod_odbc_cdr    opens odbc_cdr.conf, which does not exist by default
#      mod_xml_curl    has no <binding> URL configured by default
#      mod_xml_ldap    opens xml_ldap.conf, which does not exist by default
#
# 2. It loads cleanly but is opt-in for licensing, safety, or scope reasons:
#
#      mod_amqp        retries a broker connection forever, flooding the log
#      mod_amr         patent-encumbered in most jurisdictions
#      mod_amrwb       patent-encumbered in most jurisdictions
#      mod_spy         installs surveillance commands (spy, eavesdrop)
#
# 3. It is not needed for a typical voice deployment and would only widen
#    the attack surface or the codec/protocol surface on offer:
#
#      mod_skinny        legacy Cisco SCCP; SIP phones do not need it
#      mod_verto         Verto WebRTC client protocol; sofia WSS covers WebRTC
#      mod_rtc           Google WebRTC RTC, effectively Verto-only
#      mod_enum          E.164 ENUM resolution; unused without carrier ENUM
#      mod_fsk           FSK modem signalling for legacy caller-ID
#      mod_b64           base64 pseudo-codec; internal use only
#      mod_png           PNG image files
#      mod_shout         MP3/Shoutcast streaming; MoH uses WAV over sndfile
#      mod_local_stream  local stream playback; MoH uses WAV over sndfile
#      mod_nibblebill    prepaid billing
#      mod_avmd          voicemail beep detection for outbound AMD
#      mod_video_filter  video filtering; audio-only deployments
#      mod_xml_scgi      SCGI XML backend; fails to connect unless a server runs
#
# 4. It writes logs somewhere this image does not provide:
#
#      mod_logfile       writes var/log/freeswitch/freeswitch.log, which nothing
#                        in the image rotates (no logrotate, no cron). Whatever
#                        supervises the container has to bound that file, so the
#                        console logger is left as the single place logs go.
#      mod_syslog        logs to syslog; the image runs no syslog daemon, so it
#                        was publishing into a socket nobody reads
#
# Every module here is still compiled into the image, so enabling one needs no
# rebuild: add a <load module="..."/> line to your own modules.conf.xml (and,
# for the group-1 modules, supply the configuration they read).
NOT_AUTOLOAD_MODULES=(
  mod_lcr
  mod_fail2ban
  mod_json_cdr
  mod_odbc_cdr
  mod_xml_curl
  mod_xml_ldap
  mod_amqp
  mod_amr
  mod_amrwb
  mod_spy
  mod_skinny
  mod_verto
  mod_rtc
  mod_enum
  mod_fsk
  mod_b64
  mod_png
  mod_shout
  mod_local_stream
  mod_nibblebill
  mod_avmd
  mod_video_filter
  mod_xml_scgi
  mod_logfile
  mod_syslog
)

is_not_autoloaded() {
  local mod=$1 candidate
  for candidate in "${NOT_AUTOLOAD_MODULES[@]}"; do
    [[ "$mod" == "$candidate" ]] && return 0
  done
  return 1
}

{
  echo '<configuration name="modules.conf" description="Modules">'
  echo '  <modules>'
  echo '    <!-- Generated from modules.conf.in by tools/gen-modules-conf.sh.'
  echo '         Only modules compiled into this image are listed: loading a'
  echo '         module that was not built logs a [CRIT] at startup.'
  if (( ${#NOT_AUTOLOAD_MODULES[@]} > 0 )); then
    echo '         Built but intentionally not autoloaded:'
    for m in "${NOT_AUTOLOAD_MODULES[@]}"; do
      echo "           $m"
    done
  fi
  echo '    -->'
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    mod=${line##*/}
    if is_not_autoloaded "$mod"; then
      continue
    fi
    printf '    <load module="%s"/>\n' "$mod"
  done < "$SRC"
  echo '  </modules>'
  echo '</configuration>'
} > "$OUT"

echo "wrote $OUT with $(grep -c 'load module' "$OUT") modules"
