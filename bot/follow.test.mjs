import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Events } from 'discord.js';
import { watchUser } from './follow.mjs';
import { validateConfig } from './pcm.mjs';

const userId = '123456789012345678';
function fixture(initialChannel = null) {
  const client = new EventEmitter();
  const guild = { voiceStates: { cache: new Map() }, available: true };
  if (initialChannel) guild.voiceStates.cache.set(userId, { channelId: initialChannel });
  client.guilds = { cache: new Map([['guild', guild]]) };
  const targets = [];
  const close = watchUser(client, userId, target => targets.push(target));
  function move(channelId, id = userId) {
    const previous = guild.voiceStates.cache.get(id)?.channelId ?? null;
    guild.voiceStates.cache.set(id, { channelId });
    client.emit(Events.VoiceStateUpdate, { id, channelId: previous }, { id, channelId });
  }
  return { client, guild, targets, close, move };
}

test('follow config needs a user ID but no fixed channel', () => {
  assert.deepEqual(validateConfig({ token: ' token ', followUser: true, userId }),
    { token: 'token', followUser: true, userId });
  for (const invalid of ['', 'name', 123456789012345678, null]) {
    assert.throws(() => validateConfig({ token: 'token', followUser: true, userId: invalid }));
  }
  assert.throws(() => validateConfig({ token: 'token', followUser: false, userId }));
});

test('starts in the existing channel, follows moves, and leaves on disconnect', () => {
  const f = fixture('one');
  f.move('two');
  f.move(null);
  f.move('three');
  assert.deepEqual(f.targets, ['one', 'two', null, 'three']);
  f.close();
});

test('waits initially and ignores other users and mute changes', () => {
  const f = fixture();
  f.move('other-room', 'someone-else');
  f.move('one');
  f.move('one');
  assert.deepEqual(f.targets, [null, 'one']);
  f.close();
  f.move('two');
  assert.deepEqual(f.targets, [null, 'one']);
});

test('cross-server event reordering never selects an arbitrary room', () => {
  const f = fixture('one');
  f.client.guilds.cache.set('second', { available: true,
    voiceStates: { cache: new Map([[userId, { channelId: 'two' }]]) } });
  f.client.emit(Events.GuildCreate);
  f.move(null);
  assert.deepEqual(f.targets, ['one', null, 'two']);
  f.close();
});

test('leaves an unavailable server and resumes after availability returns', () => {
  const f = fixture('one');
  f.guild.available = false;
  f.client.emit(Events.GuildUnavailable);
  f.guild.available = true;
  f.client.emit(Events.GuildCreate);
  f.client.guilds.cache.clear();
  f.client.emit(Events.GuildDelete);
  assert.deepEqual(f.targets, ['one', null, 'one', null]);
  f.close();
});
