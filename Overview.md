# FreeSWITCH Docker Image

A containerized build of [FreeSWITCH](https://github.com/signalwire/freeswitch), the open-source software telephony platform (SIP/VoIP server), based on `debian:trixie-slim`.

## What's Included

- FreeSWITCH core built from source; the dependencies libks, sofia-sip, spandsp, and signalwire-c are also compiled from source
- English sound files and Music-on-Hold (`sounds-install`, `moh-install`)
- Multi-stage build — the final image ships only runtime libraries, not the build toolchain
- Module set defined by a custom [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in), copied over the upstream file during the build

## Enabled Modules

79 modules are compiled into the image and 54 of them are loaded at startup. [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in) is the source of truth for what gets built; `tools/gen-modules-conf.sh` turns it into the startup list.

The table below lists what is **loaded by default**.

| Category | Modules |
|---|---|
| Applications | av, bert, blacklist, callcenter, cidlookup, commands, conference, curl, db, directory, distributor, dptools, easyroute, esl, expr, fifo, hash, hiredis, httapi, http_cache, prefix, signalwire, sms, spandsp, translate, valet_parking, voicemail, voicemail_ivr |
| ASR/TTS | tts_commandline |
| Codecs | opus |
| Databases | mariadb, pgsql |
| Dialplans | dialplan_asterisk, dialplan_directory, dialplan_xml |
| Directories | ldap |
| Endpoints | loopback, sofia |
| Event Handlers | cdr_csv, cdr_sqlite, event_multicast, event_socket, format_cdr |
| Formats | native_file, opusfile, sndfile, tone_stream |
| Languages | lua, python3 |
| Loggers | console |
| Say | en |
| Timers | timerfd |
| XML Interfaces | xml_cdr, xml_rpc |

### Compiled but not loaded

The remaining 25 modules are built and present in `lib/freeswitch/mod/`, but left out of the startup list. Enable any of them by adding a `<load module="..."/>` line to your own `modules.conf.xml` — no rebuild is needed:

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

```bash
docker run -d --name freeswitch \
  --log-opt max-size=50m --log-opt max-file=5 \
  -p 5060:5060/udp -p 5060:5060/tcp \
  -p 8021:8021/tcp \
  -p 16384-16584:16384-16584/udp \
  -v $(pwd)/etc:/usr/local/freeswitch/etc \
  -v $(pwd)/lib:/usr/local/freeswitch/var/lib \
  <image>
```

To get a starting configuration:

```bash
docker run --rm <image> tar -C /usr/local/freeswitch -cf - etc/freeswitch | tar -xf -
```

## Customization

- **Configuration**: mount your own config over `/usr/local/freeswitch/etc/freeswitch`, or extract the default set out of the image first as a starting point.
- **Persistent state**: mount `var/lib/freeswitch` to avoid losing registrations, CDRs, and recorded calls on container recreation.
- **Log files on disk**: add `mod_logfile` back with a `<load module="mod_logfile"/>` line, then bound the file from outside the container — see Maintenance.
- **PostgreSQL**: `postgresql-client` and ODBC support (`--enable-core-odbc-support`, `unixodbc`) are built in, so the core DB can point at an external Postgres/MariaDB instead of the bundled sqlite.
- **RTP range**: set `rtp-start-port`/`rtp-end-port` in `autoload_configs/switch.conf.xml` and publish the same range.
- **Additional/replacement codecs**: `mod_amr` and `mod_amrwb` are already compiled in — just add a `<load>` line. For something not built at all (G.729, G.723.1, Codec2), rebuild with a modified `modules.conf.in` — see Disclaimer for the licensing considerations that come with the codecs.

## Constraints

- **Module list is fixed at build time.** Modules not in `modules.conf.in` cannot be loaded at runtime.
- **Single architecture.** The final stage copies `libks2.so*`, `libsofia-sip-ua.so*`, `libsignalwire_client2.so*`, and `libspandsp.so*` from hardcoded `x86_64`/`lib` paths, so this image (as-is) only supports `amd64`.
- **Default credentials are live.** The shipped `event_socket.conf.xml` listens on `::` port `8021` with the well-known password `ClueCon`, and the `loopback.auto` ACL is commented out. That means anyone who can reach the port can control the switch. Override these via your own config mount before exposing the container to any untrusted network.
- **No TLS certificates.** `make install` does not create a `certs/` or `tls/` directory. Run `gentls_cert` (in `bin/`) or supply your own if you enable TLS SIP profiles.
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
