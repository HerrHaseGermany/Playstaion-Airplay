import { Client, Events, GatewayIntentBits, ChannelType, PermissionFlagsBits } from 'discord.js';
import {
  joinVoiceChannel, entersState, VoiceConnectionStatus, createAudioPlayer,
  NoSubscriberBehavior, generateDependencyReport,
} from '@discordjs/voice';
import { validateConfig } from './pcm.mjs';
import { createLiveAudio } from './audio.mjs';

if (process.argv.includes('--doctor')) {
  console.log(generateDependencyReport());
  process.exit(0);
}

const emit = (event, detail = {}) => process.stdout.write(`${JSON.stringify({ event, ...detail })}\n`);
const client = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates] });
let connection, player, source, silenceTimer, connectTimer;
let ending = false;
let secret = '';
const clean = value => String(value).split(secret || '\0').join('[redacted]');

function stop(code = 0) {
  if (ending) return;
  ending = true;
  clearInterval(silenceTimer);
  clearTimeout(connectTimer);
  player?.stop(true);
  source?.destroy();
  connection?.destroy();
  client.destroy();
  process.exit(code);
}

function fail(error) {
  emit('error', { message: clean(error?.message ?? error) });
  stop(1);
}

process.on('SIGTERM', () => stop());
process.on('SIGINT', () => stop());
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);
client.on(Events.Error, fail);
process.stdin.on('end', () => stop());
process.stdin.on('error', fail);

async function connect(input) {
  const config = validateConfig(input);
  secret = config.token;
  connectTimer = setTimeout(() => fail(new Error('Discord connection timed out. Check your network and reconnect.')), 45_000);
  emit('status', { message: 'Signing in to Discord…' });
  const ready = new Promise(resolve => client.once(Events.ClientReady, resolve));
  await client.login(config.token);
  await ready;
  const channel = await client.channels.fetch(config.channelId);
  if (!channel || channel.type !== ChannelType.GuildVoice) {
    throw new Error('Choose a regular server voice channel, not a DM or Stage channel.');
  }
  const me = await channel.guild.members.fetchMe();
  const permissions = channel.permissionsFor(me);
  if (![PermissionFlagsBits.ViewChannel, PermissionFlagsBits.Connect, PermissionFlagsBits.Speak]
    .every(flag => permissions?.has(flag))) {
    throw new Error('The bot needs View Channel, Connect, and Speak in this channel.');
  }
  emit('status', { message: `Joining ${channel.name}…` });
  connection = joinVoiceChannel({
    channelId: channel.id, guildId: channel.guild.id,
    adapterCreator: channel.guild.voiceAdapterCreator,
    selfDeaf: true, selfMute: false,
  });
  connection.on('error', fail);
  connection.on(VoiceConnectionStatus.Disconnected, async () => {
    emit('reconnecting', { message: 'Voice disconnected; reconnecting…' });
    try {
      await entersState(connection, VoiceConnectionStatus.Ready, 15_000);
      emit('reconnected', { message: 'Voice reconnected.' });
    } catch { fail(new Error('Voice connection lost. Stop and reconnect.')); }
  });
  await entersState(connection, VoiceConnectionStatus.Ready, 30_000);
  const audio = createLiveAudio(Math.min(channel.bitrate, 128_000));
  source = audio.source;
  player = createAudioPlayer({ behaviors: { noSubscriber: NoSubscriberBehavior.Play } });
  player.on('error', fail);
  connection.subscribe(player);
  player.play(audio.resource);
  let lastAudio = Date.now();
  process.stdin.on('data', chunk => { lastAudio = Date.now(); source.feed(chunk); });
  // Keep a valid live resource when macOS emits no samples during silence.
  silenceTimer = setInterval(() => {
    if (Date.now() - lastAudio > 40) source.feed(Buffer.alloc(3840));
  }, 20);
  emit('ready', { channel: channel.name, bot: client.user.username });
  clearTimeout(connectTimer);
  process.stdin.resume();
}

// One JSON configuration line, followed by raw PCM on the same private pipe.
let header = Buffer.alloc(0);
function readHeader(chunk) {
  header = Buffer.concat([header, chunk]);
  if (header.length > 8192) return fail(new Error('Configuration is too large.'));
  const newline = header.indexOf(10);
  if (newline < 0) return;
  process.stdin.pause();
  process.stdin.removeListener('data', readHeader);
  const extra = header.subarray(newline + 1);
  if (extra.length) process.stdin.unshift(extra);
  try { connect(JSON.parse(header.subarray(0, newline).toString())).catch(fail); }
  catch (error) { fail(error); }
  header = Buffer.alloc(0);
}
process.stdin.on('data', readHeader);
