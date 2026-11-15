// Writes byte-exact vectors from link/src so the Dart link can be checked against
// the TypeScript one. Every key and every random byte is fixed.
// Run from mobile_flutter/: node tool/gen_link_vectors.mjs  (needs `npm ci` in ../link)
import { writeFileSync } from 'node:fs'
import {
  NoiseIkSession,
  SecureMessageCodec,
  createNoisePrologue,
  deviceIdFor,
  encodeControlFrame,
  encodeHandshakeHello,
  generateKeyPair,
  identityFingerprint,
  pairingUri,
  toBase64Url,
} from '../../link/src/index.ts'

const hex = bytes => Buffer.from(bytes).toString('hex')
const fill = (start, length = 32) => Uint8Array.from({ length }, (_, i) => (start + i * 7) & 0xff)

function deterministic(seed) {
  let counter = 0
  return length => {
    const out = new Uint8Array(length)
    for (let i = 0; i < length; i += 1) out[i] = (seed + counter * 31 + i * 13) & 0xff
    counter += 1
    return out
  }
}

const phoneKeys = generateKeyPair(fill(1))
const hostKeys = generateKeyPair(fill(100))
const phoneId = deviceIdFor(phoneKeys.publicKey)
const hostId = deviceIdFor(hostKeys.publicKey)
const connectionId = '6f1c2a9e-0d4b-4c1e-9a77-3e2b5c8d1f00'
const prologue = createNoisePrologue(connectionId, hostId, phoneId)

const phone = new NoiseIkSession({
  role: 'initiator',
  localPrivateKey: phoneKeys.privateKey,
  localPublicKey: phoneKeys.publicKey,
  remotePublicKey: hostKeys.publicKey,
  prologue,
  random: deterministic(9),
})
const host = new NoiseIkSession({
  role: 'responder',
  localPrivateKey: hostKeys.privateKey,
  localPublicKey: hostKeys.publicKey,
  remotePublicKey: phoneKeys.publicKey,
  prologue,
  random: deterministic(77),
})

const phoneHello = encodeHandshakeHello({ name: 'Pixel 9 Pro', pairingCode: 'Qk3x_9-AbCdEfGhIjKlMnOpQ' })
const msg1 = phone.writeHandshake(phoneHello)
const readByHost = host.readHandshake(msg1)
const hostHello = encodeHandshakeHello({ name: 'Desk' })
const msg2 = host.writeHandshake(hostHello)
const readByPhone = phone.readHandshake(msg2)

const small = new TextEncoder().encode(JSON.stringify({ v: 1, id: 'r-1', type: 'rpc.request', timestamp: 1700000000000, payload: { method: 'bot', params: { endpoint: 'state', payload: {} } } }))
// The big message is (i * 37 + 11) & 0xff for each index i; the Dart test rebuilds it.
const big = Uint8Array.from({ length: 100_000 }, (_, i) => (i * 37 + 11) & 0xff)
const codec = new SecureMessageCodec()
const bigFrames = codec.encode(big)
const toHost = [small, ...bigFrames].map((plain, index) => ({ plain: index === 0 ? hex(plain) : `fragment:${index - 1}`, cipher: hex(phone.encrypt(plain)) }))
const reply = new TextEncoder().encode(JSON.stringify({ v: 1, id: 'e-1', type: 'event', timestamp: 1700000000001, payload: { event: 'revision', data: { revision: 7 } } }))
const toPhone = [reply, new Uint8Array(0)].map(plain => ({ plain: hex(plain), cipher: hex(host.encrypt(plain)) }))
toHost.forEach((step, index) => {
  const back = host.decrypt(Buffer.from(step.cipher, 'hex'))
  const want = index === 0 ? step.plain : hex(bigFrames[index - 1])
  if (hex(back) !== want) throw new Error('host failed to decrypt its own vector')
})

const frames = [
  { v: 1, id: 'f-1', type: 'hello', timestamp: 1700000000000, payload: { role: 'client', deviceId: phoneId, identityKey: phoneKeys.publicKey, accessToken: toBase64Url(fill(50)), protocols: [1], capabilities: ['transport.relay'] } },
  { v: 1, id: 'f-2', type: 'connect.request', timestamp: 1700000000002, payload: { hostDeviceId: hostId } },
  { v: 1, id: 'f-3', type: 'secure.handshake', timestamp: 1700000000003, payload: { connectionId, targetDeviceId: hostId, step: 1, data: toBase64Url(msg1) } },
  { v: 1, id: 'f-4', type: 'relay', timestamp: 1700000000004, payload: { connectionId, targetDeviceId: hostId, counter: 0, ciphertext: toBase64Url(Buffer.from(toHost[0].cipher, 'hex')) } },
  { v: 1, id: 'f-5', type: 'pong', timestamp: 1700000000005, payload: { nonce: 'n-1' } },
].map(frame => ({ frame, encoded: encodeControlFrame(frame) }))

const offer = { server: 'wss://relay.example.test/v1/link', hostDeviceId: hostId, hostKey: hostKeys.publicKey, code: 'Qk3x_9-AbCdEfGhIjKlMnOpQ', name: 'Desk PC 家' }

const vectors = {
  keys: {
    phone: { privateKey: phoneKeys.privateKey, publicKey: phoneKeys.publicKey, deviceId: phoneId, fingerprint: identityFingerprint(phoneKeys.publicKey) },
    host: { privateKey: hostKeys.privateKey, publicKey: hostKeys.publicKey, deviceId: hostId, fingerprint: identityFingerprint(hostKeys.publicKey) },
  },
  connectionId,
  prologue: hex(prologue),
  random: { phoneSeed: 9, hostSeed: 77 },
  handshake: {
    phoneHello: hex(phoneHello),
    msg1: hex(msg1),
    readByHost: hex(readByHost),
    hostHello: hex(hostHello),
    msg2: hex(msg2),
    readByPhone: hex(readByPhone),
  },
  transport: { toHost, toPhone },
  fragments: { length: big.length, frames: bigFrames.map(hex) },
  frames,
  pairing: { offer, uri: pairingUri(offer) },
}

writeFileSync(new URL('../test/fixtures/link_vectors.json', import.meta.url), JSON.stringify(vectors, null, 1) + '\n')
console.log('wrote test/fixtures/link_vectors.json', { msg1: msg1.length, msg2: msg2.length, fragments: bigFrames.length })
