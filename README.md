# ns-record-notify

Injects a repeating "this call is being recorded" announcement into **outbound**
calls placed through a hosted NetSapiens PBX. Both parties hear it, it repeats on
a configurable interval, and an operator can stop it from a web UI at any time.

**Every call routed through this box is announced.** Selection happens upstream:
point the NetSapiens dial rule at this host for the calls that need the
announcement, and route everything else straight to the carrier as it goes today.

## Contents

- [Why it works this way](#why-it-works-this-way)
- [Configuring the trunks](#configuring-the-trunks)
  - [Media addressing](#media-addressing)
  - [Diagnosing no-audio](#diagnosing-no-audio)
  - [Multiple NetSapiens servers](#multiple-netsapiens-servers)
  - [Carrier failover](#carrier-failover)
- [SIP header passthrough](#sip-header-passthrough)
- [Setup](#setup)
- [Deploying on a new Ubuntu VM](#deploying-on-a-new-ubuntu-vm)
  - [What is exposed, and what is trusted](#what-is-exposed-and-what-is-trusted)
  - [The service refuses to start unsafe](#the-service-refuses-to-start-unsafe)
  - [Step by step](#step-by-step)
  - [Behind a cloud router or NAT](#behind-a-cloud-router-or-nat)
- [Managing the prompt](#managing-the-prompt)
  - [Installing or replacing it](#installing-or-replacing-it)
  - [Do not hand-convert](#do-not-hand-convert)
  - [Recording guidance](#recording-guidance)
  - [When the prompt does not play](#when-the-prompt-does-not-play)
- [Stopping the announcement mid-call](#stopping-the-announcement-mid-call)
  - [From the phone, with DTMF](#from-the-phone-with-dtmf)
- [Docker vs bare metal](#docker-vs-bare-metal)
- [Configuration](#configuration)
- [Failure modes](#failure-modes)
- [Verifying](#verifying)
- [Tests](#tests)
  - [Integration suite (needs Docker)](#integration-suite-needs-docker)
- [Known Asterisk behaviour worth knowing](#known-asterisk-behaviour-worth-knowing)

## Why it works this way

The NetSapiens API cannot inject audio. The v2 create-call endpoint exposes only
`call-orig-user` / `call-term-user` / `auto-answer-enabled` / caller-ID
parameters — there is no barge, whisper, or "play media into call X" operation.
Event subscriptions are observation-only, and native barge is a carrier-gated
supervisor feature code.

So this sits in the outbound media path instead:

```
phones ──> NetSapiens ──SIP──> [this box] ──SIP──> carrier ──> PSTN
                                    │
                                    ├── native Dial() bridge
                                    ├── ARI snoop channel (whisper=both)
                                    └── controller: rules, timer, stop button
```

Inbound routing is untouched — NetSapiens keeps delivering inbound calls exactly
as it does today.

**The call itself is a plain dialplan `Dial()`.** Audio is injected through an ARI
snoop channel created with `spy=none&whisper=both`, which transmits into both
directions of the monitored channel and attaches as an audiohook rather than
re-bridging the call. That combination is the whole design: early media (ringback,
SIT/intercept tones), DTMF, and NetSapiens' CDR answer-times all behave exactly as
they do without this box in the path. Anchoring the media in an ARI mixing bridge
instead would have forced answering the leg early — corrupting CDRs and billing
every unanswered call as connected — or dropping carrier early media.

The announcement repeats as **play-once-then-wait**, not a looped file. A looped
file talks over the whole conversation and cannot be cut cleanly mid-loop; a
discrete playback has a `playbackId` that can be deleted the instant an operator
hits stop.

## Configuring the trunks

Everything trunk-related lives in `.env`; the Asterisk configs are templates
rendered from it at container start.

```sh
cp .env.example .env
```

| Variable | What it is |
| --- | --- |
| `EXTERNAL_IP` | This host's IP **as NetSapiens and your carrier see it**. Goes into SDP; wrong value = one-way audio. |
| `LOCAL_NET` | Your local subnet, so Asterisk knows what is not external. |
| `NS_SIP_HOST` | The NetSapiens core(s) that will send calls here — see *Multiple NetSapiens servers* below. |
| `CARRIER_SIP_HOST` / `CARRIER_SIP_PORT` | Where calls go next. A **comma-separated list** of the carrier's gateways, tried in order — see *Carrier failover* below. |
| `CARRIER_USER` / `CARRIER_PASS` | Leave **blank** for an IP-authenticated trunk. If set, the entrypoint adds digest auth and an outbound registration. |
| `ARI_PASS`, `NS_AUTH_USER` / `NS_AUTH_PASS` | Required. The service **refuses to start** on a placeholder or short secret, or without NetSapiens digest auth. `./scripts/init-env.sh` generates them — see *Deploying on a new Ubuntu VM*. |

Then, on the two systems either side:

**NetSapiens** — add this host as an outbound SIP trunk / connection, and point
the dial rule for the calls you want announced at it. Add a second, lower-priority
route straight to your carrier as failover (see *Failure modes*). NetSapiens must
send from an IP listed in `NS_SIP_HOST`.

**Carrier** — authorise this host's IP on your trunk. That is usually all, since
most carrier trunks are IP-authenticated; use `CARRIER_USER`/`CARRIER_PASS` only
if yours requires registration.

Calls arrive on UDP 5060 and RTP lands in 10000-20000/udp, so open **both** to
the NetSapiens and carrier IPs. Forwarding 5060 but not the RTP range gives a
call that connects with no audio.

### Media addressing

One rule decides whether you get audio:

> For each trunk, `EXTERNAL_IP` must be the address the far end sends media to,
> **and** the address your RTP actually leaves from.

Signalling can work fine while this is wrong — the call connects, both sides
answer, and nobody hears anything, because each side is sending RTP to an
address the other never transmits from.

Check the second half of that rule with:

```sh
ip route get <your carrier IP>
ip route get <your NetSapiens IP>
```

If both name the same interface and source IP, you are on one path: set
`EXTERNAL_IP` to that path's public address and you are done.

If they name **different** interfaces — a VPN or WireGuard tunnel for one trunk
and the local WAN for the other is the usual cause — one advertised address
cannot be right for both, because `external_media_address` is a per-transport
setting in PJSIP. Either route both trunks down the same interface (simplest), or
give each its own transport:

```sh
NS_BIND_IP=10.0.0.2          # tunnel interface
NS_EXTERNAL_IP=10.0.0.2
CARRIER_BIND_IP=10.0.0.3    # WAN interface
CARRIER_EXTERNAL_IP=203.0.113.10
```

The entrypoint reports which mode it chose at startup:

```
entrypoint: single SIP transport on 0.0.0.0, advertising 203.0.113.10
entrypoint: split transports -- NetSapiens 10.0.0.2 advertising 10.0.0.2, carrier ...
```

Setting `NS_EXTERNAL_IP` and `CARRIER_EXTERNAL_IP` differently while both trunks
share a bind address is refused at startup, since two transports cannot bind the
same address and port.

### Diagnosing no-audio

```sh
docker exec ns-announce-asterisk asterisk -rx "pjsip set logger on"
docker exec ns-announce-asterisk asterisk -rx "rtp set debug on"
```

Place a call, then read `docker compose logs asterisk`. Compare the `c=` line in
the SDP you send against the address your RTP is actually sourced from.

### Multiple NetSapiens servers

`NS_SIP_HOST` takes a comma-separated list, and each entry may be an IP, a CIDR,
or a hostname:

```sh
NS_SIP_HOST=10.20.30.41,10.20.30.42,10.20.30.43
NS_SIP_HOST=10.20.30.0/24          # or cover the whole range
```

Every core that can send you traffic must be covered, or its INVITEs are rejected
as unidentified. The entrypoint emits **one identify object per host** and says so
at startup:

```
entrypoint: netsapiens will be identified by 3 host(s)
```

That split is deliberate. Asterisk resolves hostnames once at config load, and a
single unresolvable entry makes the *whole* identify object fail to load — with
one combined match, one bad hostname takes every other core down with it and
rejects all inbound calls. Per host, a bad entry costs only that host.

**Use IPs or a CIDR, not hostnames.** A CIDR covers cores added later with no
config change at all, and it sidesteps DNS entirely. Hostnames do work, but they
are resolved once at load time, so after a DNS change you would need
`docker exec ns-announce-asterisk asterisk -rx "pjsip reload"`.

Check what actually loaded with:

```sh
docker exec ns-announce-asterisk asterisk -rx "pjsip show identifies"
```

### Carrier failover

If the carrier publishes failover gateways, list them all, in the order to try:

```sh
CARRIER_SIP_HOST=192.0.2.10,192.0.2.11,192.0.2.12:5080
```

Each entry can carry its own port (`ip:5080`), and a CIDR (`192.0.2.0/24`) is
accepted for **matching inbound traffic only** — a range cannot be dialled, so it
is never a failover target. Prefer literal IPs to hostnames: a hostname is
resolved once, at startup.

**Every call starts at the first gateway.** The next is tried only if the
previous one *failed*, and "failed" is deliberately narrow:

| Outcome | Meaning | What happens |
| --- | --- | --- |
| `CONGESTION` | The gateway answered `503` — busy or overloaded | **fail over** |
| `CHANUNAVAIL` | Down, unreachable, or never answered | **fail over** |
| `BUSY` | The **destination** is busy (`486`) | call ends — no retry |
| `NOANSWER`, `CANCEL`, `ANSWER` | A real outcome | call ends |

`BUSY` is left out on purpose. Retrying it on a second gateway would ring the same
person again, so it would turn one busy signal into a second phone call. If your
carrier reports its own overload as `486`, add it with
`CARRIER_FAILOVER_ON=CONGESTION,CHANUNAVAIL,BUSY` and accept that trade.

**Why sequential rather than one AOR with several contacts.** Dialling a PJSIP
endpoint whose AOR has multiple contacts *forks* to all of them at once, so the
destination would ring once per gateway. Each gateway is therefore its own
endpoint (`carrier-1`, `carrier-2`, …) and the dialplan tries them in turn.

**Noticing a dead gateway.** Two mechanisms, for two situations:

- Each gateway is pinged with SIP `OPTIONS` every `CARRIER_QUALIFY_SECONDS`
  (default 10). One that stops answering is marked unavailable and **skipped
  instantly** — a call never waits on it.
- In the gap between a gateway dying and the next ping, a call can reach it. It
  is abandoned after `CARRIER_RESPONSE_TIMEOUT_MS` (default 16 s) instead of SIP's
  32 s. Asterisk will not accept Timer B below 64 × T1, so this works by lowering
  T1 (`timeout / 64`); keep T1 above the round-trip time to the carrier, or you
  get needless retransmits. The floor is 6400 ms.

**What an outage looks like in the logs.** A call that skips a gateway already
marked unavailable makes Asterisk log, at `ERROR`:

```
Endpoint 'carrier-1': Could not create dialog to invalid URI 'carrier-aor-1'.  Is endpoint registered and reachable?
```

That is the skip working, not a misconfiguration — expect one per call per down
gateway for as long as the outage lasts. The dialplan line just before the retry
(`carrier-1 returned CHANUNAVAIL … FAILOVER to carrier-2`) is the one to read.

Two things to check for your carrier:

- **It must answer `OPTIONS`**, or qualification marks it unavailable *forever*
  and it is never used. Check with `docker compose exec asterisk asterisk -rx
  "pjsip show contacts"`; if a gateway shows `Unavail` while healthy, set
  `CARRIER_QUALIFY_SECONDS=0` (failover then relies on the timeout alone).
- **Digest-authenticated carriers** get a registration per gateway. That path is
  not covered by the integration tests, which use an IP-authenticated fake
  carrier; test it against yours.

Emergency calls fail over like any other. The integration suite proves all of
this against two fake gateways — a healthy call, a `503`, a busy destination, a
gateway that has just died, one already marked down, all of them down, and
recovery — and asserts what each gateway was *asked to dial*, since the caller's
response alone cannot show whether a call went to the right place or to two.

## SIP header passthrough

**Asterisk is a B2BUA and relays no headers by default.** This was measured, not
assumed: with a stock config, `Identity`, `P-Asserted-Identity`, `Diversion`,
`Remote-Party-ID` and custom `X-` headers all arrived at the carrier **empty**,
with only the calling number surviving in a rebuilt `From`.

That would have stripped the STIR/SHAKEN `Identity` header off every outbound
call, so `[from-ns]` captures these headers and the `[carrier-headers]` pre-dial
handler re-adds them to the outbound INVITE. Verified end to end between two
Asterisk instances:

| Header | Result |
| --- | --- |
| `Identity` (STIR/SHAKEN) | Relayed **byte-identical** — required, or the signature no longer verifies |
| `P-Asserted-Identity` | Relayed verbatim |
| `Remote-Party-ID` | Relayed verbatim |
| `P-Charge-Info`, `P-Preferred-Identity` | Relayed verbatim |
| `Diversion` | Relayed, but Asterisk regenerates it — number and `reason` survive, the host part becomes this box's IP |
| Custom `X-*` | **Not** relayed |

To add a custom header, capture it as `__H_YOURS` in `[from-ns]` and add a
matching `ExecIf` line in `[carrier-headers]` — both in
`asterisk/etc/extensions.conf`, a couple of lines each.

Note this box does not sign calls itself; it preserves whatever NetSapiens
signed. If NetSapiens does *not* sign, nothing here changes that.

## Setup

Then install the prompt with the script — do not hand-convert it:

```sh
./scripts/prompt.sh install path/to/your-recording.wav
```

It converts to both formats Asterisk can read, normalises the level, and asks
Asterisk itself whether it can open the result. `./scripts/prompt.sh check`
re-validates at any time. Exporting "8 kHz 8-bit mono µ-law" by hand produces a
µ-law **WAV**, which `format_wav` cannot open — Asterisk then falls back to a
stale prompt and you hear the *old* greeting on a call that sounds perfectly
normal. See `asterisk/sounds/README.md`.

Set the interval and prompt in `config/rules.yaml`.

The directory is mounted to `/var/lib/asterisk/sounds/custom` inside the
container. That path matters: Asterisk searches for sounds under
`<astdatadir>/sounds`, and for our source build `astdatadir` is
`/var/lib/asterisk`. A prompt placed outside that tree is silently unresolvable
— every playback fails while the call itself sounds perfectly normal.

**This path changed with the Asterisk 22 upgrade.** The old Ubuntu package
compiled in `/usr/share/asterisk`; a source build uses `/var/lib/asterisk`, which
is where its core sounds and XML documentation live too. Confirm with:

```sh
docker exec ns-announce-asterisk asterisk -rx "core show settings" | grep "Data directory"
docker exec ns-announce-asterisk ls /var/lib/asterisk/sounds/custom/
```

Do not "fix" a mismatch by editing `astdatadir` in `asterisk.conf` to point
somewhere else: the XML documentation lives under the same directory, and moving
it stops Asterisk from starting at all.

```sh
docker compose up -d --build
```

The operator UI is on `http://127.0.0.1:8080` by default.

## Deploying on a new Ubuntu VM

This box relays outbound calls to your carrier, so a public address makes it a
toll-fraud target within hours of going up. The design is built so that the safe
configuration is the default, and the unsafe ones are refused rather than warned
about.

### What is exposed, and what is trusted

| | Reachable from | Protected by |
| --- | --- | --- |
| SIP `5060/udp` | only the NetSapiens and carrier IPs in `.env` | firewall **and** IP match; NetSapiens must also answer a **digest challenge** |
| RTP `10000-20000/udp` | anywhere (media comes from addresses signalling never names) | Asterisk `strictrtp` — drops anything but the learned source |
| SSH | your admin address | key-only login, firewalled to `--ssh-from` |
| ARI `8088`, AMI `5038`, operator UI `8090` | **loopback only** | never bound to a public interface |

The digest challenge is what stops **source-IP spoofing**. An IP allowlist trusts a
field the sender controls: anyone who can forge a packet from a NetSapiens address
could place calls on your carrier trunk and never need to see a reply, because for
toll fraud the payoff is the number dialled, not the audio. Our `401`, with its
nonce, goes to the *real* NetSapiens address, which a blind spoofer never
receives.

### The service refuses to start unsafe

Each of these is a hard startup failure with a message that says how to fix it,
because nobody reads the logs of a box that appears to work:

- `ARI_PASS` (or `NS_AUTH_PASS`) is a known placeholder such as `change-me…`, or too short
- NetSapiens digest credentials are not set
- `WEB_HOST` is not loopback and `WEB_USER` / `WEB_PASS` are not set, or the password is under 12 characters

`ALLOW_INSECURE_DEFAULTS=1` downgrades the first two to warnings, for a lab on a
private link. Do not set it on a public host — `preflight.sh` fails if you do.

### Step by step

**1. Lock down SSH first**, from a second session so you cannot lose your way in:
put your public key in `~/.ssh/authorized_keys`, then

```sh
echo 'PasswordAuthentication no
PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh      # confirm a NEW login works before closing the old one
```

**2. Base packages and automatic security updates:**

```sh
sudo apt update && sudo apt -y upgrade
sudo apt -y install ufw sox git unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

**3. Docker Engine** from Docker's own apt repository
([instructions](https://docs.docker.com/engine/install/ubuntu/)). Adding yourself
to the `docker` group is root-equivalent on that machine; on a dedicated VM that
is normally acceptable, but know that it is what you are doing.

**4. Configuration** — every secret generated, none taken from the repository:

```sh
git clone git@github.com:DallanL/ns-record-notify.git && cd ns-record-notify
./scripts/init-env.sh --external-ip <this-VM-public-IP> \
    --ns-hosts <ns1,ns2,…> --carrier-hosts <gw1,gw2,…> \
    --max-calls <a little above your busiest hour> --max-per-caller 3
./scripts/prompt.sh install path/to/your-recording.wav
```

It prints the NetSapiens username and password **once** — enter them on the
NetSapiens trunk. It never overwrites an existing `.env`, because regenerating
secrets on a live box locks NetSapiens out until its trunk is updated.

**5. Firewall.** Look first, then apply. `--enable` turns on default-deny, and only
after it has allowed the SSH port you are connected on:

```sh
./scripts/firewall.sh                                        # the plan; changes nothing
sudo ./scripts/firewall.sh --apply --enable --ssh-from <your-admin-IP>
```

Keep your current session open and confirm a *new* SSH login works before you
close it. Without `--ssh-from`, SSH stays open to the whole internet — the most
attacked service there is. Re-run the script whenever a gateway IP changes; it
only touches its own rules, and one that has been removed from `.env` loses its
rule.

**6. Start it and audit it:**

```sh
docker compose up -d --build
sudo ./scripts/preflight.sh
```

`preflight.sh` checks the deployment rather than trusting the steps above: file
permissions, secret strength, digest auth, concurrency caps, what is actually
listening, the firewall's effective state, sshd's *effective* config, container
privileges, and whether every carrier gateway is reachable. It exits non-zero on
any FAIL. Treat a FAIL as a blocker, and a WARN as a question to answer.

### Behind a cloud router or NAT

Nothing in the design needs the VM to hold a public address itself, but the
addresses have to tell the truth:

- **`EXTERNAL_IP`** is the router's public address *as the carrier and NetSapiens
  see it* — it goes into SDP, and a wrong value means one-way audio.
  **`LOCAL_NET`** is the VM's private subnet, so Asterisk knows which peers are
  outside it.
- The router must forward **UDP 5060 and 10000–20000** to the VM (1:1 NAT is
  simplest), keep UDP NAT timeouts above a minute so idle media is not dropped,
  and have any **SIP ALG / "SIP helper" turned off** — it rewrites SIP and RTP
  headers and breaks digest auth and media in ways that are miserable to trace.
- **Do not open 5060 to the internet** in the cloud security group. Allow it only
  from the NetSapiens and carrier IPs, and SSH only from yours. The host firewall
  and the cloud firewall are separate layers, and you want both.
- **Use one network path.** `external_media_address` is per transport, so a box
  whose trunks leave by different routes (say NetSapiens through a WireGuard
  tunnel and the carrier through the LAN uplink) advertises one address to both,
  and at least one side is told to send media somewhere our packets do not come
  from. The entrypoint refuses that combination unless each trunk has its own
  bind address. A single interface with a single public address — which a fresh
  VM naturally is — is the configuration this is designed for.

## Managing the prompt

### Installing or replacing it

```sh
./scripts/prompt.sh install path/to/your-recording.wav
```

That is the whole procedure. The script converts to both formats Asterisk can
read, normalises the level, keeps your original as `recording-notice.source.wav`,
and then validates the result — including asking Asterisk itself whether it can
open each file.

**No restart or rebuild is needed.** `asterisk/sounds/` is bind-mounted into the
container, so a new prompt is live for the next call.

To re-check what is installed at any time:

```sh
./scripts/prompt.sh check
```

```
recording-notice.wav         RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 8000 Hz
OK       .wav is 16-bit PCM
speech peak 0.544495 (want 0.50-0.90), speech RMS 0.068593 (want 0.05-0.20)
OK       level is in range
OK       Asterisk opened recording-notice.wav
OK       Asterisk opened recording-notice.ulaw
```

### Do not hand-convert

Exporting "8 kHz, 8-bit, mono, µ-law" from an audio editor describes the audio
correctly and still produces a file Asterisk cannot open, because it writes a
µ-law **WAV**. `format_wav` reads 16-bit signed linear PCM only. Raw µ-law is
fine, but it has to be headerless, as `.ulaw`.

This one is worth understanding rather than just avoiding, because of how it
fails. Asterisk resolves `sound:custom/recording-notice` by basename and tries
each extension it knows. If the `.wav` is unreadable it silently falls back to
the `.ulaw` beside it — which, after an install that only replaced the `.wav`, is
the *previous* prompt. So the call is healthy, no error appears anywhere, and you
hear the old greeting. That is not a hypothetical; it is what happened here.

### Recording guidance

Aim for **speech** peak 0.50–0.90 and **speech** RMS 0.05–0.20. Measure the
speech rather than the file: trailing silence drags whole-file RMS down and makes
a perfectly good prompt look too quiet. `prompt.sh check` already does this.

Keep it short. The prompt plays over a live conversation on an interval, so a
2–4 second notice is usually right; anything longer starts talking over the call
more than it informs.

### When the prompt does not play

If calls are fine but nobody hears the prompt, the controller now says so
outright:

```
ERROR playback FAILED -- callers heard nothing {"media":"sound:custom/recording-notice", ...}
```

and the operator UI shows the failure count next to the plays. ARI's
`PlaybackFinished` event fires whether a playback succeeded or failed — only its
`state` field distinguishes them — so "the playback event arrived" is not
evidence that anyone heard anything. Check `state`, or check Asterisk for
`Playback failed`:

```sh
docker compose logs asterisk | grep "Playback failed"
```

Start with the checker — it covers every cause below in one command, and asks
Asterisk directly rather than inferring:

```sh
./scripts/prompt.sh check
```

The three things that produce a healthy call with no announcement, in the order
they actually occur:

1. **The file is unreadable and a stale one plays instead.** See
   [Do not hand-convert](#do-not-hand-convert). This is the only failure where
   you hear *something*, which makes it the easiest to misread.
2. **The prompt is too quiet.** A file can be technically valid, play
   "successfully", and still be inaudible under a live conversation.
3. **The file is not where Asterisk looks.** Sounds resolve under
   `<astdatadir>/sounds`, which for this build is `/var/lib/asterisk`:

   ```sh
   docker exec ns-announce-asterisk asterisk -rx "core show settings" | grep "Data directory"
   docker exec ns-announce-asterisk ls /var/lib/asterisk/sounds/custom/
   ```

If the prompt checks out and callers still hear nothing, the problem is the media
path rather than the prompt — see [Media addressing](#media-addressing) and
[Diagnosing no-audio](#diagnosing-no-audio).

## Stopping the announcement mid-call

The UI lists every live call with its extension, dialed number, announcement
state and play count. Each row has a **Stop** button that cuts the audio
immediately — it deletes the running playback rather than waiting for the prompt
to finish — and stops it repeating for the rest of that call. **Stop all** does
the same for every call at once.

The same thing over the API, if you would rather script it or bind it to a key:

```sh
curl -s http://127.0.0.1:8080/api/calls                      # find the channelId
curl -X POST http://127.0.0.1:8080/api/calls/<channelId>/announce/stop
curl -X POST http://127.0.0.1:8080/api/announce/stop-all     # everything, now
```

Stop is per call and permanent for that call — it clears the auto-announce flag,
so it will not restart on the next interval. **Start** on the same row resumes it
if needed.

### From the phone, with DTMF

Someone on the call can stop it themselves by pressing a code — `*9` by default,
set in `config/rules.yaml`:

```sh
DTMF_STOP_DIGITS=*9      # empty (DTMF_STOP_DIGITS=) disables the feature
DTMF_ACCEPT_FROM=any     # caller | callee | any
```

(or `dtmf_stop:` in `config/rules.yaml` — the env vars win, see
*Configuration* below).

It behaves exactly like the UI's Stop: audio cuts immediately and stays off for
the rest of that call. The UI shows the active code in its header and records
`stopped by caller via DTMF` (or `callee`) as the reason.

Three things worth knowing:

- **Use two digits, not one.** This box *observes* DTMF, it cannot swallow it, so
  whatever you choose still travels to the far end. A lone `*` or `0` risks being
  pressed at a far-end IVR and silently killing the announcement. A partial
  sequence is forgotten after `sequence_timeout_seconds`.
- **`accept_from` decides who may press it.** The default `any` matches the usual
  request, but if the announcement is a compliance notice you do not want the
  outside party switching off, set `caller` — the internal NetSapiens-side user
  only. Verified: with `caller`, digits from the far party are ignored and the
  announcement keeps playing.
- **It only works while an announcement is or has been running on that call.** In
  a native RTP bridge Asterisk passes DTMF straight through without surfacing it;
  it is the announcement's own audiohook that causes the digits to be seen. That
  is not a limitation in practice — there is nothing to stop before the first
  announcement, and the hook stays for the rest of the call once created.

The UI binds to `127.0.0.1` by default, and the safest way in is an SSH tunnel:

```sh
ssh -L 8090:127.0.0.1:8090 you@the-vm      # then browse http://127.0.0.1:8090
```

Set `WEB_USER` and `WEB_PASS` (12+ characters) and it requires HTTP Basic auth on
everything, the UI included — only `/api/health` stays open, for the container
healthcheck. `WEB_HOST=0.0.0.0` is **refused at startup** unless those are set,
so exposing call control by editing one line is not possible. Cross-origin
`POST`s are rejected too: browsers attach Basic credentials to cross-site
requests automatically, so without that check any page you visited could submit a
form that stops every announcement. Use TLS (a reverse proxy, or the tunnel)
whenever it leaves loopback: Basic auth sends the password with every request.

Finally, point the NetSapiens outbound dial rule at this host **for the calls you
want announced**, and add a failover route straight to the carrier (see *Failure
modes* below).

## Docker vs bare metal

Docker is fine — **both containers use `network_mode: host`**, which is
deliberate. Virtualization is not the latency risk here; Docker's *bridge*
networking is. A 10k-port RTP range through the userland proxy and NAT adds
jitter and breaks SDP address rewriting. With host networking this performs
essentially like bare metal, so bare metal is not required. Host networking also
lets ARI stay bound to `127.0.0.1`, where it is not reachable off-box.

## Configuration

Settings live in two places:

| | `.env` | `config/rules.yaml` |
| --- | --- | --- |
| Holds | timing and DTMF stop code | everything, including the prompt and safety list |
| Applies | on restart | live |
| Wins | **yes**, when the variable is set | when the variable is unset |

The four deployment-facing settings are overridable from `.env`:

```sh
ANNOUNCE_INITIAL_DELAY_SECONDS=3
ANNOUNCE_INTERVAL_SECONDS=30
DTMF_STOP_DIGITS=*9
DTMF_ACCEPT_FROM=any
```

These are read at **startup only**, so a change needs
`docker compose up -d controller`, not `/api/reload`. An invalid value (a
non-number, a negative interval, a non-DTMF character) is ignored with a warning
and the YAML value is used instead. Setting `DTMF_STOP_DIGITS=` — defined but
empty — disables the stop code, which is different from leaving it unset.

To avoid guessing which source won, the controller says so at startup:

```
rules loaded {"intervalSeconds":"30 (ANNOUNCE_INTERVAL_SECONDS)",
              "dtmfStop":"*9 (DTMF_STOP_DIGITS)", ...}
```

Everything else — the prompt, the enable switch, `max_duration_seconds`, the
safety exclusions — lives in `config/rules.yaml` and reloads live without
dropping calls:

```sh
curl -X POST http://127.0.0.1:8090/api/reload
```

It ships with `announcement.enabled: false` — leave it that way until step 1 of
*Verifying* below passes.

There is no per-user or per-destination targeting: routing decides what gets
announced. The only exceptions are the `safety.exclude_dialed` list and, more
importantly, the emergency numbers (911, 112, 999, …) blocked in `rules.js` **in
code**, not just in config. Neither can be announced over, even by a manual
operator start.

The operator UI shows the originating extension, read from `P-Asserted-Identity`
(falling back to `From`, then caller ID). This is display only — if NetSapiens
sends the company DID rather than the extension there, the column is less useful
but nothing about the announcement behaviour changes.

## Failure modes

The dialplan is `Stasis(announcer)` followed by `Dial()`. If the **controller** is
down, `Stasis()` sets `STASISSTATUS=FAILED` and execution falls through to the
next priority — the `Dial()`. Outbound calling keeps working, just without
announcements.

The **Asterisk** container is a hard dependency for outbound calls while the trunk
points at it, so configure a failover route on the NetSapiens dial rule that goes
straight to the carrier.

If **every carrier gateway** fails, the calling PBX is sent a `503`, not a `404`:
a 503 reads as "try another route", which is what lets NetSapiens fall through to
that failover route, while a 404 would read as a permanent failure and be given up
on. See *Carrier failover*.

## Verifying

1. **Transparency first.** With `announcement.enabled: false`, route outbound
   through the box and confirm two-way audio, correct caller ID, ringback, DTMF
   into an IVR, and correct answer times in the NetSapiens CDRs. Get this clean
   before enabling anything.
2. **Injection.** Set `enabled: true` and place a test call; confirm both parties
   hear the prompt and that it repeats at the configured interval.
3. **Stop.** Hit stop mid-playback — audio must cut immediately and not resume.
4. **911 guard.** Confirm an excluded destination never announces.
5. **Degradation.** `docker compose stop controller`, then place an outbound
   call. It must still complete, without announcements.
6. **Headers.** On a real outbound call, confirm with your carrier (or a capture)
   that the `Identity` header arrives intact and attestation is unchanged from
   what NetSapiens sent.
7. **Teardown.** Hang up from each side; `asterisk -rx "core show channels"`
   should show no leftover `Snoop/` channels.

## Tests

```sh
cd controller && npm install && npm test
```

`test/web.test.mjs` covers the operator UI's access control (authentication, cross-origin
refusal, and the refusal to bind a public address without credentials). `test/unit.test.mjs` covers the announce decision, the emergency guard, and the
announcer state machine. `test/e2e.test.mjs` boots the real controller against a fake ARI
server and drives a call through classify → answer → announce → stop → hangup.

Neither test needs Asterisk.

### Integration suite (needs Docker)

```sh
./test/integration/run.sh
```

Builds the images, stands up an isolated Asterisk plus a fake carrier on their own
Docker network, and drives raw SIP at it. Three phases, 48 checks:

**Phase 1 — signalling**, with no controller running, which also exercises the
`STASISSTATUS=FAILED` fallback: every call here completes with Stasis
unavailable. Asserts that an unauthenticated trunk is challenged, a wrong
password is refused, both concurrency caps fire, emergency calls bypass them, and
the identity headers survive the B2BUA hop.

**Phase 2 — the announcement path**, with the controller attached and the carrier
answering. Asserts that ARI connects, the snoop attaches, Asterisk opens the
prompt, and it repeats on the interval — then flips `media` to a nonexistent file
and asserts the failure *is* reported. The announcement phase also runs **real RTP**
on both legs — the caller sends a tone as its voice and the far side measures what
arrives — so it asserts that the *originating and terminating* parties both hear
the announcement, not merely that Asterisk opened the file. Direction controls
(`whisper=in`, `whisper=out`) were used to prove that check can fail.

**Phase 3 — carrier failover**, against two fake gateways: a healthy call, a `503`,
a busy destination, a gateway that has just died, one already marked down, all of
them down, and recovery. It insists on an empty box first and on the concurrency
cap never having fired, because a cap rejection is *also* a fast `503` — an earlier
version of these checks passed for that wrong reason.

Two things about it are deliberate and worth preserving.

It asserts what the **carrier** was asked to dial, not the response the caller
got. A `Goto` that clobbered `${EXTEN}` once sent 911 to `sip:emergency@` while
still returning a healthy `180 Ringing` — only the carrier-side view caught it.

The fake carrier holds calls at `180 Ringing` instead of answering, because a cap
is only observable while calls stay up. `ANSWER=1` makes it answer instead, which
is what the announcement path needs — a snoop has nothing to whisper into while a
call is still ringing.

When checking that a prompt plays, confirm a **failure is detectable** before
trusting a pass: point `media` at a nonexistent file and check the controller
logs `playback FAILED`. `PlaybackFinished` fires whether playback succeeded or
not, so "no error appeared" is not evidence on its own.

## Known Asterisk behaviour worth knowing

`DELETE /channels/{snoopId}` returns 204 but does **not** tear down a snoop
channel while the spied channel is still up — Asterisk reaps it with the call.
Creating a snoop per start/stop cycle therefore leaks idle `Snoop/` channels on a
long call, so `Announcer` creates at most one per call and reuses it.
