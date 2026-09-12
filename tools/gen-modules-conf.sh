#!/bin/bash
# Regenerates the autoload module list from ./modules.conf.in.
#
# FreeSWITCH ships an autoload list (conf/vanilla/autoload_configs/modules.conf.xml)
# that names every module upstream knows about, including the ones we do not
# compile. At startup each of those produces a [CRIT] "Error Loading module"
# line, which is noise that hides real failures. Generating the autoload list
# from the same file that drives the build keeps the two in sync.
#
# Run from the repository root.
set -euo pipefail

SRC=${1:-modules.conf.in}
OUT=${2:-conf-templates/autoload_configs/modules.conf.xml}

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

{
  echo '<configuration name="modules.conf" description="Modules">'
  echo '  <modules>'
  echo '    <!-- Generated from modules.conf.in by tools/gen-modules-conf.sh.'
  echo '         Only modules compiled into this image are listed: loading a'
  echo '         module that was not built logs a [CRIT] at startup. -->'
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '    <load module="%s"/>\n' "${line##*/}"
  done < "$SRC"
  echo '  </modules>'
  echo '</configuration>'
} > "$OUT"

echo "wrote $OUT with $(grep -c 'load module' "$OUT") modules"
