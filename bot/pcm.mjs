import { Readable } from 'node:stream';

export const FRAME_BYTES = 960 * 2 * 2; // 20 ms, 48 kHz, stereo, signed 16-bit LE.
export const MAX_PENDING_FRAMES = 2;

// Bound the live backlog rather than replaying old audio after a network stall.
export class LivePCM extends Readable {
  constructor({ encodeFrame } = {}) {
    super({ highWaterMark: encodeFrame ? 1 : FRAME_BYTES, objectMode: Boolean(encodeFrame) });
    this.encodeFrame = encodeFrame;
    this.pending = Buffer.alloc(0);
    this.requested = false;
  }

  feed(chunk) {
    this.pending = Buffer.concat([this.pending, chunk]);
    const overflowFrames = Math.ceil((this.pending.length - FRAME_BYTES * MAX_PENDING_FRAMES) / FRAME_BYTES);
    if (overflowFrames > 0) this.pending = this.pending.subarray(overflowFrames * FRAME_BYTES);
    this.flushFrame();
  }

  _read() {
    this.requested = true;
    this.flushFrame();
  }

  flushFrame() {
    if (!this.requested || this.pending.length < FRAME_BYTES) return;
    const frame = this.pending.subarray(0, FRAME_BYTES);
    this.pending = this.pending.subarray(FRAME_BYTES);
    this.requested = false;
    try { this.push(this.encodeFrame ? this.encodeFrame(frame) : frame); }
    catch (error) { this.destroy(error); }
  }
}

export function validateConfig(config) {
  if (typeof config.token !== 'string' || !config.token.trim()) throw new Error('Enter a bot token.');
  if (!/^\d{17,20}$/.test(config.channelId ?? '')) throw new Error('Enter a valid voice channel ID.');
  return { token: config.token.trim(), channelId: config.channelId };
}
