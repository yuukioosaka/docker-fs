# FreeSWITCH Docker Image

A containerized build of [FreeSWITCH](https://github.com/signalwire/freeswitch), the open-source software telephony platform (SIP/VoIP server), based on `debian:trixie-slim`.

## What's Included

- FreeSWITCH core built from source; the dependencies libks, sofia-sip, spandsp, and signalwire-c are also compiled from source
- English sound files and Music-on-Hold (`sounds-install`, `moh-install`)
- Multi-stage build — the final image ships only runtime libraries, not the build toolchain
- Module set defined by a custom [`modules.conf.in`](https://github.com/yuukioosaka/docker-fs/blob/main/modules.conf.in), copied over the upstream file during the build; the startup module list is generated from it by `tools/gen-modules-conf.sh`
- FreeSWITCH version pinned by [`FS_VERSION`](https://github.com/yuukioosaka/docker-fs/blob/main/FS_VERSION) and resolved to the latest upstream release tag by CI

## Enabled Modules

80 modules. `modules.conf.in` is the source of truth; the table below mirrors it.

The image is ~563MB, down from ~1.5GB before the slimming described in "Why modules are disabled". Two things keep it there: `--no-install-recommends` on every apt install, and an apt package list that names only the libraries an enabled module actually links against.

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

The startup module list is generated from the same file by [`tools/gen-modules-conf.sh`](https://github.com/yuukioosaka/docker-fs/blob/main/tools/gen-modules-conf.sh). Upstream's shipped autoload list names every module it knows about, including ones this build does not compile, which makes FreeSWITCH log a `[CRIT]` for each at every startup. The generated list contains only what is actually present.

### Built but not autoloaded

One module is compiled into the image but left out of the startup list, because it cannot work until you supply configuration:

| Module | Reason | How to enable |
|---|---|---|
| `mod_amqp` | Loads and immediately connects to an AMQP broker. With the default config and no broker running it retries forever, filling the log with `[CRIT]`/`[WARNING]` every second. | Add `<load module="mod_amqp"/>` to your own `modules.conf.xml` and provide `amqp.conf.xml` |

This is an autoload decision only — `mod_amqp.so` is present in `/usr/local/freeswitch/lib/freeswitch/mod/`, so re-enabling it needs no rebuild. The generator holds the list in its `NOT_AUTOLOAD_MODULES` array.

### Why modules are disabled

The list is deliberately narrower than upstream. Three reasons drive the exclusions.

**Dependencies missing from Debian.** These cannot be built without vendoring the library from source: `mod_bv`, `mod_ilbc`, `mod_silk`, `mod_siren`, `mod_flite`, `mod_h323`, `mod_opal`, `mod_osp`, `mod_cdr_pg_csv`, `mod_managed`, `mod_java`, `mod_v8`, `mod_perl`, `mod_basic`.

**Warnings promoted to errors.** Upstream builds with `-Werror`, and these modules no longer compile cleanly against current libraries: `mod_mongo` (deprecated `mongoc_collection_find`), `mod_smpp` (`stringop-truncation`).

**No purpose in a container or best avoided:**

| Module | Reason |
|---|---|
| `mod_alsa` | No sound card in a container |
| `mod_rtmp` | RTMP/Flash is end-of-life |
| `mod_test` | Developer test module |
| `mod_cluechoo`, `mod_esf` | Joke / sound-effect modules |
| `mod_fsv` | Proprietary recording format |
| `mod_snapshot` | Narrow use case; `mod_sndfile` covers most needs |
| `mod_spy` | Call interception — unnecessary attack surface |
| `mod_shell_stream` | Executes shell commands — unnecessary attack surface |
| `mod_av`, `mod_cv`, `mod_imagick`, `mod_vlc` | Video/image processing. Their libraries also pull in large GL/LLVM/GDAL/X11 chains, and ffmpeg alone carries ~40 CVEs that Debian does not plan to fix |
| `mod_pocketsphinx` | Speech recognition; the acoustic model alone is 15MB |
| `mod_amr`, `mod_amrwb` | Narrow mobile-codec use case |
| `mod_graylog2`, `mod_erlang_event` | Only useful if you run Graylog / Erlang |
| `mod_memcache`, `mod_snmp` | Only useful if you use those services |

`mod_amr` deserves an extra note: upstream's `configure` looks for `opencore-amrnb`, which was never in this image's apt list, so the module had silently failed to build long before it was disabled. If you need AMR-NB, re-enable `codecs/mod_amr` **and** add `libopencore-amrnb-dev` and `libopencore-amrnb0` to the two apt blocks.

If your dialplan or config depends on any of these, fork and rebuild with a modified `modules.conf.in`.

### Modules that cannot be disabled

`mod_spandsp` **cannot** be removed by commenting it out of `modules.conf.in`, even if you do not need FAX/T.38:

- `configure.ac` gates on `PKG_CHECK_MODULES([SPANDSP], [spandsp >= 3.1.1])` with a hard `AC_MSG_ERROR`, and there is no `--disable-spandsp` escape hatch.
- `src/switch_spandsp.c` is compiled into `libfreeswitch` itself, and `Makefile.am` adds `$(SPANDSP_CFLAGS)` / `$(SPANDSP_LIBS)` to the core.

So the `spandsp` source build and the `libspandsp.so*` copy in the final stage must stay regardless of the module list. This is also why `libtiff` and `libjpeg` are present: `libspandsp.so` links against both directly, even though no FreeSWITCH module or config references them. Dropping them would leave `mod_spandsp`, `mod_sndfile`, and every other module that loads `libfreeswitch` unresolvable.

Note that a module being absent from `.so` output does not prove it is absent from the core: always check `src/switch_*.c` and the `*_LIBADD` lines in `Makefile.am` before treating a dependency as removable.

## Base Image and Vulnerabilities

The image builds on `debian:trixie-slim` (Debian 13). Trixie is a supported build target upstream: FreeSWITCH's `debian/control-modules` carries explicit `Build-Depends-Bookworm` and `Build-Depends-Trixie` lines.

Debian trixie ships **tiff 4.7.x**, which resolves the Critical and High libtiff findings present in bookworm's 4.5.0 (those fixes exist only in 4.7.2 and were never backported to bookworm). Moving to trixie took the image from 4 Critical / 13 High to **0 Critical / 1 High**.

Package names differ from bookworm. Several libraries were renamed for the 64-bit `time_t` transition (`t64` suffix), and several others bumped their soname:

| bookworm | trixie | Reason |
|---|---|---|
| `libssl3` | `libssl3t64` | time_t transition |
| `libdb5.3` | `libdb5.3t64` | time_t transition |
| `libgdbm6` | `libgdbm6t64` | time_t transition |
| `libldns3` | `libldns3t64` | time_t transition |
| `libmpg123-0` | `libmpg123-0t64` | time_t transition |
| `libcurl4` | `libcurl4t64` | time_t transition |
| `libflac12` | `libflac14` | soname bump |
| `libhiredis0.14` | `libhiredis1.1.0` | soname bump |
| `libldap-2.5-0` | `libldap2` | OpenLDAP 2.5 → 2.6 |
| `libcodec2-1.0` | `libcodec2-1.2` | soname bump |
| `libpython3.11` | `libpython3.13` | Python 3.11 → 3.13 |

`python3-distutils` no longer exists: from Python 3.12 `distutils` ships inside `python3-setuptools`, so only `python3-dev` and `python3-setuptools` are installed.

### Known remaining findings

Scout reports 1 High and 1 Medium against the base image. Neither is fixable here; both are unfixed in Debian trixie and are not reachable from FreeSWITCH's code paths:

| Package | CVE | Why it does not apply |
|---|---|---|
| `zlib` | CVE-2026-85091 | Heap overflow in `gz_vacate()`, reached via non-blocking `gzprintf()`/`gzvprintf()` after a write stall. FreeSWITCH uses zlib for protocol-level inflate/deflate, not for the `gz*` buffered-write API. |
| `tar` | (Medium) | Only used if you run `tar` yourself inside the container (e.g. `docker cp`). The FreeSWITCH process never invokes it. |

The 63 Low findings are dominated by libtiff entries that all live in `tools/*.c` (`tiffcrop`, `tiffcmp`, `thumbnail`, `rgb2ycbcr`). The `libtiff6` package contains only the shared library — no CLI tools are installed — so those code paths are not present in the image.

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

The image declares `EXPOSE` for SIP and ESL, but **the RTP range is not exposed** — you must publish it yourself to match your configuration.

- `5060/udp`, `5060/tcp` — SIP signaling (internal profile)
- `5080/udp`, `5080/tcp` — SIP signaling (external profile)
- `8021/tcp` — Event Socket Library (ESL)
- RTP range — not declared. Upstream's `rtp-start-port`/`rtp-end-port` are commented out in `switch.conf.xml`, so **no fixed range applies until you set one**. Size the range to your expected concurrent call count, then publish it.

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
- **RTP range**: set `rtp-start-port`/`rtp-end-port` in your mounted `switch.conf.xml` and publish the same range.
- **CMD override**: default is `freeswitch -nonat -nf -c`; override `CMD` to change startup flags (e.g. remove `-nonat` if not behind NAT).
- **`FREESWITCH_OPTS`**: if you set this variable, FreeSWITCH appends it to its argument list. Note the value is split on spaces, so arguments containing spaces cannot be passed this way.

## Constraints

- **Module list is fixed at build time.** Modules not in `modules.conf.in` cannot be loaded at runtime; adding one requires rebuilding the image. `mod_amqp` is the one exception: it is built but not autoloaded, so it can be enabled purely by config.
- **Single architecture.** The final stage copies `libks2.so*`, `libsofia-sip-ua.so*`, `libsignalwire_client2.so*`, and `libspandsp.so*` from hardcoded `x86_64`/`lib` paths, so this image (as-is) only supports `amd64`.
- **Default credentials are live.** The shipped `event_socket.conf.xml` listens on `8021` with the well-known password `ClueCon` and the `loopback.auto` ACL commented out. Override these via your own config mount before exposing the container to any untrusted network.
- **Empty `certs/` directory.** `make install` does not populate TLS certificates; run `gentls_cert` (from `bin/`) or supply your own if you enable TLS SIP profiles.
- **No named volumes declared.** Config, logs, and DB directories are not `VOLUME`-declared, so data is ephemeral unless you explicitly bind/volume-mount those paths.
- **RTP ports are not pre-exposed.** Publish the range manually and keep it in sync with your config.
- **tini as PID 1** handles signal forwarding (SIGTERM/SIGHUP); graceful shutdown and reload behavior depend on FreeSWITCH's own signal handling.

## Disclaimer

This image is provided "as is", without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and non-infringement. **Use it at your own risk.**

The maintainer(s) of this image are not affiliated with SignalWire or the FreeSWITCH project, and provide no guarantee of production-readiness, security hardening, or fitness for any telephony/regulatory use case (e.g. E911, lawful intercept, CALEA, GDPR, HIPAA). You are solely responsible for:

- reviewing and hardening default credentials, ACLs, and exposed ports before any network-facing deployment
- compliance with applicable telecom regulations in your jurisdiction
- verifying license compliance for all bundled and third-party dependencies (FreeSWITCH is MPL 1.1; some optional codecs/libraries, e.g. G.729, may carry separate licensing/patent obligations depending on your usage and region)
- any data loss, service interruption, toll fraud, or other damages arising from use of this image

No support or SLA is implied. Issues can be filed on the repository, but response and fixes are not guaranteed.
