import test from 'node:test';
import assert from 'node:assert/strict';
import { LivePCM, FRAME_BYTES, validateConfig } from './pcm.mjs';

test('fragmented audio is reassembled into intact stereo frames', () => {
  const stream = new LivePCM();
  const frame = Buffer.alloc(FRAME_BYTES, 42);
  stream.feed(frame.subarray(0, 71));
  assert.equal(stream.read(FRAME_BYTES), null);
  stream.feed(frame.subarray(71));
  assert.deepEqual(stream.read(FRAME_BYTES), frame);
  stream.destroy();
});

test('a stalled consumer retains recent frames with sample alignment', () => {
  const stream = new LivePCM();
  for (let index = 0; index < 100; index++) stream.feed(Buffer.alloc(FRAME_BYTES, index));
  assert.equal(stream.pending.length, FRAME_BYTES * 2);
  assert.equal(stream.read(FRAME_BYTES)[0], 98);
  stream.destroy();
});

test('configuration rejects malformed IDs and missing tokens', () => {
  assert.throws(() => validateConfig({ channelId: '123', token: 'secret' }));
  assert.throws(() => validateConfig({ channelId: '123456789012345678', token: ' ' }));
  assert.deepEqual(validateConfig({ channelId: '123456789012345678', token: ' secret ' }),
    { channelId: '123456789012345678', token: 'secret' });
});
