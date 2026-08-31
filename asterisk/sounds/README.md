# Announcement audio

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

To generate a placeholder for testing:

```sh
espeak-ng -w recording-notice.wav "This call is being recorded."
ffmpeg -i recording-notice.wav -ar 8000 -ac 1 -acodec pcm_s16le out.wav && mv out.wav recording-notice.wav
```
