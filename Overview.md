# FreeSWITCH Docker Image

A containerized build of [FreeSWITCH](https://github.com/signalwire/freeswitch), the open-source software telephony platform (SIP/VoIP server), based on `debian:trixie-slim`.

## What's Included

- FreeSWITCH core built from source; the dependencies libks, sofia-sip, spandsp, and signalwire-c are also compiled from source
- English sound files and Music-on-Hold (`sounds-install`, `moh-install`)
- Multi-stage build — the final image ships only runtime libraries, not the build toolchain
- Module set defined by a custom [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in), copied over the upstream file during the build

## Enabled Modules

79 modules are compiled into the image and 53 of them are loaded at startup. [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in) is the source of truth for what gets built; `tools/gen-modules-conf.sh` turns it into the startup list.

The table below lists what is **loaded by default**.

| Category | Modules |
|---|---|
| Applications | av, bert, blacklist, callcenter, cidlookup, commands, conference, curl, db, directory, distributor, dptools, easyroute, esl, expr, fifo, hash, hiredis, httapi, http_cache, prefix, sms, spandsp, translate, valet_parking, voicemail, voicemail_ivr |
| ASR/TTS | tts_commandline |
| Codecs | opus |
| Databases | mariadb, pgsql |
| Dialplans | dialplan_asterisk, dialplan_directory, dialplan_xml |
| Directories | ldap |
| Endpoints | loopback, sofia |
| Event Handlers | cdr_csv, event_multicast, event_socket, format_cdr |
| Formats | native_file, opusfile, sndfile, tone_stream |
| Languages | lua, python3 |
| Loggers | console |
| Say | en |
| Timers | timerfd |
| XML Interfaces | xml_cdr, xml_rpc |

### Compiled but not loaded

The remaining 26 modules are built and present in `lib/freeswitch/mod/`, but left out of the startup list. Enable any of them by adding a `<load module="..."/>` line to your own `modules.conf.xml` — no rebuild is needed:

| Modules | Why they are not loaded |
|---|---|
| `mod_lcr`, `mod_fail2ban`, `mod_json_cdr`, `mod_odbc_cdr`, `mod_xml_curl`, `mod_xml_ldap` | Fail their load routine unless you supply a config file upstream does not ship, so they would log a `[CRIT]` on every boot |
| `mod_signalwire` | Remote Address Error. |
| `mod_amqp` | Retries its broker connection forever, flooding the log |
| `mod_amr`, `mod_amrwb` | Load and transcode fine, but AMR/AMR-WB carry patent obligations in most jurisdictions |
| `mod_spy` | Installs surveillance commands (`spy`, `eavesdrop`) |
| `mod_skinny`, `mod_verto`, `mod_rtc` | Legacy Cisco SCCP and WebRTC signalling that `mod_sofia` already covers |
| `mod_enum`, `mod_fsk`, `mod_b64`, `mod_png` | ENUM resolution, legacy FSK caller-ID, and internal-use formats |
| `mod_shout`, `mod_local_stream` | Streaming and local stream playback; Music-on-Hold uses WAV via `mod_sndfile` |
| `mod_nibblebill`, `mod_avmd`, `mod_video_filter` | Prepaid billing, outbound beep detection, and video filtering |
| `mod_xml_scgi` | SCGI XML backend; logs a connection failure unless a server is running |
| `mod_cdr_sqlite` | Writes CDRs to a local sqlite file, which cannot be read by anything outside the container and duplicates the CSV/original CDR output already in place |
| `mod_logfile` | Writes a second copy of every line to `var/log/freeswitch/freeswitch.log`, which nothing in the image rotates. Logs go to stdout instead, where `docker logs` and its `--log-opt max-size`/`max-file` can bound them. |
| `mod_syslog` | Publishes to syslog; the image runs no syslog daemon, so it was writing into a socket nobody read |

`mod_av` **is** loaded by default (FFmpeg-based video/recording support); see Disclaimer for the GPL/LGPL and H.264/AAC considerations that come with it.

## Directory Layout (prefix: `/usr/local/freeswitch`)

The prefix uses the FHS layout, so paths differ from the source tree's defaults:

| Purpose | Path |
|---|---|
| Configuration | `/usr/local/freeswitch/etc/freeswitch/` |
| Logs | `/usr/local/freeswitch/var/log/freeswitch/` |
| Core DB (sqlite) | `/usr/local/freeswitch/var/lib/freeswitch/db/` |
| Recordings | `/usr/local/freeswitch/var/lib/freeswitch/recordings/` |
| HTTP cache | `/usr/local/freeswitch/var/lib/freeswitch/storage/` |
| Images | `/usr/local/freeswitch/var/lib/freeswitch/images/` |
| PID file | `/usr/local/freeswitch/var/run/freeswitch/` |
| Sounds / MoH | `/usr/local/freeswitch/share/freeswitch/sounds/` |
| Scripts | `/usr/local/freeswitch/share/freeswitch/scripts/` |
| Modules | `/usr/local/freeswitch/lib/freeswitch/mod/` |
| Binaries | `/usr/local/freeswitch/bin/` |

## Maintenance

Everything FreeSWITCH writes lives under `var/`. Left alone, **nothing reclaims it**: the image ships no `logrotate`, no `cron`, and no `sqlite3`. Plan for growth before you deploy, not after the disk fills.

Logs themselves are not on this list. `mod_logfile` and `mod_syslog` are deliberately not loaded, so every log line goes to stdout and it is Docker, not FreeSWITCH, that owns the file. Bound it at run time:

```bash
--log-opt max-size=50m --log-opt max-file=5
```

Without those options `docker logs` grows without limit. With them, no log file accumulates inside the container at all.

| What | Grows because | Maintenance |
|---|---|---|
| `var/log/freeswitch/{cdr-csv,format_cdr,xml_cdr}/` | One file per call | Rotate, or ship CDRs to Postgres/MariaDB via `mod_pgsql`/`mod_mariadb` and stop writing files. |
| `var/lib/freeswitch/recordings/` | One file per call when recording is enabled | Rotate/archive. Never delete without checking retention obligations. |
| `var/lib/freeswitch/storage/` | `mod_http_cache` caches fetched files and never expires them; voicemail recordings (`vm.conf.xml` default `storage-dir`) are also written under `storage/voicemail/default/<domain>/<user>/` in this same tree | Prune HTTP cache periodically, but do not blindly wipe this directory — voicemail `.wav` files live here too and must be preserved/backed up separately. |
| `var/lib/freeswitch/db/` | Registrations, queues, CDRs, voicemail | **Back this up, but do not prune it.** Deleting `core.db` or `sofia_reg_*.db` drops every registration; `callcenter.db`, `fifo.db`, and `voicemail_default.db` hold live state. |

`var/log/freeswitch/freeswitch.xml.fsxml` is also written on every config reload. It is fixed in size and regenerated, so it needs no attention.

If you want a log file on disk after all — for a local tail without going through the Docker daemon — add `mod_logfile` back to your own `modules.conf.xml` and rotate it from the host, since FreeSWITCH holds the file open and the image has no `logrotate`:

```
# host logrotate, referenced against the mounted volume
/path/to/log/freeswitch.log {
    daily
    rotate 7
    copytruncate
    compress
    missingok
    notifempty
}
```

## Ports

Publish the ports you need with `-p`. Nothing listens until the corresponding module and profile are configured.

- `5060/udp`, `5060/tcp` — SIP signaling (internal profile)
- `5080/udp`, `5080/tcp` — SIP signaling (external profile)
- `8021/tcp` — Event Socket Library (ESL)
- RTP range — upstream's `rtp-start-port`/`rtp-end-port` are commented out in `autoload_configs/switch.conf.xml`, so **no fixed range applies until you set one**. Size the range to your expected concurrent call count, then publish it.

## Usage

docker-compose.yml

```docker-compose.yml
# ==============================================================================
# FreeSWITCH docker-compose
# ==============================================================================
#
# Usage
# -----
#   1. Extract the default config into ./etc (required before first run):
#        docker run --rm yukiosaka/freeswitch:latest \
#          tar -C /usr/local/freeswitch -cf - etc/freeswitch \
#          | tar -xf - --strip-components=1 -C ./etc
#
#   2. mkdir -p ./secrets && chmod 700 ./secrets
#
#   3. docker compose up -d
#      On first boot the container generates a self-signed TLS cert and
#      writes it to ./secrets/tls, then starts FreeSWITCH normally. On
#      subsequent restarts, if ./secrets/tls already exists, it is
#      reused as-is instead of being regenerated.
#
#   4. Check what was generated:
#        ls ./secrets/tls
#
# Customization
# -------------
#   Security hardening still required before exposing this to any
#   untrusted network — none of the following are automated by this
#   compose:
#
#   1. ESL default password
#      File: ./etc/freeswitch/autoload_configs/event_socket.conf.xml
#      Fix:  replace the "ClueCon" password with a strong random value.
#
#   2. ESL ACL
#      File: ./etc/freeswitch/autoload_configs/event_socket.conf.xml
#      Fix:  uncomment/configure the <ACL> section (e.g. "loopback.auto")
#            so only trusted hosts/containers can connect, even on the
#            internal network.
#
#   3. SIP directory default passwords
#      File: ./etc/freeswitch/vars.xml
#      Fix:  change the default_password variable from its shipped
#            value to a strong random value (used by extensions under
#            directory/default/*.xml).
#
#   4. SIP directory per-extension overrides
#      File: ./etc/freeswitch/directory/default/*.xml (e.g. 1000.xml)
#      Fix:  remove or set an individual strong password per extension
#            instead of relying solely on the shared default_password.
#
#   5. RTP port range
#      File: ./etc/freeswitch/autoload_configs/switch.conf.xml
#      Fix:  uncomment and set rtp-start-port / rtp-end-port explicitly
#            to match the "ports:" range below (16384-18383). Left
#            commented out, FreeSWITCH defaults to the full 16384-32768
#            span, wider than what is actually published.
#
#   6. SIP TLS profile
#      File: ./etc/freeswitch/sip_profiles/internal.xml (and/or external.xml)
#      Fix:  add a TLS-enabled profile pointing at the certs generated
#            under ./secrets/tls, then restart the profile
#            (`sofia profile <name> restart`) — SIP is plaintext until
#            this is done.
#
#   Non-security customization:
#   - RTP capacity: match ports: above to your expected concurrent call
#     count (~2 RTP ports per call) when setting item 5.
#   - Self-signed cert: on first start this compose generates one via
#     gentls_cert into ./secrets/tls and reuses it on later restarts —
#     see item 6 to actually wire it into a SIP profile.
#   - Anything else not covered above (dialplans, additional modules,
#     etc.) — edit XML under ./etc/freeswitch/ directly and run
#     `fs_cli reloadxml` (or restart the container).

version: "3.8"

services:
  freeswitch:
    image: yukiosaka/freeswitch:latest
    container_name: freeswitch
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    ports:
      - "5060:5060/udp"
      - "5060:5060/tcp"
      - "5080:5080/udp"
      - "5080:5080/tcp"
      - "16384-18383:16384-18383/udp"
      # ESL — intentionally commented out and NOT hardened by this
      # compose (default password "ClueCon", open ACL unchanged). Only
      # uncomment after changing the password/ACL yourself in
      # event_socket.conf.xml (see Customization item 1-2), and prefer
      # reaching it from other containers on the "internal" network
      # instead of publishing to the host.
      # - "8021:8021/tcp"
    volumes:
      - ./etc:/usr/local/freeswitch/etc
      - ./secrets:/secrets
      - fs-db:/usr/local/freeswitch/var/lib/freeswitch/db
      - fs-recordings:/usr/local/freeswitch/var/lib/freeswitch/recordings
      - fs-storage:/usr/local/freeswitch/var/lib/freeswitch/storage
      - fs-log:/usr/local/freeswitch/var/log/freeswitch
    networks:
      - internal
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        ETC=/usr/local/freeswitch/etc/freeswitch
        if [ ! -d /secrets/tls ]; then
          /usr/local/freeswitch/bin/gentls_cert sip
          cp -r "$$ETC/tls" /secrets/tls
        else
          rm -rf "$$ETC/tls"
          cp -r /secrets/tls "$$ETC/tls"
        fi
        exec /usr/bin/tini -- /usr/local/bin/docker-entrypoint.sh freeswitch -nonat -nf -c

networks:
  internal:
    driver: bridge

volumes:
  fs-db:
  fs-recordings:
  fs-storage:
  fs-log:
```

## Customization

See the docker-compose.yml above for step-by-step hardening (ESL password/ACL, SIP directory passwords, RTP range, TLS profile). This section covers config not tied to that specific compose file:

- **Configuration**: mount your own config over `/usr/local/freeswitch/etc/freeswitch`, or extract the default set out of the image first as a starting point.
- **Persistent state**: mount `var/lib/freeswitch` to avoid losing registrations, CDRs, and recorded calls on container recreation.
- **PostgreSQL**: `postgresql-client` and ODBC support (`--enable-core-odbc-support`, `unixodbc`) are built in, so the core DB can point at an external Postgres/MariaDB instead of the bundled sqlite.

## Constraints

- **mod_fail2ban is not available.** You **MUST** configure and enable outside of this image.
- **Module list is fixed at build time.** Modules not in `modules.conf.in` cannot be loaded at runtime.
- **Single architecture.** The final stage copies `libks2.so*`, `libsofia-sip-ua.so*`, `libsignalwire_client2.so*`, and `libspandsp.so*` from hardcoded `x86_64`/`lib` paths, so this image (as-is) only supports `amd64`.
- **Default credentials are live.** The shipped `event_socket.conf.xml` listens on `::` port `8021` with the well-known password `ClueCon`, and the `loopback.auto` ACL is commented out. That means anyone who can reach the port can control the switch. Override these via your own config mount before exposing the container to any untrusted network.
- **No TLS certificates.** `make install` does not create a `certs/` or `tls/` directory. Run `gentls_cert` (in `bin/`) or supply your own if you enable TLS SIP profiles — the docker-compose.yml above automates this via `gentls_cert`, writing certs to `./secrets/tls`, but still requires you to wire them into a SIP profile manually (see Customization item 6 in the compose file).
- **No named volumes declared.** Config, logs, and DB directories are not `VOLUME`-declared, so data is ephemeral unless you explicitly bind/volume-mount those paths.
- **tini as PID 1** handles signal forwarding (SIGTERM/SIGHUP); graceful shutdown and reload behavior depend on FreeSWITCH's own signal handling.

## Disclaimer

This image is provided "as is", without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. **Use it at your own risk.**

The maintainer(s) of this image are not affiliated with SignalWire or the FreeSWITCH project, and provide no guarantee of production-readiness, security hardening, or fitness for any telephony/regulatory use case (e.g. E911, lawful intercept, CALEA, GDPR, HIPAA). You are solely responsible for:

- reviewing and hardening default credentials, ACLs, and exposed ports before any network-facing deployment
- compliance with applicable telecom regulations in your jurisdiction
- verifying license compliance for all bundled and third-party dependencies. FreeSWITCH itself is MPL 1.1. `mod_amr` and `mod_amrwb` are compiled in but not loaded by default: AMR/AMR-WB carry patent obligations in most jurisdictions, so enabling them is your decision. `mod_av` is linked against FFmpeg and loaded by default, which raises GPL/LGPL relicensing questions and possible H.264/AAC patent exposure depending on how you use it
- any data loss, service interruption, toll fraud, or other damages arising from use of this image

No support or SLA is implied. Issues can be filed on the repository, but response and fixes are not guaranteed.
