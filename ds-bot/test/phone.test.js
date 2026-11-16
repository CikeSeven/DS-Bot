import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { apply } from '../index.js'
import { HostLink, PhoneLink, deviceIdFor, generateKeyPair, parsePairingUri, randomToken } from '../link.js'
import { fakeContext } from './fake-ctx.js'
import { startRelay } from './support/relay.js'
import { DEFAULT_SERVER } from '../src/host/phone.js'

const TEAM = {
  version: 1,
  mainBotIds: ['m1'],
  revision: 1,
  bots: { m1: { id: 'm1', sessionId: 'm1', name: 'Chief', role: 'Chief of Staff', instructions: '', createdAt: 1 } },
  rooms: {},
  exchanges: [],
  exchangeTurns: {},
  questions: {},
}

const server = await startRelay()
after(() => server.close())

function open(home) {
  const ctx = fakeContext()
  const register = ctx.connection.fetch.register
  ctx.connection.fetch.register = (route) => { ctx.route = route; return register(route) }
  apply(ctx, { home, github: false })
  const call = async (endpoint, payload) => (await (await ctx.route.fetch(new Request('http://localhost/api/bot', { method: 'POST', body: JSON.stringify({ endpoint, payload }) }))).json())
  return { ctx, call }
}

function openDesk(t) {
  const home = mkdtempSync(join(tmpdir(), 'dsb-phone-'))
  writeFileSync(join(home, 'state.json'), JSON.stringify(TEAM))
  const opened = open(home)
  t.after(async () => { await opened.ctx.dispose(); rmSync(home, { recursive: true, force: true, maxRetries: 5 }) })
  return opened
}

async function until(read, check) {
  for (let tries = 0; tries < 200; tries += 1) {
    const value = await read()
    if (check(value)) return value
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  throw new Error('timed out')
}

/** A phone for the computer in `offer`; `options` is `{pairingCode?, name?, keys?, token?, createSocket?}`. */
function phone(offer, { keys = generateKeyPair(), token = randomToken(), ...options } = {}) {
  const link = new PhoneLink({
    server: offer.server,
    identity: { deviceId: deviceIdFor(keys.publicKey), ...keys },
    accessToken: token,
    hostDeviceId: offer.hostDeviceId,
    hostKey: offer.hostKey,
    ...options,
  })
  after(() => link.close())
  return { link, keys, token }
}

async function pairedPhone(call, options = {}) {
  await call('phone-set', { server: server.url, on: true })
  await until(() => call('state', {}), state => state.value.phone.status === 'online')
  const offer = parsePairingUri((await call('phone-pair', {})).value.pairing.uri)
  const paired = phone(offer, { pairingCode: offer.code, name: 'Pixel', ...options })
  await paired.link.connect()
  return { ...paired, offer }
}

test('a phone pairs with the QR code and calls the same endpoints as the window', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'dsb-phone-'))
  writeFileSync(join(home, 'state.json'), JSON.stringify(TEAM))
  let desk = open(home)
  t.after(async () => { await desk.ctx.dispose(); rmSync(home, { recursive: true, force: true, maxRetries: 5 }) })

  const first = await desk.call('state', {})
  assert.deepEqual(first.value.phone, { server: DEFAULT_SERVER, on: false, status: 'off', phones: [], pairing: null })
  assert.equal((await desk.call('phone-set', { server: 'http://relay.test' })).error.code, 'bot/invalid')
  assert.equal((await desk.call('phone-pair', {})).ok, false)

  await desk.call('phone-set', { server: server.url, on: true })
  await until(() => desk.call('state', {}), state => state.value.phone.status === 'online')
  if (process.platform !== 'win32') assert.equal(statSync(join(home, 'phone.json')).mode & 0o777, 0o600)

  const paired = await desk.call('phone-pair', {})
  const offer = parsePairingUri(paired.value.pairing.uri)
  const pixel = phone(offer, { pairingCode: offer.code, name: 'Pixel' })
  await pixel.link.connect()
  const state = await pixel.link.rpc('bot', { endpoint: 'state', payload: {} })
  assert.equal(state.ok, true)
  assert.deepEqual(state.value.bots.map(bot => bot.name), ['Chief'])
  const refused = await pixel.link.rpc('bot', { endpoint: 'phone-pair', payload: {} })
  assert.equal(refused.error.code, 'bot/refused')

  const listed = (await desk.call('state', {})).value.phone
  assert.equal(listed.pairing, null)
  assert.deepEqual(listed.phones.map(entry => [entry.name, entry.connected]), [['Pixel', true]])
  pixel.link.close()

  // The computer keeps its identity across restarts, so the phone comes back without a code.
  await desk.ctx.dispose()
  desk = open(home)
  await until(() => desk.call('state', {}), next => next.value.phone.status === 'online')
  const again = phone(offer, { keys: pixel.keys, token: pixel.token })
  await again.link.connect()
  assert.equal((await again.link.rpc('bot', { endpoint: 'state', payload: {} })).ok, true)

  const rejected = new Promise(resolve => again.link.onStatus(status => { if (status.status === 'rejected') resolve(status.code) }))
  const removed = await desk.call('phone-remove', { id: listed.phones[0].id })
  assert.deepEqual(removed.value.phones, [])
  assert.equal(await rejected, 'DEVICE_REVOKED')
  await assert.rejects(phone(offer, { keys: pixel.keys, token: pixel.token }).link.connect(), { code: 'NOT_PAIRED' })

  await desk.call('phone-set', { on: false })
  assert.equal((await desk.call('state', {})).value.phone.status, 'off')
})

test('a phone write that moved the team carries the new state in its reply', async (t) => {
  const { call } = openDesk(t)
  const { link } = await pairedPhone(call)

  const before = (await link.rpc('bot', { endpoint: 'state', payload: {} })).value.revision

  // The write reply doubles as the `state` answer the phone would have asked for.
  const written = await link.rpc('bot', { endpoint: 'update-bot', payload: { id: 'm1', color: '#112233' }, state: { since: before, avatars: 'ref' } })
  assert.equal(written.ok, true)
  assert.equal(written.state.revision, before + 1)
  assert.equal(written.state.bots.find(bot => bot.id === 'm1').color, '#112233')

  // A read with `state` attached carries none: the revision never moved.
  const read = await link.rpc('bot', { endpoint: 'models', payload: {}, state: { since: before } })
  assert.equal(read.ok, true)
  assert.equal(read.state, undefined)

  // A rejected write stays a failure and carries no state.
  const failed = await link.rpc('bot', { endpoint: 'update-bot', payload: { id: 'ghost', color: '#112233' }, state: { since: before } })
  assert.equal(failed.ok, false)
  assert.equal(failed.state, undefined)
})

test('a bare Server host means the link path; a dead Server shows why', async (t) => {
  const { call } = openDesk(t)

  // Bare host: the link path is implied.
  const bare = server.url.replace(/\/v2\/link$/, '')
  await call('phone-set', { server: bare, on: true })
  assert.equal((await call('state', {})).value.phone.server, server.url)
  await until(() => call('state', {}), state => state.value.phone.status === 'online')

  // An explicit path is kept as typed. The dead Server is a closed local port, so the
  // refusal is immediate wherever the test runs (a public name may hang on DNS or TCP).
  await call('phone-set', { server: 'ws://127.0.0.1:1/some-path' })
  assert.equal((await call('state', {})).value.phone.server, 'ws://127.0.0.1:1/some-path')
  const state = await until(() => call('state', {}), next => next.value.phone.status === 'offline')
  assert.equal(typeof state.value.phone.error, 'string')

  // Turned off and cleared, the address falls back to the DS Bot relay (off, so nothing dials it).
  await call('phone-set', { on: false })
  await call('phone-set', { server: '' })
  assert.equal((await call('state', {})).value.phone.server, DEFAULT_SERVER)
})

test('the DS Bot relay\'s v1 address in phone.json means the default', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'dsb-phone-'))
  writeFileSync(join(home, 'state.json'), JSON.stringify(TEAM))
  writeFileSync(join(home, 'phone.json'), JSON.stringify({ server: 'wss://bot.sisct.xyz/v1/link', on: false, devices: [] }))
  const { ctx, call } = open(home)
  t.after(async () => { await ctx.dispose(); rmSync(home, { recursive: true, force: true, maxRetries: 5 }) })
  assert.equal((await call('state', {})).value.phone.server, DEFAULT_SERVER)
})

test('a call in flight lives through a dropped phone socket, with no new handshake', async (t) => {
  const keys = generateKeyPair()
  const identity = { deviceId: deviceIdFor(keys.publicKey), ...keys }
  const phoneKeys = generateKeyPair()
  let handshakes = 0
  const ran = []
  let entered
  const reached = new Promise(resolve => { entered = resolve })
  let release
  const held = new Promise(resolve => { release = resolve })
  const host = new HostLink({
    url: server.url,
    identity,
    accessToken: randomToken(),
    name: 'Desk',
    admits: deviceId => deviceId === deviceIdFor(phoneKeys.publicKey),
    authorize: async () => { handshakes += 1; return true },
    handle: async (method, params) => {
      ran.push(params.n)
      if (params.hold) {
        entered()
        await held
      }
      return { n: params.n }
    },
  })
  t.after(() => host.stop())
  host.start()
  await host.waitOnline()

  const { link } = phone({ server: server.url, hostDeviceId: identity.deviceId, hostKey: identity.publicKey }, { keys: phoneKeys })
  const statuses = []
  link.onStatus(status => statuses.push(status))
  await link.connect()
  assert.equal(link.hostName, 'Desk')

  const slow = link.rpc('echo', { n: 1, hold: true })
  await reached
  // This one may leave on the socket that is about to drop, or wait for the next one.
  const quick = link.rpc('echo', { n: 2 })
  link.networkChanged()
  await until(() => link.status, status => status.status === 'online')
  release()

  assert.deepEqual(await slow, { n: 1 })
  assert.deepEqual(await quick, { n: 2 })
  assert.deepEqual(ran.sort(), [1, 2])
  assert.equal(handshakes, 1)
  assert.ok(statuses.some(status => status.status === 'reconnecting'))
  assert.deepEqual(statuses.filter(status => status.status === 'online'), [{ status: 'online', resumed: false }, { status: 'online', resumed: true }])
})

test('feed events sent while the phone is away arrive when it is back, in order', async (t) => {
  const { call } = openDesk(t)
  let away = false
  const { link } = await pairedPhone(call, { createSocket: url => new WebSocket(away ? 'ws://127.0.0.1:1/' : url) })
  const revisions = []
  link.onEvent((name, data) => { if (name === 'revision') revisions.push(data.revision) })
  const before = (await link.rpc('bot', { endpoint: 'state', payload: {} })).value.revision

  away = true
  link.networkChanged()
  await until(() => call('state', {}), state => state.value.phone.phones[0].connected === false)
  for (const color of ['#111111', '#222222', '#333333']) assert.equal((await call('update-bot', { id: 'm1', color })).ok, true)
  const last = (await call('state', {})).value.revision
  assert.ok(last >= before + 3)
  assert.equal(revisions.filter(revision => revision > before).length, 0)

  away = false
  link.networkChanged()
  await until(() => revisions, got => got.includes(last))
  const expected = Array.from({ length: last - before }, (_, index) => before + 1 + index)
  assert.deepEqual(revisions.filter(revision => revision > before), expected)
  assert.deepEqual(link.status, { status: 'online', resumed: true })
})
