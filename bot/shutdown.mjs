import { Events } from 'discord.js';

// Keep the gateway alive until Discord acknowledges our own channel departure.
// Register first: the acknowledgement may arrive while leave() is running.
export function leaveAndConfirm(client, connection, leave, timeoutMs = 3000) {
  if (!connection) { leave(); return Promise.resolve(true); }
  const guildId = connection.joinConfig.guildId;
  return new Promise((resolve, reject) => {
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      client.off(Events.VoiceStateUpdate, onState);
    };
    const finish = confirmed => { cleanup(); resolve(confirmed); };
    const onState = (_before, after) => {
      if (after.id === client.user?.id && after.guild.id === guildId && after.channelId === null) {
        finish(true);
      }
    };
    client.on(Events.VoiceStateUpdate, onState);
    timer = setTimeout(() => finish(false), timeoutMs);
    try { leave(); }
    catch (error) { cleanup(); reject(error); }
  });
}
