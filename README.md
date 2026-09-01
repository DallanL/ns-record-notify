# ns-record-notify

Injects a repeating "this call is being recorded" announcement into **outbound**
calls placed through a hosted NetSapiens PBX. Both parties hear it, it repeats on
a configurable interval, and an operator can stop it from a web UI at any time.

**Every call routed through this box is announced.** Selection happens upstream:
point the NetSapiens dial rule at this host for the calls that need the
announcement, and route everything else straight to the carrier as it goes today.

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
| `CARRIER_SIP_HOST` / `CARRIER_SIP_PORT` | Where calls go next. Also accepts a list. |
| `CARRIER_USER` / `CARRIER_PASS` | Leave **blank** for an IP-authenticated trunk. If set, the entrypoint adds digest auth and an outbound registration. |
| `ARI_PASS` | Change it. ARI binds to loopback, but still. |

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

### Diagnosing a silent announcement

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

The usual cause is the media path above.

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

Then put the prompt at `asterisk/sounds/recording-notice.wav` (8 kHz mono µ-law —
see `asterisk/sounds/README.md`), and set the interval and prompt in
`config/rules.yaml`.

The directory is mounted to `/usr/share/asterisk/sounds/custom` inside the
container. That path matters: Asterisk searches for sounds under
`<astdatadir>/sounds`, and on this distro `astdatadir` is `/usr/share/asterisk`,
**not** `/var/lib/asterisk`. A prompt placed outside that tree is silently
unresolvable — every playback fails while the call itself sounds perfectly
normal. Confirm with:

```sh
docker exec ns-announce-asterisk asterisk -rx "core show settings" | grep "Data directory"
docker exec ns-announce-asterisk ls /usr/share/asterisk/sounds/custom/
```

```sh
docker compose up -d --build
```

The operator UI is on `http://127.0.0.1:8080` by default.

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

```yaml
dtmf_stop:
  digits: "*9"       # "" disables the feature
  accept_from: any   # caller | callee | any
  sequence_timeout_seconds: 5
```

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

The UI binds to `127.0.0.1` by default. To reach it from another machine, set
`WEB_HOST=0.0.0.0` and put a reverse proxy with authentication in front of it;
there is no auth on the API itself.

Finally, point the NetSapiens outbound dial rule at this host **for the calls you
want announced**, and add a failover route straight to the carrier (see *Failure
modes* below).

### Docker vs bare metal

Docker is fine — **both containers use `network_mode: host`**, which is
deliberate. Virtualization is not the latency risk here; Docker's *bridge*
networking is. A 10k-port RTP range through the userland proxy and NAT adds
jitter and breaks SDP address rewriting. With host networking this performs
essentially like bare metal, so bare metal is not required. Host networking also
lets ARI stay bound to `127.0.0.1`, where it is not reachable off-box.

## Configuration

`config/rules.yaml` controls the prompt and the interval. It ships with
`announcement.enabled: false` — leave it that way until step 1 of *Verifying*
below passes.

Reload it without dropping calls:

```sh
curl -X POST http://127.0.0.1:8080/api/reload
```

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

`test/unit.test.mjs` covers the announce decision, the emergency guard, and the
announcer state machine. `test/e2e.test.mjs` boots the real controller against a fake ARI
server and drives a call through classify → answer → announce → stop → hangup.

Neither test needs Asterisk. The behaviour that *does* need real Asterisk — that
`whisper=both` injects audio and that snoop channels do not accumulate — was
verified against Asterisk 20.6 during development; see the note in `announcer.js`
about snoop lifetime.

## Known Asterisk behaviour worth knowing

`DELETE /channels/{snoopId}` returns 204 but does **not** tear down a snoop
channel while the spied channel is still up — Asterisk reaps it with the call.
Creating a snoop per start/stop cycle therefore leaks idle `Snoop/` channels on a
long call, so `Announcer` creates at most one per call and reuses it.
