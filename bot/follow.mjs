import { Events } from 'discord.js';

// Voice states are seeded by Discord at login. Recompute across shared guilds
// so a late leave event from the previous server cannot cancel a new join.
export function watchUser(client, userId, onTarget) {
  let previous;
  const refresh = () => {
    const channels = new Map();
    for (const guild of client.guilds.cache.values()) {
      if (guild.available === false) continue;
      const state = guild.voiceStates.cache.get(userId);
      if (state?.channelId) channels.set(state.channelId, state.channelId);
    }
    // An ambiguous multi-server state must not broadcast to an arbitrary room.
    const target = channels.size === 1 ? channels.values().next().value : null;
    if (target !== previous) { previous = target; onTarget(target); }
  };
  const update = (before, after) => {
    if (after.id === userId && before.channelId !== after.channelId) refresh();
  };
  client.on(Events.VoiceStateUpdate, update);
  client.on(Events.GuildCreate, refresh);
  client.on(Events.GuildDelete, refresh);
  client.on(Events.GuildUnavailable, refresh);
  refresh();
  return () => {
    client.off(Events.VoiceStateUpdate, update);
    client.off(Events.GuildCreate, refresh);
    client.off(Events.GuildDelete, refresh);
    client.off(Events.GuildUnavailable, refresh);
  };
}
