import test from 'node:test';
import assert from 'node:assert/strict';
import { measureCodecDelay, previousAudioPipeline } from '../scripts/measure-codec-delay.mjs';

test('production pipeline removes 192 samples of codec lookahead from the previous mode', async t => {
  const before = await measureCodecDelay(previousAudioPipeline);
  const after = await measureCodecDelay();
  assert.equal(before.delaySamples, 312);
  assert.equal(after.delaySamples, 120);
  assert.equal(before.delaySamples - after.delaySamples, 192);
  t.diagnostic(`Codec-only signal delay: ${before.delayMs} ms -> ${after.delayMs} ms`);
});
