import assert from 'node:assert/strict'
import { test } from 'node:test'
import { actFields, isActCall } from '../src/host/acts.js'

const bots = [{ id: 'b-chief', name: 'Chief' }, { id: 'b-writer', name: 'Writer' }]
const rooms = [{ id: 'r-launch', name: 'Launch' }]
const scope = {
  selfId: 'b-chief',
  findBot: ref => bots.find(bot => bot.id === ref || bot.name.toLowerCase() === String(ref ?? '').toLowerCase()),
  findRoom: ref => rooms.find(room => room.id === ref || room.name === ref),
  appOf: callId => (callId === 'c-known' ? 'Notes' : undefined),
}
const ok = text => ({ text, isError: false, content: [{ type: 'text', text }] })
const failed = (text, code) => ({ text, isError: true, code, content: [{ type: 'text', text }] })

test('only the calls the desktop chat draws are team actions', () => {
  for (const name of ['message_bot', 'stop_bot', 'create_bot', 'update_bot', 'create_group', 'post_to_group', 'read_group_chat', 'remember', 'forget', 'cua', 'cua_driver_native__click']) {
    assert.equal(isActCall(name), true, name)
  }
  for (const name of ['read', 'bash', 'web_search', 'ask_user', 'show_view', 'group_relay', 'recall', undefined]) {
    assert.equal(isActCall(name), false, String(name))
  }
})

test('a message to a Bot shows while it runs and names the sender for the exchange', () => {
  assert.deepEqual(actFields({ name: 'message_bot', args: { to: 'writer' } }, undefined, scope),
    { act: 'message', state: 'running', bot: { id: 'b-writer', name: 'Writer' }, from: 'b-chief' })
  assert.equal(actFields({ name: 'message_bot', args: { to: 'Writer' } }, failed('No such Bot'), scope).state, 'failed')
  // A Bot that is gone keeps its name on the line, without an id to open.
  assert.deepEqual(actFields({ name: 'stop_bot', args: { bot: 'Ghost' } }, ok('Stopped'), scope).bot, { name: 'Ghost' })
})

test('a Bot made or changed shows once the call is done and the Bot is there', () => {
  assert.equal(actFields({ name: 'create_bot', args: { name: 'Writer' } }, undefined, scope), undefined)
  assert.deepEqual(actFields({ name: 'create_bot', args: { name: 'Writer' } }, ok('Created'), scope),
    { act: 'create-bot', state: 'done', bot: { id: 'b-writer', name: 'Writer' } })
  assert.equal(actFields({ name: 'create_bot', args: { name: 'Nobody' } }, ok('Created'), scope), undefined)
  assert.deepEqual(actFields({ name: 'update_bot', args: { instructions: 'x' } }, ok('Updated'), scope),
    { act: 'update-bot', state: 'done', bot: { id: 'b-chief', name: 'Chief' }, self: true })
})

test('a group change reads the group from the result and a refusal says it failed', () => {
  assert.deepEqual(actFields({ name: 'create_group', args: {} }, ok('Created group "Launch" with 2 members'), scope),
    { act: 'group', verb: 'created', state: 'done', room: { id: 'r-launch', name: 'Launch' } })
  assert.deepEqual(actFields({ name: 'delete_group', args: {} }, ok('Deleted "Launch"'), scope),
    { act: 'group', verb: 'deleted', state: 'done', room: { name: 'Launch' } })
  assert.deepEqual(actFields({ name: 'post_to_group', args: {} }, ok('Not a member'), scope),
    { act: 'group', verb: 'posted', state: 'failed' })
  assert.equal(actFields({ name: 'post_to_group', args: {} }, undefined, scope), undefined)
  assert.deepEqual(actFields({ name: 'read_group_chat', args: { group: 'Launch' } }, ok('…'), scope),
    { act: 'read-group', state: 'done', room: { id: 'r-launch', name: 'Launch' } })
})

test('a memory change names whose memory and the panel that shows it', () => {
  assert.deepEqual(actFields({ name: 'remember', args: { text: 'x' } }, ok('Saved to your memory'), scope),
    { act: 'memory', tool: 'remember', state: 'done', outcome: 'saved', whose: 'self', open: { botId: 'b-chief' } })
  assert.deepEqual(actFields({ name: 'remember', args: { scope: 'team' } }, ok('Saved to team memory'), scope),
    { act: 'memory', tool: 'remember', state: 'done', outcome: 'saved', whose: 'team', open: { botId: 'b-chief' } })
  assert.deepEqual(actFields({ name: 'remember', args: { scope: 'Writer' } }, ok("Saved to Writer's memory"), scope),
    { act: 'memory', tool: 'remember', state: 'done', outcome: 'saved', whose: 'bot', bot: { id: 'b-writer', name: 'Writer' }, open: { botId: 'b-writer' } })
  assert.deepEqual(actFields({ name: 'remember', args: {} }, ok('Already in your memory'), scope),
    { act: 'memory', tool: 'remember', state: 'done', outcome: 'already', open: { botId: 'b-chief' } })
  assert.deepEqual(actFields({ name: 'forget', args: {} }, failed('nothing', 'memory/no-match'), scope),
    { act: 'memory', tool: 'forget', state: 'failed', outcome: 'failed', code: 'memory/no-match', open: { botId: 'b-chief' } })
  // The group's memory in a group Session; nowhere to open from a Bot's own chat.
  assert.deepEqual(actFields({ name: 'remember', args: { scope: 'group' } }, ok('Something else'), { ...scope, roomId: 'r-launch' }).open, { roomId: 'r-launch' })
  assert.equal(actFields({ name: 'remember', args: { scope: 'group' } }, ok('Something else'), scope).open, undefined)
})

test('a computer step names the app and carries its screenshot', () => {
  assert.deepEqual(actFields({ name: 'cua', args: { method: 'click' }, callId: 'c-known' }, undefined, scope),
    { act: 'computer', state: 'running', method: 'click', app: 'Notes' })
  assert.deepEqual(actFields({ name: 'cua', args: { method: 'getApp', params: { selector: 'Safari' } }, callId: 'c-1' }, ok('ok'), scope),
    { act: 'computer', state: 'done', method: 'getApp', app: 'Safari' })
  const shot = { text: '', isError: false, content: [{ type: 'text', text: 'ok' }, { type: 'image', attachment: { attachmentId: 'sha256:shot', mediaType: 'image/png' } }] }
  assert.deepEqual(actFields({ name: 'cua_driver_native__screenshot', args: {}, callId: 'c-2' }, shot, scope),
    { act: 'computer', state: 'done', method: 'screenshot', shot: { attachmentId: 'sha256:shot', mime: 'image/png' } })
})
