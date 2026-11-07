# FreeSWITCH Docker Image

A containerized build of [FreeSWITCH](https://github.com/signalwire/freeswitch), the open-source SIP/VoIP telephony platform, based on `ubuntu:24.04`.

## docker-compose.yml

```yaml
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
      - "16384-16583:16384-16583/udp"
    volumes:
      - ./etc:/usr/local/freeswitch/etc
      - fs-db:/usr/local/freeswitch/var/lib/freeswitch/db
      - fs-recordings:/usr/local/freeswitch/var/lib/freeswitch/recordings
      - fs-storage:/usr/local/freeswitch/var/lib/freeswitch/storage
      - fs-log:/usr/local/freeswitch/var/log/freeswitch
    networks:
      - internal

networks:
  internal:
    driver: bridge

volumes:
  fs-db:
  fs-recordings:
  fs-storage:
  fs-log:
```

ESL (`8021/tcp`) is intentionally not published. See [`docker-compose.yml`](docker-compose.yml) for the annotated version and a hardening checklist.

## Quick Start

```bash
# 1. Extract the default config so you can edit it on the host
mkdir etc
docker run --rm yukiosaka/freeswitch:latest \
  tar -C /usr/local/freeswitch -cf - etc/freeswitch \
  | tar -xf - --strip-components=1 -C ./etc

# 2. Start
docker compose up -d

# 3. Change the default passwords before exposing the container (see Warnings)
```

## Warnings

| Item | Default | What to do |
|---|---|---|
| ESL password | `ClueCon`, bound to `::` with the `loopback.auto` ACL commented out | Change the password and enable the ACL in `autoload_configs/event_socket.conf.xml` before publishing port `8021` |
| SIP directory password | `default_password=1234` in `vars.xml` | Change it; it authenticates every extension under `directory/default/` |
| Architecture | `amd64` only | The final stage copies libraries from hardcoded `x86_64` paths, so the image does not run on arm64 |
| Module set | Fixed at build time | Modules not in `modules.conf.in` cannot be loaded at runtime, even by editing `modules.conf.xml` |
| `mod_fail2ban` | Not available | Must be configured and enabled outside this image |

## Ports

Nothing listens until the matching module and profile are configured. Publish only what you need.

| Port | Purpose |
|---|---|
| `5060/udp`, `5060/tcp` | SIP signaling (internal profile) |
| `5080/udp`, `5080/tcp` | SIP signaling (external profile) |
| `8021/tcp` | Event Socket Library (ESL) |
| `16384-16583/udp` | RTP media. The image pins `rtp-start-port`/`rtp-end-port` to this range in `switch.conf.xml` (the Dockerfile patches upstream's commented-out defaults), so allocating a port outside the published range cannot happen. ~2 ports per concurrent call, i.e. ~100 calls. Widen both the image and the compose `ports:` entry together if you need more. |

## Configuration

Mount these three paths to keep your changes and state across container recreation:

| Mount | Path inside the container | Contents |
|---|---|---|
| Config | `/usr/local/freeswitch/etc/freeswitch` | XML configuration, plus the `tls/` material FreeSWITCH generates on first boot |
| State | `/usr/local/freeswitch/var/lib/freeswitch` | Core DB, registrations, queues, recordings, voicemail, HTTP cache |
| Logs | `/usr/local/freeswitch/var/log/freeswitch` | CDR output and the compiled config dump |

The image prefix follows the FHS layout:

| Purpose | Path |
|---|---|
| Binaries | `/usr/local/freeswitch/bin/` |
| Modules | `/usr/local/freeswitch/lib/freeswitch/mod/` |
| Sounds / MoH | `/usr/local/freeswitch/share/freeswitch/sounds/` |
| Scripts | `/usr/local/freeswitch/share/freeswitch/scripts/` |
| PID file | `/usr/local/freeswitch/var/run/freeswitch/` |

Notes:

- **PostgreSQL**: `postgresql-client` and ODBC support (`--enable-core-odbc-support`, `unixodbc`) are built in, so the core DB can point at an external Postgres/MariaDB instead of the bundled sqlite.
- **TLS**: `make install` creates no `tls/` directory. FreeSWITCH writes a self-signed `tls/wss.pem` and `tls/dtls-srtp.pem` itself on first boot and reuses them afterwards, so the `etc` mount above preserves them. SIP TLS stays off until you set `internal_ssl_enable` / `external_ssl_enable` in `vars.xml`.
- **Nothing is `VOLUME`-declared**, so data is ephemeral unless you mount the paths above.

## Modules

79 modules are compiled into the image and 53 are loaded at startup. [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in) is the source of truth for what gets built; `tools/gen-modules-conf.sh` turns it into the startup list.

<details>
<summary>Loaded by default (53)</summary>

| Category | Modules |
|---|---|
| Applications | signalwire, av, bert, blacklist, callcenter, cidlookup, commands, conference, curl, db, directory, distributor, dptools, easyroute, esl, expr, fifo, hash, hiredis, httapi, http_cache, prefix, sms, spandsp, translate, valet_parking, voicemail, voicemail_ivr |
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

</details>

<details>
<summary>Compiled but not loaded (26)</summary>

The remaining 26 modules are built and present in `lib/freeswitch/mod/`, but left out of the startup list. Enable any of them by adding a `<load module="..."/>` line to your own `modules.conf.xml` — no rebuild is needed.

| Modules | Why they are not loaded |
|---|---|
| `mod_lcr`, `mod_fail2ban`, `mod_json_cdr`, `mod_odbc_cdr`, `mod_xml_curl`, `mod_xml_ldap` | Fail their load routine unless you supply a config file upstream does not ship, so they would log a `[CRIT]` on every boot |
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

</details>

## Maintenance

Everything FreeSWITCH writes lives under `var/`. Left alone, **nothing reclaims it**: the image ships no `logrotate`, no `cron`, and no `sqlite3`. Plan for growth before you deploy, not after the disk fills.

Logs are the exception. `mod_logfile` and `mod_syslog` are deliberately not loaded, so every log line goes to stdout and Docker owns the file. Bound it with the `logging:` options in `docker-compose.yml`:

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

Without those options `docker logs` grows without limit. With them, no log file accumulates inside the container at all.

| What | Grows because | Maintenance |
|---|---|---|
| `var/log/freeswitch/{cdr-csv,format_cdr,xml_cdr}/` | One file per call | Rotate, or ship CDRs to Postgres/MariaDB via `mod_pgsql`/`mod_mariadb` and stop writing files. |
| `var/lib/freeswitch/recordings/` | One file per call when recording is enabled | Rotate/archive. Never delete without checking retention obligations. |
| `var/lib/freeswitch/storage/` | `mod_http_cache` caches fetched files and never expires them; voicemail recordings (`vm.conf.xml` default `storage-dir`) are also written under `storage/voicemail/default/<domain>/<user>/` in this same tree | Prune HTTP cache periodically, but do not blindly wipe this directory — voicemail `.wav` files live here too and must be preserved/backed up separately. |
| `var/lib/freeswitch/db/` | Registrations, queues, CDRs, voicemail | **Back this up, but do not prune it.** Deleting `core.db` or `sofia_reg_*.db` drops every registration; `callcenter.db`, `fifo.db`, and `voicemail_default.db` hold live state. |

`var/log/freeswitch/freeswitch.xml.fsxml` is also written on every config reload. It is fixed in size and regenerated, so it needs no attention.

## References

- [`docker-compose.yml`](docker-compose.yml) — annotated version of the compose file above, with a hardening checklist
- [`modules.conf.in`](modules.conf.in) — the module list the image is built from
- [`Dockerfile`](Dockerfile) — multi-stage build; the final image ships only runtime libraries, not the build toolchain
- [FreeSWITCH documentation](https://developer.signalwire.com/freeswitch/)

## Disclaimer

This image is provided "as is", without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. **Use it at your own risk.**

The maintainer(s) of this image are not affiliated with SignalWire or the FreeSWITCH project, and provide no guarantee of production-readiness, security hardening, or fitness for any telephony/regulatory use case (e.g. E911, lawful intercept, CALEA, GDPR, HIPAA). You are solely responsible for:

- reviewing and hardening default credentials, ACLs, and exposed ports before any network-facing deployment
- compliance with applicable telecom regulations in your jurisdiction
- verifying license compliance for all bundled and third-party dependencies. FreeSWITCH itself is MPL 1.1. `mod_amr` and `mod_amrwb` are compiled in but not loaded by default: AMR/AMR-WB carry patent obligations in most jurisdictions, so enabling them is your decision. `mod_av` is linked against FFmpeg and loaded by default, which raises GPL/LGPL relicensing questions and possible H.264/AAC patent exposure depending on how you use it
- any data loss, service interruption, toll fraud, or other damages arising from use of this image

No support or SLA is implied. Issues can be filed on the repository, but response and fixes are not guaranteed.
