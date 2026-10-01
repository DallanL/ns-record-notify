# Announcement prompt

**Use the script — do not hand-convert:**

```sh
./scripts/prompt.sh install --default                       # the bundled "all calls are recorded" prompt
./scripts/prompt.sh install path/to/your-recording.wav   # convert + install
./scripts/prompt.sh check                                # validate what is installed
```

It writes both `recording-notice.wav` (16-bit PCM) and `recording-notice.ulaw`
(raw mu-law), normalises the level, keeps your original as
`recording-notice.source.wav`, and asks Asterisk itself whether it can open the
result. No restart is needed -- this directory is bind-mounted.

## Why not just export a mu-law file yourself

"8 kHz, 8-bit, mono, mu-law" describes the *audio* correctly, but it is not the
whole story: Asterisk's `format_wav` reads **16-bit signed linear PCM only**. A
mu-law-encoded `.wav` cannot be opened at all. Asterisk then quietly falls back
to another extension it finds under the same basename -- usually a stale prompt
from a previous install -- so the call sounds completely normal and you hear the
*old* greeting. Raw mu-law is fine, but it must be headerless, as `.ulaw`.

The other silent failure is level. A prompt whispered under a live conversation
is inaudible even though every log line says it played. Target speech peak
0.50-0.90 and speech RMS 0.05-0.20; measure the *speech*, since trailing silence
drags whole-file RMS down and makes a good prompt look too quiet.

Both failures are what `prompt.sh check` exists to catch.

---

Drop the prompt here as `recording-notice.wav`. It is mounted read-only into the
Asterisk container at `/var/lib/asterisk/sounds/custom/`, which is why
`config/rules.yaml` refers to it as `sound:custom/recording-notice` (no extension).

## Format

Match the trunk codec so the injection is as cheap as possible. For a standard
µ-law trunk that means **8 kHz, mono, 16-bit signed PCM**:

```sh
ffmpeg -i source.mp3 -ar 8000 -ac 1 -acodec pcm_s16le recording-notice.wav
```

If the NetSapiens and carrier trunks are both wideband (G.722), use `-ar 16000`
instead and Asterisk will pick the better-matching file automatically.

## Length

Keep it short — under about 5 seconds. It plays over a live conversation on the
interval set in `config/rules.yaml`, so a long prompt is disproportionately
disruptive and will start colliding with its own next playback.

## Generating a placeholder

The file currently here is synthetic speech, fine for testing but robotic — replace
it with a real recording before going live. To regenerate it without installing a
TTS engine locally:

```sh
docker run --rm -v "$PWD/asterisk/sounds:/out" -e UID=$(id -u) -e GID=$(id -g) \
  debian:bookworm-slim bash -c '
    apt-get update -qq && apt-get install -y -qq espeak-ng
    espeak-ng -v en-us -s 145 -a 200 -w /out/.tts-raw.wav "This call is being recorded."
    chown ${UID}:${GID} /out/.tts-raw.wav'

# sox only -- resample and peak-normalise. Do NOT put ffmpeg's loudnorm or
# silenceremove filters in this chain: they reduced the prompt to -41 dBFS peak,
# which plays "successfully" and is completely inaudible on the call.
sox asterisk/sounds/.tts-raw.wav -r 8000 -c 1 -b 16 -e signed-integer \
    asterisk/sounds/recording-notice.wav norm -3
rm asterisk/sounds/.tts-raw.wav
```

## ALWAYS check the level before using it

```sh
sox asterisk/sounds/recording-notice.wav -n stat 2>&1 | grep -E "Maximum|RMS"
```

Expect roughly **peak 0.5-0.9, RMS 0.05-0.2**. Anything with an RMS in the
thousandths is silence as far as a caller is concerned, and nothing downstream
will tell you: Asterisk reports the playback as successful, the controller counts
it as a play, and the call sounds completely normal.

## Checking Asterisk can play it

The directory is bind-mounted read-only, so a new file is picked up with no
rebuild and no restart. To confirm Asterisk can actually find and decode it,
play it to a throwaway bridge and look for `PlaybackStarted` / `PlaybackFinished`
rather than waiting on a test call.
