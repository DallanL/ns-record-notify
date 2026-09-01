/**
 * Matches a DTMF sequence pressed during a call.
 *
 * Supports multi-digit sequences so the stop code can be made hard to press by
 * accident. Digits pressed on a live call also travel to the far end (we observe
 * them, we cannot swallow them), so a single common digit like `*` risks being
 * eaten by a far-end IVR and silently killing the announcement -- a two-digit
 * sequence avoids that.
 *
 * The buffer resets after `timeoutMs` of silence, and only ever keeps as many
 * digits as the target sequence is long.
 */
export class DigitMatcher {
  constructor(sequence, timeoutMs = 5000) {
    this.sequence = String(sequence ?? '');
    this.timeoutMs = timeoutMs;
    this.buffer = '';
    this.lastAt = 0;
  }

  get enabled() {
    return this.sequence.length > 0;
  }

  /**
   * Feed one digit. Returns true exactly once, on the press that completes the
   * sequence; the buffer is cleared so a repeat needs the full sequence again.
   * `now` is injectable for tests.
   */
  press(digit, now = Date.now()) {
    if (!this.enabled) return false;

    if (this.lastAt && now - this.lastAt > this.timeoutMs) this.buffer = '';
    this.lastAt = now;

    this.buffer += digit;
    // Keep only the tail, so a wrong leading digit cannot block a later match.
    if (this.buffer.length > this.sequence.length) {
      this.buffer = this.buffer.slice(-this.sequence.length);
    }

    if (this.buffer === this.sequence) {
      this.buffer = '';
      return true;
    }
    return false;
  }
}
