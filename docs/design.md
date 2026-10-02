# Design notes and reference

The reasoning behind how this works, and the details you need when something is
unusual. For deploying and day-to-day use, see the [README](../README.md).

## Contents

- [Why it works this way](#why-it-works-this-way)
- [Failure modes](#failure-modes)
- [Media addressing](#media-addressing)
- [Diagnosing no-audio](#diagnosing-no-audio)
- [Multiple NetSapiens servers](#multiple-netsapiens-servers)
- [Carrier failover](#carrier-failover)
- [SIP header passthrough](#sip-header-passthrough)
- [The announcement prompt: formats and failure modes](#the-announcement-prompt-formats-and-failure-modes)
  - [Do not hand-convert](#do-not-hand-convert)
  - [Recording guidance](#recording-guidance)
  - [When the prompt does not play](#when-the-prompt-does-not-play)
- [Docker vs bare metal](#docker-vs-bare-metal)
- [Known Asterisk behaviour](#known-asterisk-behaviour)
- [How the integration suite works](#how-the-integration-suite-works)

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
on. See [Carrier failover](#carrier-failover).

## Media addressing

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
NS_BIND_IP=10.0.0.2        # tunnel interface
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

## Diagnosing no-audio

```sh
docker exec ns-announce-asterisk asterisk -rx "pjsip set logger on"
docker exec ns-announce-asterisk asterisk -rx "rtp set debug on"
```

Place a call, then read `docker compose logs asterisk`. Compare the `c=` line in
the SDP you send against the address your RTP is actually sourced from.

## Multiple NetSapiens servers

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

## Carrier failover

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

## The announcement prompt: formats and failure modes

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

## Docker vs bare metal

Docker is fine — **both containers use `network_mode: host`**, which is
deliberate. Virtualization is not the latency risk here; Docker's *bridge*
networking is. A 10k-port RTP range through the userland proxy and NAT adds
jitter and breaks SDP address rewriting. With host networking this performs
essentially like bare metal, so bare metal is not required. Host networking also
lets ARI stay bound to `127.0.0.1`, where it is not reachable off-box.

## Known Asterisk behaviour

`DELETE /channels/{snoopId}` returns 204 but does **not** tear down a snoop
channel while the spied channel is still up — Asterisk reaps it with the call.
Creating a snoop per start/stop cycle therefore leaks idle `Snoop/` channels on a
long call, so `Announcer` creates at most one per call and reuses it.

## How the integration suite works

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

The prompt it plays is the one that ships in `asterisk/default-prompt/`, installed into a
throwaway directory — not whatever happens to be in your own gitignored `asterisk/sounds/`.
That makes the suite pass on a fresh clone, and means the file everyone deploys is the file
that was tested.

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
