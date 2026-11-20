import OpusScript from 'opusscript';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
import { createAudioResource, StreamType } from '@discordjs/voice';
import { createLiveAudio } from '../bot/audio.mjs';
import { LivePCM, FRAME_BYTES } from '../bot/pcm.mjs';

// A controlled comparison of codec signal delay. This does not measure Core
// Audio, Discord transport, network jitter, or the PlayStation receiver.
export function previousAudioPipeline() {
  const encoder = new OpusScript(48000, 2, OpusScript.Application.AUDIO);
  encoder.encoderCTL(4002, 128000);
  const source = new LivePCM({ encodeFrame: frame => encoder.encode(frame, 960) });
  source.once('close', () => encoder.delete());
  return { source, resource: createAudioResource(source, { inputType: StreamType.Opus }) };
}

export async function measureCodecDelay(factory = createLiveAudio) {
  const count = 18 * 960;
  const reference = new Float64Array(count);
  const decoded = new Float64Array(count);
  let seed = 27;
  for (let i = 0; i < count; i++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    reference[i] = Math.round((seed / 4294967296 * 2 - 1) * 10000);
  }
  const { source, resource } = factory();
  const decoder = new OpusScript(48000, 2, OpusScript.Application.AUDIO);
  try {
    for (let frame = 0; frame < 18; frame++) {
      const pcm = Buffer.alloc(FRAME_BYTES);
      for (let i = 0; i < 960; i++) {
        const value = reference[frame * 960 + i];
        pcm.writeInt16LE(value, i * 4);
        pcm.writeInt16LE(-value, i * 4 + 2);
      }
      const readable = once(source, 'readable');
      source.feed(pcm);
      await readable;
      const packet = resource.playStream.read();
      const audio = decoder.decode(packet);
      for (let i = 0; i < 960; i++) decoded[frame * 960 + i] = audio.readInt16LE(i * 4);
    }
    let bestLag = 0, bestScore = -Infinity;
    for (let lag = 0; lag < 960; lag++) {
      let score = 0;
      for (let i = 1920; i < count - 960; i++) score += reference[i] * decoded[i + lag];
      if (score > bestScore) { bestScore = score; bestLag = lag; }
    }
    return { delaySamples: bestLag, delayMs: bestLag / 48 };
  } finally {
    source.destroy();
    decoder.delete();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const before = await measureCodecDelay(previousAudioPipeline);
  const after = await measureCodecDelay();
  console.log(JSON.stringify({ scope: 'codec only; not end-to-end', before, after,
    savedMs: before.delayMs - after.delayMs }, null, 2));
}
