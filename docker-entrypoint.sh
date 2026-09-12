#!/bin/sh
set -e

# FreeSWITCH's compiled-in default conf directory is ${prefix}/etc/freeswitch,
# NOT ${prefix}/conf. `make install` populates it with the stock upstream
# configuration, so rendering our templates into ${prefix}/conf has no effect:
# FreeSWITCH reads the stock files instead and silently falls back to the
# hardcoded defaults (listen-port 8021, password "ClueCon", ACL
# "loopback.auto"), which rejects every ESL connection from another container.
#
# We therefore render into the directory FreeSWITCH actually reads. FS_CONF_DIR
# can override it; the default matches the configure --prefix used in the
# Dockerfile.
FS_PREFIX=/usr/local/freeswitch
FS_CONF="${FS_CONF_DIR:-$FS_PREFIX/etc/freeswitch}"
FS_LOG_DIR="${FS_LOG_DIR:-$FS_PREFIX/var/log/freeswitch}"
FS_TEMPLATE_DIR="${FS_TEMPLATE_DIR:-/opt/fs-templates}"

mkdir -p "$FS_LOG_DIR"

wait_for_pg() {
    [ -z "$PGHOST" ] && return 0
    echo "[entrypoint] waiting for postgres at ${PGHOST}:${PGPORT:-5432}..."
    i=0
    while [ "$i" -lt 60 ]; do
        if PGPASSWORD="$PGPASSWORD" pg_isready -h "$PGHOST" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}" >/dev/null 2>&1; then
            echo "[entrypoint] postgres is ready"
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    echo "[entrypoint] WARN: postgres not reachable, continuing anyway" >&2
}

render_templates() {
    [ -d "$FS_TEMPLATE_DIR" ] || return 0
    echo "[entrypoint] rendering templates from $FS_TEMPLATE_DIR into $FS_CONF"

    # Start from a clean slate so stale files from a previous image or run
    # cannot linger and be picked up instead of the rendered ones.
    rm -rf "$FS_CONF"
    mkdir -p "$FS_CONF"

    # Only substitute the variables we actually own.
    #
    # FreeSWITCH uses $${...} for its own preprocessor variables, and plain
    # envsubst() replaces them too, collapsing "$${local_ip_v4}" to "$". That
    # silently breaks rtp-ip (RTP would not bind, so no audio) and dialplan
    # playback targets. Passing an explicit variable list makes envsubst leave
    # every other $ sequence untouched.
    vars='${ESL_PASSWORD} ${FS_DEFAULT_PASSWORD} ${FS_HOSTNAME} ${FS_DOMAIN} ${FS_LOCAL_IP} ${DOCKER_NETWORK_CIDR} ${PGHOST} ${PGPORT} ${PGUSER} ${PGPASSWORD} ${PGDATABASE}'

    find "$FS_TEMPLATE_DIR" -type f | while read -r tpl; do
        rel="${tpl#"$FS_TEMPLATE_DIR"/}"
        out="$FS_CONF/$rel"
        mkdir -p "$(dirname "$out")"
        envsubst "$vars" < "$tpl" > "$out"
        echo "[entrypoint]   $rel"
    done

    # Bail out loudly if a placeholder survived, rather than starting with a
    # literal "${...}" in a config value.
    if grep -rq '\${FS_\|\${ESL_\|\${DOCKER_NETWORK_CIDR}' "$FS_CONF"; then
        echo "[entrypoint] ERROR: unsubstituted placeholder in rendered config:" >&2
        grep -rn '\${FS_\|\${ESL_\|\${DOCKER_NETWORK_CIDR' "$FS_CONF" >&2
        exit 1
    fi
}

clear_xml_cache() {
    # FreeSWITCH memory-maps the preprocessed configuration from
    # freeswitch.xml.fsxml. If it survives a config change it is reused and the
    # new configuration is ignored.
    rm -f "$FS_LOG_DIR/freeswitch.xml.fsxml"
}

wait_for_pg
render_templates
clear_xml_cache

exec "$@"
