# Ubuntu 24.04 ships Asterisk 20.x (LTS). Note this is deliberately not a Debian
# base: Debian dropped the `asterisk` package in bookworm and it is still absent
# in trixie. Everything this project needs -- res_ari*, app_dial, chan_pjsip,
# func_pjsip_header -- is in the stock package set.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        asterisk \
        asterisk-config \
        asterisk-core-sounds-en-gsm \
        asterisk-modules \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Remove only the stock config that could define its own dialplan contexts or
# endpoints. The rest of the shipped defaults (udptl, acl, features, cdr, cel,
# indications) are left in place deliberately: they are sane, and deleting them
# produced ~100 lines of "unable to load config file" noise at every startup
# that would hide real errors.
RUN rm -f /etc/asterisk/extensions.ael /etc/asterisk/extensions.lua \
        /etc/asterisk/sip.conf /etc/asterisk/iax.conf /etc/asterisk/dundi.conf \
        /etc/asterisk/pjsip_wizard.conf

COPY etc/ /etc/asterisk/
COPY sounds/ /usr/share/asterisk/sounds/custom/
COPY entrypoint.sh /entrypoint.sh

# The entrypoint renders templates into /etc/asterisk at runtime, so the
# asterisk user needs to own it.
RUN chmod +x /entrypoint.sh \
    && mkdir -p /var/run/asterisk /var/log/asterisk /var/spool/asterisk /usr/share/asterisk/sounds/custom \
    && chown -R asterisk:asterisk \
        /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk \
        /usr/share/asterisk/sounds/custom

USER asterisk
ENTRYPOINT ["/entrypoint.sh"]
CMD ["asterisk", "-f", "-vvv"]
