import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Events } from 'discord.js';
import { leaveAndConfirm } from './shutdown.mjs';

function fixture() {
  const client = new EventEmitter();
  client.user = { id: 'bot' };
  const connection = { joinConfig: { guildId: 'server' } };
  const state = (id = 'bot', guildId = 'server', channelId = null) => {
    client.emit(Events.VoiceStateUpdate, {}, { id, guild: { id: guildId }, channelId });
  };
  return { client, connection, state };
}

test('subscribes before leaving and waits for the bot departure acknowledgement', async () => {
  const f = fixture();
  let completed = false;
  const result = leaveAndConfirm(f.client, f.connection, () => {
    f.state('other');
    f.state('bot', 'other-server');
    f.state('bot', 'server', 'still-connected');
  }).then(value => { completed = true; return value; });
  await Promise.resolve();
  assert.equal(completed, false);
  f.state();
  assert.equal(await result, true);
  assert.equal(f.client.listenerCount(Events.VoiceStateUpdate), 0);
});

test('handles an acknowledgement emitted synchronously by leave', async () => {
  const f = fixture();
  assert.equal(await leaveAndConfirm(f.client, f.connection, () => f.state()), true);
  assert.equal(f.client.listenerCount(Events.VoiceStateUpdate), 0);
});

test('bounds a missing acknowledgement and removes the listener', async () => {
  const f = fixture();
  assert.equal(await leaveAndConfirm(f.client, f.connection, () => {}, 10), false);
  assert.equal(f.client.listenerCount(Events.VoiceStateUpdate), 0);
});

test('logout without a voice connection does not wait for a voice event', async () => {
  const f = fixture();
  let called = false;
  assert.equal(await leaveAndConfirm(f.client, null, () => { called = true; }), true);
  assert.equal(called, true);
  assert.equal(f.client.listenerCount(Events.VoiceStateUpdate), 0);
});

test('cleans up if leaving throws', async () => {
  const f = fixture();
  await assert.rejects(leaveAndConfirm(f.client, f.connection, () => {
    throw new Error('leave failed');
  }), /leave failed/);
  assert.equal(f.client.listenerCount(Events.VoiceStateUpdate), 0);
});
