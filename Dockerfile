FROM debian:trixie-slim AS build

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq --no-install-recommends install \
        git wget ca-certificates gnupg2 lsb-release \
    && rm -rf /var/lib/apt/lists/*

# --- build toolchain ---
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq --no-install-recommends install \
        build-essential cmake automake autoconf libtool pkg-config nasm yasm \
        libtool-bin \
    && rm -rf /var/lib/apt/lists/*

# --- general / core / codec dependencies ---
# Only libraries whose module is enabled in ./modules.conf.in belong here.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq --no-install-recommends install \
        libssl-dev zlib1g-dev libdb-dev unixodbc-dev libncurses-dev \
        libexpat1-dev libgdbm-dev bison libtpl-dev libtiff-dev \
        uuid-dev libpcre2-dev libedit-dev libsqlite3-dev libcurl4-openssl-dev \
        libogg-dev libspeex-dev libspeexdsp-dev libldns-dev \
        python3-dev python3-setuptools \
        liblua5.4-dev libopus-dev libpq-dev \
        libsndfile1-dev libflac-dev libvorbis-dev default-libmysqlclient-dev \
        libshout3-dev libmpg123-dev libmp3lame-dev \
        libnode-dev librabbitmq-dev \
        libhiredis-dev libmariadb-dev libldap2-dev \
        libopusfile-dev libopusenc-dev \
        libavformat-dev libavcodec-dev libswscale-dev \
        libavutil-dev libswresample-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/libs

# libks (SignalWire's kernel library)
# A full clone is required: CMakeLists.txt derives the Debian changelog from
# `git describe`, which needs the repository tags to be present.
RUN git clone https://github.com/signalwire/libks.git libks \
    && cd libks && cmake . -DCMAKE_INSTALL_PREFIX=/usr -DWITH_LIBBACKTRACE=1 \
    && make -j"$(nproc)" && make install

# sofia-sip
RUN git clone --depth 1 https://github.com/freeswitch/sofia-sip.git sofia-sip \
    && cd sofia-sip && ./bootstrap.sh \
    && ./configure CFLAGS="-g -ggdb" --with-pic --with-glib=no --without-doxygen \
       --disable-stun --prefix=/usr \
    && make -j"$(nproc)" && make install

# spandsp
RUN git clone --depth 1 https://github.com/freeswitch/spandsp.git spandsp \
    && cd spandsp && ./bootstrap.sh \
    && ./configure CFLAGS="-g -ggdb" --with-pic --prefix=/usr \
    && make -j"$(nproc)" && make install

# signalwire-c
RUN git clone --depth 1 https://github.com/signalwire/signalwire-c.git signalwire-c \
    && cd signalwire-c && PKG_CONFIG_PATH=/usr/lib/pkgconfig \
       cmake . -DCMAKE_INSTALL_PREFIX=/usr \
    && make -j"$(nproc)" && make install

# --- FreeSWITCH itself ---
# The version lives in ./FS_VERSION rather than an ARG so this file stays
# constant across releases: an ARG change would invalidate every layer after
# the clone, including all of the dependency builds above.
COPY FS_VERSION /tmp/FS_VERSION
RUN set -eux; \
    FS_VERSION="$(cat /tmp/FS_VERSION)"; \
    rm -f /tmp/FS_VERSION; \
    git clone --depth 1 --branch "$FS_VERSION" \
        https://github.com/signalwire/freeswitch.git /usr/src/freeswitch

WORKDIR /usr/src/freeswitch

# Replace the upstream module list wholesale: our modules.conf.in is the source
# of truth for which modules get built, and it only enables modules whose
# dependencies exist in Debian trixie.
COPY modules.conf.in /usr/src/freeswitch/build/modules.conf.in

# The shipped autoload list names every module upstream knows about, so the
# ones we do not compile log a [CRIT] at every startup. Replace it with one
# generated from the same list that drives the build.
COPY conf-templates/autoload_configs/modules.conf.xml \
     /usr/src/freeswitch/conf/vanilla/autoload_configs/modules.conf.xml

# Upstream preloads mod_pgsql here as well as in modules.conf.xml, which makes
# the core warn "Module mod_pgsql Already Loaded!" on boot. Emptying this file
# leaves modules.conf.xml as the single place that decides what is loaded.
COPY conf-templates/autoload_configs/pre_load_modules.conf.xml \
     /usr/src/freeswitch/conf/vanilla/autoload_configs/pre_load_modules.conf.xml

RUN ./bootstrap.sh -j \
    && ./configure --prefix=/usr/local/freeswitch --enable-core-odbc-support \
    && make -j"$(nproc)" \
    && make install \
    && make sounds-install moh-install \
    && make clean

RUN rm -rf /usr/src/freeswitch/.git /usr/src/libs/*/.git

# ---------------------------------------------------------------------------
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="FreeSWITCH" \
      org.opencontainers.image.source="https://github.com/signalwire/freeswitch"

# Package names differ from bookworm: several libraries were renamed for the
# 64-bit time_t transition (t64 suffix), and flac, libhiredis,
# libcurl, and openldap all bumped their soname. libpython3.13 is not a
# dependency of python3, but mod_python3.so links against libpython3.13.so.1.0
# at load time.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq --no-install-recommends install \
        libssl3t64 zlib1g libdb5.3t64 unixodbc libncurses6 libexpat1 libgdbm6t64 \
        libtiff6 uuid-runtime libpcre2-8-0 libedit2 libsqlite3-0 libcurl4t64 \
        libogg0 libspeex1 libspeexdsp1 libldns3t64 python3 libpython3.13 \
        liblua5.4-0 libopus0 libpq5 libsndfile1 libflac14 \
        libvorbis0a libshout3 libmpg123-0t64 libmp3lame0 \
        libvorbisfile3 libtpl0 \
        libhiredis1.1.0 libmariadb3 libldap2 \
        libopusfile0 libopusenc0 \
        librabbitmq4 \
        libavformat61 libavcodec61 libswscale8 libavutil59 libswresample5 \
        ca-certificates tini gettext-base postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/freeswitch /usr/local/freeswitch
COPY --from=build /usr/lib/libks2.so* /usr/lib/
COPY --from=build /usr/lib/libsofia-sip-ua.so* /usr/lib/
COPY --from=build /usr/lib/libsignalwire_client2.so* /usr/lib/
COPY --from=build /usr/lib/x86_64-linux-gnu/libspandsp.so* /usr/lib/x86_64-linux-gnu/
RUN ldconfig

ENV PATH="/usr/local/freeswitch/bin:${PATH}"

WORKDIR /usr/local/freeswitch

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["freeswitch", "-nonat", "-nf", "-c"]
