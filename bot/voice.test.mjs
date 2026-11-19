import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createLiveAudio } from './audio.mjs';
import OpusScript from 'opusscript';
import { FRAME_BYTES } from './pcm.mjs';

test('the production voice pipeline encodes stereo PCM without FFmpeg', async () => {
  const { source, resource } = createLiveAudio();
  const decoder = new OpusScript(48000, 2, OpusScript.Application.AUDIO);
  try {
    const ready = once(resource.playStream, 'readable');
    const pcm = Buffer.alloc(FRAME_BYTES);
    for (let sample = 0; sample < 960; sample++) {
      pcm.writeInt16LE(Math.round(Math.sin(sample * 2 * Math.PI * 440 / 48000) * 8000), sample * 4);
      pcm.writeInt16LE(0, sample * 4 + 2);
    }
    source.feed(pcm);
    await ready;
    const packet = resource.playStream.read();
    assert.ok(packet.length > 0 && packet.length < FRAME_BYTES);
    const decoded = decoder.decode(packet);
    assert.equal(decoded.length, FRAME_BYTES);
    let leftPower = 0, rightPower = 0;
    for (let i = 0; i < decoded.length; i += 4) {
      leftPower += decoded.readInt16LE(i) ** 2;
      rightPower += decoded.readInt16LE(i + 2) ** 2;
    }
    assert.ok(leftPower > 1_000_000);
    assert.ok(leftPower > rightPower * 10, 'left/right audio must remain separate');
  } finally {
    source.destroy();
    resource.playStream.destroy();
    decoder.delete();
  }
});

test('stalled playback retains at most one Opus packet and two raw frames', async () => {
  const { source, resource } = createLiveAudio();
  try {
    const ready = once(resource.playStream, 'readable');
    source.feed(Buffer.alloc(FRAME_BYTES));
    await ready;
    for (let i = 0; i < 200; i++) source.feed(Buffer.alloc(FRAME_BYTES, i % 100));
    assert.equal(resource.playStream, source, 'no extra transform buffering');
    assert.ok(source.readableLength <= 1, 'at most 20 ms of encoded audio');
    assert.ok(source.pending.length <= FRAME_BYTES * 2, 'at most 40 ms of pending PCM');
    assert.ok(resource.playStream.read()?.length > 0);
  } finally {
    source.destroy();
  }
});
