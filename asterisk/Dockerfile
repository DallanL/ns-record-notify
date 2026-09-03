# ---------------------------------------------------------------------------
# Asterisk built from source, pinned to a release we choose.
#
# The distro package was 20.6.0 from Ubuntu *universe*, which carries no
# security commitment and had received no update since 24.04 shipped -- 36
# advisories were fixed on the 20 branch after it, 11 of them high severity.
# Building from source is what makes the version ours to control.
#
# 22 is the newest released LTS: fully supported to 2028-10-16, security fixes
# to 2029-10-16. The 20 branch we were on goes security-fix-only 2026-10-19.
#
# To move to a new release: bump both ARGs together. The checksum is published
# at <url>/asterisk-<version>.sha256 -- note that is the .sha256 beside the
# tarball, not a .tar.gz.sha256.
# ---------------------------------------------------------------------------
ARG ASTERISK_VERSION=22.11.0
ARG ASTERISK_SHA256=3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94

FROM debian:trixie-slim AS build
ARG ASTERISK_VERSION
ARG ASTERISK_SHA256
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl file patch pkg-config \
        bison flex libedit-dev libjansson-dev libsqlite3-dev libssl-dev \
        libsrtp2-dev libxml2-dev libcurl4-openssl-dev uuid-dev libncurses-dev \
        python3 xmlstarlet \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
# Verified against the checksum Asterisk publishes. A source build that pulls an
# unverified tarball has just moved the supply-chain problem, not solved it.
RUN curl -fsSLO "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz" \
    && echo "${ASTERISK_SHA256}  asterisk-${ASTERISK_VERSION}.tar.gz" | sha256sum -c - \
    && tar xzf "asterisk-${ASTERISK_VERSION}.tar.gz"

WORKDIR /usr/src/asterisk-${ASTERISK_VERSION}
# These paths are chosen to match etc/asterisk.conf exactly. In particular
# datadir gives ASTDATADIR=/usr/share/asterisk, which is where <astdatadir>/sounds
# is searched -- the custom prompt is mounted there and a mismatch makes every
# prompt silently unresolvable while the call otherwise sounds fine.
RUN ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --with-pjproject-bundled \
        --with-srtp \
        --with-ssl \
    && make menuselect.makeopts

# Modules get removed between releases -- 22 no longer has chan_skinny, chan_mgcp
# or chan_alsa, and menuselect exits non-zero on a name it does not recognise,
# which would fail the build on a version bump for no good reason. So each is
# attempted individually and a missing one is reported, not fatal.
RUN set -eu; \
    for m in \
        chan_iax2 chan_unistim chan_skinny chan_mgcp chan_alsa chan_console \
        app_voicemail res_musiconhold pbx_ael pbx_lua pbx_dundi \
        res_hep res_hep_pjsip res_hep_rtcp res_phoneprov \
        res_pjsip_phoneprov_provider res_pjsip_config_wizard res_geolocation \
    ; do \
        if menuselect/menuselect --disable "$m" menuselect.makeopts 2>/dev/null; then \
            echo "  disabled $m"; \
        else \
            echo "  note: $m is not present in this release"; \
        fi; \
    done; \
    for m in CORE-SOUNDS-EN-GSM codec_ulaw codec_alaw res_srtp; do \
        menuselect/menuselect --enable "$m" menuselect.makeopts \
            || { echo "FATAL: required module $m is unavailable" >&2; exit 1; }; \
        echo "  enabled $m"; \
    done

RUN make -j"$(nproc)" \
    && make install DESTDIR=/out \
    && make samples DESTDIR=/out

# The sample configs exist only to keep modules from complaining that their
# config is missing -- that noise is what made real warnings hard to spot. Drop
# the ones that would define their own contexts, endpoints or dialplan, since
# those are ours to define and a stray sample context is a routing surprise.
# make install creates /out/var/run as a real directory, but on trixie /var/run
# is a symlink to /run -- COPY then fails with "cannot copy to non-directory".
# The runtime stage creates /var/run/asterisk itself, through the symlink.
RUN rm -rf /out/var/run

RUN cd /out/etc/asterisk \
    && rm -f extensions.ael extensions.lua extensions.conf \
             sip.conf iax.conf dundi.conf pjsip_wizard.conf pjsip.conf \
             manager.conf ari.conf http.conf asterisk.conf modules.conf \
             logger.conf rtp.conf \
    && rm -f users.conf

# ---------------------------------------------------------------------------
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

# Runtime libraries only -- no compiler, no headers, no source tree. Note the
# t64 suffixes: trixie has no libssl3 or libcurl4 under the old names.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libedit2 libjansson4 libsqlite3-0 libssl3t64 libsrtp2-1 libuuid1 \
        libxml2 libcurl4t64 libncursesw6 \
        gettext-base ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r asterisk && useradd -r -g asterisk -d /var/lib/asterisk -s /usr/sbin/nologin asterisk

COPY --from=build /out /

COPY etc/ /etc/asterisk/
COPY sounds/ /var/lib/asterisk/sounds/custom/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/run/asterisk /var/log/asterisk /var/spool/asterisk \
                /var/lib/asterisk/sounds/custom \
    && chown -R asterisk:asterisk \
        /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk \
        /var/run/asterisk /var/lib/asterisk/sounds/custom

USER asterisk
ENTRYPOINT ["/entrypoint.sh"]
CMD ["asterisk", "-f", "-vvv"]
