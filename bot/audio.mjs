import OpusScript from 'opusscript';
import { createAudioResource, StreamType } from '@discordjs/voice';
import { LivePCM } from './pcm.mjs';

export function createLiveAudio(bitrate = 128000) {
  // Encode on demand instead of filling a second readable/writable transform.
  const encoder = new OpusScript(48000, 2, OpusScript.Application.AUDIO);
  encoder.encoderCTL(4002, bitrate); // OPUS_SET_BITRATE
  const source = new LivePCM({ encodeFrame: frame => encoder.encode(frame, 960) });
  source.once('close', () => encoder.delete());
  const resource = createAudioResource(source, { inputType: StreamType.Opus });
  return { source, resource };
}
