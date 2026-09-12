FROM debian:bookworm-slim AS build

ARG FS_VERSION=v1.11.3

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq install \
        git wget ca-certificates gnupg2 lsb-release \
    && rm -rf /var/lib/apt/lists/*

# --- build toolchain ---
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq install \
        build-essential cmake automake autoconf libtool pkg-config nasm yasm \
        libtool-bin \
    && rm -rf /var/lib/apt/lists/*

# --- general / core / codec dependencies ---
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq install \
        libssl-dev zlib1g-dev libdb-dev unixodbc-dev libncurses-dev \
        libexpat1-dev libgdbm-dev bison erlang-dev libtpl-dev libtiff-dev \
        uuid-dev libpcre2-dev libedit-dev libsqlite3-dev libcurl4-openssl-dev \
        libogg-dev libspeex-dev libspeexdsp-dev libldns-dev python3-dev \
        libavformat-dev libswscale-dev liblua5.4-dev libopus-dev libpq-dev \
        libsndfile1-dev libflac-dev libvorbis-dev default-libmysqlclient-dev \
        libshout3-dev libmpg123-dev libmp3lame-dev libyuv-dev \
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
RUN git clone --depth 1 --branch "${FS_VERSION}" \
        https://github.com/signalwire/freeswitch.git /usr/src/freeswitch

WORKDIR /usr/src/freeswitch

RUN sed -i \
        -e 's|^#\(databases/mod_pgsql\)|\1|' \
        -e 's|^#\(timers/mod_timerfd\)|\1|' \
        build/modules.conf.in \
    && grep -q '^databases/mod_pgsql' build/modules.conf.in \
    && grep -q '^timers/mod_timerfd' build/modules.conf.in \
    && grep -q '^applications/mod_spandsp' build/modules.conf.in \
    && grep -q '^applications/mod_dptools' build/modules.conf.in

RUN ./bootstrap.sh -j \
    && ./configure --prefix=/usr/local/freeswitch --enable-core-odbc-support \
    && make -j"$(nproc)" \
    && make install \
    && make sounds-install moh-install \
    && make clean

RUN rm -rf /usr/src/freeswitch/.git /usr/src/libs/*/.git

# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="FreeSWITCH" \
      org.opencontainers.image.source="https://github.com/signalwire/freeswitch"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -yq install \
        libssl3 zlib1g libdb5.3 unixodbc libncurses6 libexpat1 libgdbm6 \
        libtiff6 uuid-runtime libpcre2-8-0 libedit2 libsqlite3-0 libcurl4 \
        libogg0 libspeex1 libspeexdsp1 libldns3 python3 libavformat59 \
        libswscale6 liblua5.4-0 libopus0 libpq5 libsndfile1 libflac12 \
        libvorbis0a libshout3 libmpg123-0 libmp3lame0 libyuv0 \
        libvorbisfile3 libtpl0 \
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

# SIP signaling
EXPOSE 5060/udp 5060/tcp 5080/udp 5080/tcp
# RTP media
EXPOSE 16384-16484/udp
# Event Socket Library
EXPOSE 8021/tcp

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["freeswitch", "-nonat", "-nf", "-c"]
