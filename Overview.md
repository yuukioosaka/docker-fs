# FreeSWITCH Docker Image

A containerized build of [FreeSWITCH](https://github.com/signalwire/freeswitch), the open-source software telephony platform (SIP/VoIP server), based on `debian:trixie-slim`.

## What's Included

- FreeSWITCH core built from source; the dependencies libks, sofia-sip, spandsp, and signalwire-c are also compiled from source
- English sound files and Music-on-Hold (`sounds-install`, `moh-install`)
- Multi-stage build — the final image ships only runtime libraries, not the build toolchain
- Module set defined by a custom [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in), copied over the upstream file during the build; the startup module list is generated from it by `tools/gen-modules-conf.sh`
- FreeSWITCH version pinned by [`FS_VERSION`](https://github.com/yuukioosaka/docker-fs/blob/main/FS_VERSION) and resolved to the latest upstream release tag by CI

## Enabled Modules

80 modules are compiled into the image. `modules.conf.in` is the source of truth; the table below mirrors it.

The image is ~563MB, down from ~1.5GB before slimming. Two things keep it there: `--no-install-recommends` on every apt install, and an apt package list that names only the libraries an enabled module actually links against.

| Category | Modules |
|---|---|
| Applications | avmd, bert, blacklist, callcenter, cidlookup, commands, conference, curl, db, directory, distributor, dptools, easyroute, enum, esl, expr, fifo, fsk, hash, hiredis, httapi, http_cache, lcr, nibblebill, prefix, redis, signalwire, sms, spandsp, translate, valet_parking, video_filter, vmd, voicemail, voicemail_ivr |
| ASR/TTS | tts_commandline |
| Codecs | b64, codec2, g723_1, g729, opus |
| Databases | mariadb, pgsql |
| Dialplans | dialplan_asterisk, dialplan_directory, dialplan_xml |
| Directories | ldap |
| Endpoints | loopback, rtc, skinny, sofia, verto |
| Event Handlers | amqp, cdr_csv, cdr_sqlite, event_multicast, event_socket, fail2ban, format_cdr, json_cdr, odbc_cdr |
| Formats | local_stream, native_file, opusfile, png, shout, sndfile, tone_stream |
| Languages | lua, python3 |
| Loggers | console, logfile, syslog |
| Say | en |
| Timers | timerfd |
| XML Interfaces | xml_cdr, xml_curl, xml_ldap, xml_rpc, xml_scgi |

Upstream's shipped autoload list names every module it knows about, including ones this build does not compile, which makes FreeSWITCH log a `[CRIT]` for each at every startup. The generated list contains only what is actually present.

## Directory Layout (prefix: `/usr/local/freeswitch`)

The prefix uses the FHS layout, so paths differ from the source tree's defaults:

| Purpose | Path |
|---|---|
| Configuration | `/usr/local/freeswitch/etc/freeswitch/` |
| Logs | `/usr/local/freeswitch/var/log/freeswitch/` |
| Core DB (sqlite) | `/usr/local/freeswitch/var/lib/freeswitch/db/` |
| Recordings | `/usr/local/freeswitch/var/lib/freeswitch/recordings/` |
| Images | `/usr/local/freeswitch/var/lib/freeswitch/images/` |
| PID file | `/usr/local/freeswitch/var/run/freeswitch/` |
| Sounds / MoH | `/usr/local/freeswitch/share/freeswitch/sounds/` |
| Scripts | `/usr/local/freeswitch/share/freeswitch/scripts/` |
| Modules | `/usr/local/freeswitch/lib/freeswitch/mod/` |
| Binaries | `/usr/local/freeswitch/bin/` |

## Ports

No ports are declared with `EXPOSE`; publish the ones you need with `-p`. Nothing listens until the corresponding module and profile are configured.

- `5060/udp`, `5060/tcp` — SIP signaling (internal profile)
- `5080/udp`, `5080/tcp` — SIP signaling (external profile)
- `8021/tcp` — Event Socket Library (ESL)
- RTP range — upstream's `rtp-start-port`/`rtp-end-port` are commented out in `autoload_configs/switch.conf.xml`, so **no fixed range applies until you set one**. Size the range to your expected concurrent call count, then publish it.

## Usage

```bash
docker run -d --name freeswitch \
  -p 5060:5060/udp -p 5060:5060/tcp \
  -p 8021:8021/tcp \
  -p 16384-16584:16384-16584/udp \
  -v $(pwd)/etc:/usr/local/freeswitch/etc \
  -v $(pwd)/log:/usr/local/freeswitch/var/log \
  -v $(pwd)/db:/usr/local/freeswitch/var/lib \
  <image>
```

To get a starting configuration:

```bash
docker run --rm <image> tar -C /usr/local/freeswitch -cf - etc/freeswitch | tar -xf -
```

## Customization

- **Configuration**: mount your own config over `/usr/local/freeswitch/etc/freeswitch`, or extract the default set out of the image first as a starting point.
- **Environment substitution**: `gettext-base` (`envsubst`) is installed, but `docker-entrypoint.sh` does **not** use it — the entrypoint is a plain `exec "$@"` and no config templating happens. Render your config yourself before mounting it.
- **Persistent state**: mount `var/lib/freeswitch` to avoid losing registrations, CDRs, and recorded calls on container recreation.
- **PostgreSQL**: `postgresql-client` and ODBC support (`--enable-core-odbc-support`, `unixodbc`) are built in, so the core DB can point at an external Postgres/MariaDB instead of the bundled sqlite.
- **RTP range**: set `rtp-start-port`/`rtp-end-port` in `autoload_configs/switch.conf.xml` and publish the same range.
- **CMD override**: default is `freeswitch -nonat -nf -c`; override `CMD` to change startup flags (e.g. remove `-nonat` if not behind NAT).
- **`FREESWITCH_OPTS`**: if you set this variable, FreeSWITCH appends it to its argument list. Note the value is split on spaces, so arguments containing spaces cannot be passed this way.

## Constraints

- **Module list is fixed at build time.** Modules not in `modules.conf.in` cannot be loaded at runtime; adding one requires rebuilding the image. `mod_amqp` is the exception: it is compiled in but not autoloaded, so it can be turned on purely by config.
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
- verifying license compliance for all bundled and third-party dependencies (FreeSWITCH is MPL 1.1; some optional codecs/libraries, e.g. G.729, may carry separate licensing/patent obligations depending on your usage and region)
- any data loss, service interruption, toll fraud, or other damages arising from use of this image

No support or SLA is implied. Issues can be filed on the repository, but response and fixes are not guaranteed.
