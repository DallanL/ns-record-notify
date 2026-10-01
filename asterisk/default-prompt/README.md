# Bundled default prompt

`recording-notice.wav` says **"All calls are recorded."** — about 1.3 seconds, 16-bit
mono 8 kHz, normalised to a level that is clearly audible over a live call. It was
recorded by the project author and ships under the repository's Apache-2.0 license.

It exists so a new deployment works out of the box. Install it with:

```sh
./scripts/prompt.sh install --default
```

That converts it to both formats Asterisk reads, validates the level, and puts it
where the container looks for it. This directory is **not** mounted into the
container, so changing a file here changes nothing on a running system; the
installed copy lives in `asterisk/sounds/`, which is gitignored.

**Treat it as a placeholder for your own wording.** What you must tell callers, and
how, depends on where you and they are. Replace it with your own recording any time:

```sh
./scripts/prompt.sh install path/to/your-recording.wav
```

The integration tests install this exact file into a throwaway directory, so what
ships is what is tested.
