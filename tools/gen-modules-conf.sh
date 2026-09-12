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

# Compiled, but not loaded at startup unless the user opts in.
#
#   mod_amqp: connects to an AMQP broker on load and retries forever if none is
#             reachable, filling the log with [CRIT]/[WARNING] on every boot.
#
# The rest fail their load routine outright because upstream ships no config
# for them, so every default start logs an "Error Loading module" [CRIT]:
#
#   mod_lcr         needs an ODBC DSN and an lcr.conf.xml
#   mod_fail2ban    opens fail2ban.conf, which does not exist by default
#   mod_json_cdr    opens json_cdr.conf, which does not exist by default
#   mod_odbc_cdr    opens odbc_cdr.conf, which does not exist by default
#   mod_xml_curl    has no <binding> URL configured by default
#   mod_xml_ldap    opens xml_ldap.conf, which does not exist by default
#   mod_codec2      opens codec2.conf, which does not exist by default
#
# The AMR codecs below are a deliberate opt-in for licensing reasons rather than
# a configuration problem: they load cleanly and really do transcode, but AMR
# and AMR-WB carry patent obligations in most jurisdictions. Keeping them out
# of the default startup list means an unmodified container never offers them
# in a codec negotiation.
#
#   mod_amr         patent-encumbered in most jurisdictions
#   mod_amrwb       patent-encumbered in most jurisdictions
#
# All ten are still built, so enabling one needs no rebuild: add a
# <load module="..."/> line to your own modules.conf.xml (and, for the
# modules that need it, supply the configuration they read).
NOT_AUTOLOAD_MODULES=(
  mod_amqp
  mod_lcr
  mod_fail2ban
  mod_json_cdr
  mod_odbc_cdr
  mod_xml_curl
  mod_xml_ldap
  mod_codec2
  mod_amr
  mod_amrwb
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
