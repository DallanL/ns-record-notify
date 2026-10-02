# ns-record-notify

Plays a repeating "this call is being recorded" announcement into **outbound** calls
from a hosted NetSapiens PBX. Both parties hear it, and anyone on the call — or an
operator in a web UI — can stop it.

```
phones ──> NetSapiens ──SIP──> [ this box ] ──SIP──> carrier ──> PSTN
```

NetSapiens can't play audio into a call from its API, so this box sits in the
outbound path: Asterisk bridges the call and a small controller injects the
announcement. **Every call routed through it is announced** — you choose which calls
by pointing a NetSapiens dial rule at it. Inbound calls are untouched. For how and
why it works this way, see [docs/design.md](docs/design.md).

**Contents:** [Deploy](#deploy) · [Using it](#using-it) · [Scripts](#scripts) ·
[Troubleshooting](#troubleshooting) · [Security](#security) · [Tests](#tests) ·
[License](#license)

## Deploy

You need a Linux host with Docker (these steps assume Ubuntu), the IPs of your
NetSapiens servers, and the IPs of your carrier's gateways.

**1. Prepare the VM.** Use key-only SSH (do this from a second session, and confirm a
new login works before closing the first), then install the basics and
[Docker Engine](https://docs.docker.com/engine/install/ubuntu/):

```sh
echo 'PasswordAuthentication no
PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl reload ssh

sudo apt update && sudo apt -y upgrade
sudo apt -y install git sox ufw unattended-upgrades
```

**2. Get the code and create `.env`.** This generates every secret and prints the
NetSapiens credentials once — note them for step 6:

```sh
git clone https://github.com/DallanL/ns-record-notify.git && cd ns-record-notify
./scripts/init-env.sh \
    --external-ip <this VM's public IP> \
    --ns-hosts <netsapiens IPs, comma separated> \
    --carrier-hosts <carrier gateway IPs, primary first, then failovers> \
    --max-calls <a little above your busiest hour> --max-per-caller 3
```

Everything else has a sensible default; [`.env.example`](.env.example) explains each
setting. It never overwrites an existing `.env`.

**3. Install the announcement prompt.** A stock "All calls are recorded." prompt
ships with the repo. Use it, or your own recording:

```sh
./scripts/prompt.sh install --default
./scripts/prompt.sh install path/to/your-recording.wav     # instead, for your own wording
```

**4. Turn on the firewall.** Look at the plan first, then apply it. `--enable`
switches on default-deny, and only after allowing your SSH session:

```sh
./scripts/firewall.sh                                       # shows the plan, changes nothing
sudo ./scripts/firewall.sh --apply --enable --ssh-from <your admin IP>
```

Keep your current session open and confirm a *new* SSH login works before closing
it. Re-run it whenever a gateway IP changes.

**5. Start it and audit it.**

```sh
docker compose up -d --build
sudo ./scripts/preflight.sh
```

`preflight.sh` should finish with no FAILs. Treat a FAIL as a blocker and a WARN as
a question to answer.

**6. Connect NetSapiens and the carrier.**

- **NetSapiens:** add this VM as an outbound SIP trunk — its public IP, port 5060,
  UDP, with the username and password from step 2 — and point the dial rule for the
  calls you want announced at it. Also add a lower-priority route straight to your
  carrier: this box is in the path, so if it is ever down, calls need somewhere to go.
- **Carrier:** authorise the VM's public IP on your trunk. If yours wants a
  username and password instead, set `CARRIER_USER` / `CARRIER_PASS` in `.env`.

**7. Make a test call** and check that:

- audio works both ways, and caller ID is right;
- both parties hear the announcement about 3 seconds after the call is answered,
  and again every 30 seconds;
- pressing `*9` stops it;
- with the controller stopped (`docker compose stop controller`) calls still
  complete, just without the announcement.

Emergency numbers (911, 112, 999, …) are never announced over — enforced in code.
To test the exclusion mechanism, add a non-emergency number to `safety.exclude_dialed`
in `config/rules.yaml` and call that, rather than dialling 911.

### Behind a cloud router or NAT

The VM doesn't need a public address of its own, but the addresses must tell the truth:

- `EXTERNAL_IP` is the **router's public IP** as the carrier and NetSapiens see it,
  and `LOCAL_NET` is the VM's private subnet. A wrong `EXTERNAL_IP` means calls
  connect but nobody hears anything.
- Forward **UDP 5060 and 10000–20000** to the VM, keep UDP NAT timeouts above a
  minute, and turn **SIP ALG / "SIP helper" off** — it rewrites SIP and media headers.
- In the cloud security group, allow 5060 **only from the NetSapiens and carrier
  IPs**, and SSH only from yours. The host firewall and the cloud firewall are
  separate layers; you want both.
- Use **one network path**: one interface, one public address. A box whose trunks
  leave by different routes (say NetSapiens through a VPN and the carrier through
  the LAN) advertises one address to both, and one side is told to send media
  somewhere our packets don't come from. See
  [Media addressing](docs/design.md#media-addressing).

## Using it

### The operator UI

The UI lists every live call — extension, dialled number, announcement state, play
count — with **Stop**, **Start** and **Stop all** buttons. Stop cuts the audio
immediately and keeps it off for the rest of that call.

It listens on `127.0.0.1:8090` only. Reach it through an SSH tunnel and log in with
`WEB_USER` / `WEB_PASS` from `.env`:

```sh
ssh -L 8090:127.0.0.1:8090 you@the-vm        # then browse http://127.0.0.1:8090
```

### The same thing from a script

Run on the VM. Leave off `-u …` if you left `WEB_PASS` blank.

```sh
curl -s -u operator:<WEB_PASS> http://127.0.0.1:8090/api/calls                       # list; note a channelId
curl -s -u operator:<WEB_PASS> -X POST http://127.0.0.1:8090/api/calls/<channelId>/announce/stop
curl -s -u operator:<WEB_PASS> -X POST http://127.0.0.1:8090/api/announce/stop-all
curl -s -u operator:<WEB_PASS> -X POST http://127.0.0.1:8090/api/reload              # re-read config/rules.yaml
```

### Stopping it from the phone

Anyone on the call can press `*9` (change it with `DTMF_STOP_DIGITS`). Use **two**
digits: this box observes DTMF but can't swallow it, so the digits also reach the far
end, and a lone `*` or `0` could be eaten by a far-end menu. `DTMF_ACCEPT_FROM`
chooses who may press it — `caller` (the internal side), `callee` (the far party) or
`any`. If the announcement is a compliance notice, `caller` stops the outside party
switching it off.

### Changing settings

| What | Where | Takes effect |
| --- | --- | --- |
| Network, secrets, carrier, call caps, announcement timing, the stop code | `.env` | after a restart: `docker compose up -d` (this drops live calls) |
| Prompt file, on/off switch, maximum duration, never-announce list | `config/rules.yaml` | **live**: `POST /api/reload`, no dropped calls |

Timing and the stop code can be set in either place; when set in `.env` it wins, and
the controller logs which source each value came from at startup. To pause
announcements without touching routing, set `announcement.enabled: false` and reload.

### Changing the prompt

```sh
./scripts/prompt.sh install path/to/your-recording.wav
./scripts/prompt.sh check
```

No restart: the next call uses it. Always use the script rather than exporting a
file yourself — an "8 kHz µ-law" WAV looks right but Asterisk can't read it, and it
then silently plays the *previous* prompt (why:
[docs/design.md](docs/design.md#the-announcement-prompt-formats-and-failure-modes)).
Keep it short, 2–4 seconds; it plays over a live conversation.

### Carrier failover

List several gateways in `CARRIER_SIP_HOST` (primary first). Every call tries the
first; the next is used only if that one fails — it answers `503`, is down, or never
answers. A busy *destination* is not retried, since that would ring the same person
twice. If every gateway fails, NetSapiens is sent a `503`, so it falls through to the
backup route from step 6. Details and tuning: [docs/design.md](docs/design.md#carrier-failover).

### Day to day

```sh
docker compose ps                                                       # both containers healthy?
docker compose logs -f controller                                       # announcements, stops, failures
docker compose logs -f asterisk                                         # SIP and carrier events
docker exec ns-announce-asterisk asterisk -rx "pjsip show contacts"     # are the carrier gateways Avail?
docker exec ns-announce-asterisk asterisk -rx "core show channels"      # live calls
```

**Updating:** `git pull && docker compose up -d --build`, then `sudo ./scripts/preflight.sh`.
The restart drops live calls, so pick a quiet moment.

## Scripts

| Script | What it does | Usage |
| --- | --- | --- |
| `scripts/init-env.sh` | Creates `.env` with every secret generated; prints the NetSapiens credentials once. Never overwrites an existing `.env` unless `--force` (which keeps a backup). | `--external-ip --ns-hosts --carrier-hosts [--local-net] [--max-calls] [--max-per-caller] [--force]` |
| `scripts/prompt.sh` | Installs or validates the announcement prompt: converts to the formats Asterisk reads, normalises the level, and asks Asterisk if it can open the result. | `install <file>` · `install --default` · `check` |
| `scripts/firewall.sh` | Opens SIP only to the NetSapiens and carrier IPs in `.env` and closes it to everyone else. Safe to re-run; only touches its own rules. | no flags = show the plan · `--apply` · `--apply --enable [--ssh-from <cidr>]` |
| `scripts/preflight.sh` | Audits a deployment: secrets, call caps, what is listening, the firewall, SSH, container privileges, prompt, carrier gateways. Exits non-zero on any FAIL. | `./scripts/preflight.sh` · `sudo` for the firewall and SSH checks |
| `test/integration/run.sh` | End-to-end tests against a throwaway Asterisk and fake carriers. See [Tests](#tests). | `./test/integration/run.sh` |

`firewall.sh --enable` switches on a default-deny firewall, which is how people lock
themselves out of remote machines. It allows your SSH session first, and refuses to
continue if it can't find an SSH port to keep open.

## Troubleshooting

- **A container exits right after starting.** Read `docker compose logs asterisk`: a
  line starting `FATAL` says what is wrong. It refuses to start on a placeholder or
  short secret, without NetSapiens credentials, or with the UI exposed without a password.
- **Calls connect but there's no audio, or one-way audio.** Almost always
  `EXTERNAL_IP`, a router that isn't forwarding the RTP range, or SIP ALG. Check that
  `ip route get <carrier IP>` and `ip route get <netsapiens IP>` name the **same**
  interface. See [Media addressing](docs/design.md#media-addressing).
- **Calls are fine but nobody hears the announcement.** Run `./scripts/prompt.sh check`,
  then `docker compose logs controller | grep "playback FAILED"`.
- **You hear the *old* greeting.** The new file was hand-converted. Reinstall it with
  `./scripts/prompt.sh install`.
- **NetSapiens calls are rejected.** Its IP isn't in `NS_SIP_HOST` (check
  `asterisk -rx "pjsip show identifies"`), or the digest username/password doesn't
  match what is on the NetSapiens trunk.
- **New calls get a `503`.** Either the call cap was hit (look for `REJECTED` in the
  Asterisk log) or every carrier gateway is down.
- **`ERROR … invalid URI 'carrier-aor-1'` in the log.** Expected during a carrier
  outage: it is a call skipping a gateway already marked down. If a *healthy*
  gateway shows `Unavail` in `pjsip show contacts`, your carrier doesn't answer
  `OPTIONS` pings — set `CARRIER_QUALIFY_SECONDS=0`.
- **The UI won't load.** It is bound to loopback; use the SSH tunnel. If the controller
  log says the port is in use, set a different `WEB_PORT` (the containers share the
  host's network).

## Security

| | Reachable from | Protected by |
| --- | --- | --- |
| SIP `5060/udp` | only the NetSapiens and carrier IPs in `.env` | firewall and IP match; NetSapiens must also answer a **digest challenge** |
| RTP `10000-20000/udp` | anywhere — media comes from addresses signalling never names | Asterisk `strictrtp` drops anything but the learned source |
| SSH | your admin address | key-only login, firewalled with `--ssh-from` |
| Asterisk control interfaces and the UI | **loopback only** | never bound to a public address |

The digest challenge is what stops source-IP spoofing: without it, anyone who can
forge a packet from a NetSapiens address could place calls on your carrier trunk.

The service **refuses to start** if `ARI_PASS` or `NS_AUTH_PASS` is a placeholder or
too short, if NetSapiens digest credentials are missing, or if `WEB_HOST` is set to
a public address without `WEB_USER` / `WEB_PASS` — a hard failure with a message
that says how to fix it. `ALLOW_INSECURE_DEFAULTS=1` softens the first two for a lab
on a private link; `preflight.sh` fails if it is set.

Set `MAX_CONCURRENT_CALLS` and `MAX_CONCURRENT_PER_CALLER`: they bound the bill if
someone does get in. Emergency numbers bypass both caps.

## Tests

```sh
cd controller && npm install && npm test      # unit, web access control, end-to-end (no Asterisk needed)
./test/integration/run.sh                     # needs Docker; 48 checks
```

The integration suite builds a throwaway Asterisk and fake carriers and drives raw
SIP at it. It checks trunk authentication and the call caps; that the announcement
is actually heard by **both** the calling and the receiving party (real RTP, not just
"the file opened"); and carrier failover — a healthy gateway, a `503`, a busy
destination, a gateway that has just died, all of them down, and recovery. How it
works: [docs/design.md](docs/design.md#how-the-integration-suite-works).

## License

[Apache License 2.0](LICENSE). That covers the code here. The images it builds
download and compile Asterisk (GPLv2, with its own exceptions) and install other
open-source packages, which keep their own licenses; none of it is in this repository.
