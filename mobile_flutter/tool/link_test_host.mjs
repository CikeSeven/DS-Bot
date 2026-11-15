// A Relay Server and a computer (HostLink) from ../link, driven over stdin/stdout
// so Dart tests can check the Dart link against the real thing.
// Each stdout line is JSON. Commands on stdin, one per line:
//   {"cmd":"pair"}                → {"pair":{code}}
//   {"cmd":"revoke","id":"d-…"}   → {"revoked":true}
//   {"cmd":"emit","event":"…","data":…}
//   {"cmd":"stop-host"} / {"cmd":"start-host"}
import { createInterface } from 'node:readline'
import { DeviceRegistry, HostLink, deviceIdFor, generateKeyPair, randomToken } from '../../link/src/index.ts'
import { startRelayServer } from '../../link/server/server.ts'

const server = await startRelayServer()
const keys = generateKeyPair()
const self = { deviceId: deviceIdFor(keys.publicKey), ...keys }
const registry = new DeviceRegistry()
const token = randomToken()

function makeHost() {
  return new HostLink({
    url: server.url,
    identity: self,
    accessToken: token,
    name: 'Desk',
    admits: (deviceId, key) => registry.admits(deviceId, key),
    authorize: (deviceId, key, hello) => registry.authorize(deviceId, key, hello),
    handle: async (method, params, request) => {
      if (method === 'slow') await new Promise(resolve => setTimeout(resolve, 2_000))
      if (method === 'fail') throw Object.assign(new Error('Nope'), { code: 'bot/refused' })
      return { method, params, deviceId: request.deviceId }
    },
    retryMs: [50, 200],
  })
}

let host = makeHost()
host.start()
await host.waitOnline()
const say = value => process.stdout.write(JSON.stringify(value) + '\n')
say({ ready: { url: server.url, hostDeviceId: self.deviceId, hostKey: self.publicKey } })

for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line)
  if (command.cmd === 'pair') say({ pair: registry.openPairing() })
  else if (command.cmd === 'revoke') {
    registry.revoke(command.id)
    host.disconnect(command.id)
    say({ revoked: true })
  } else if (command.cmd === 'emit') { host.emit(command.event, command.data); say({ emitted: true }) }
  else if (command.cmd === 'stop-host') { await host.stop(); say({ hostStopped: true }) }
  else if (command.cmd === 'start-host') { host = makeHost(); host.start(); await host.waitOnline(); say({ hostStarted: true }) }
  else if (command.cmd === 'devices') say({ devices: registry.list() })
}
await host.stop()
await server.close()
process.exit(0)
