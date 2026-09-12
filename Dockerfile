FROM debian:bookworm-slim AS build

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
        libexpat1-dev libgdbm-dev bison libtpl-dev libtiff-dev \
        uuid-dev libpcre2-dev libedit-dev libsqlite3-dev libcurl4-openssl-dev \
        libogg-dev libspeex-dev libspeexdsp-dev libldns-dev \
        python3-dev python3-distutils python3-setuptools \
        libavformat-dev libswscale-dev liblua5.4-dev libopus-dev libpq-dev \
        libsndfile1-dev libflac-dev libvorbis-dev default-libmysqlclient-dev \
        libshout3-dev libmpg123-dev libmp3lame-dev libyuv-dev \
        libnode-dev librabbitmq-dev libasound2-dev libcodec2-dev \
        libopencv-dev libhiredis-dev libmemcached-dev libmongoc-dev \
        libmariadb-dev libldap2-dev libsmpp34-dev libmagickcore-dev \
        libvlc-dev libopusfile-dev libopusenc-dev libsnmp-dev libperl-dev \
        default-jdk libsphinxbase-dev libpocketsphinx-dev \
        libvo-amrwbenc-dev libopencore-amrwb-dev \
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
# dependencies exist in Debian bookworm.
COPY modules.conf.in /usr/src/freeswitch/build/modules.conf.in

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
        libvorbisfile3 libtpl0 libnode108 \
        libopencv-core406 libopencv-imgproc406 libopencv-video406 \
        libopencv-imgcodecs406 libhiredis0.14 libmemcached11 libmongoc-1.0-0 \
        libmariadb3 libldap-2.5-0 libsmpp34-1 libmagickcore-6.q16-6 \
        libvlccore9 libvlc5 libopusfile0 libopusenc0 libsnmp40 libperl5.36 \
        libcodec2-1.0 libvo-amrwbenc0 libopencore-amrwb0 librabbitmq4 \
        libasound2 libsphinxbase3 libpocketsphinx3 \
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
