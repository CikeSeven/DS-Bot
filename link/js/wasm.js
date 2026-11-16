// Loads the protocol code before anything uses it. The build places link.wasm next to
// link.js, and import.meta.url is link.js once bundled.
import { readFileSync } from 'node:fs'
import { initSync } from 'dsbot-link-wasm'

initSync({ module: readFileSync(new URL('./link.wasm', import.meta.url)) })

export {
  ClientCore,
  DeviceRegistry,
  HostCore,
  RelayCore,
  deviceIdFor,
  generateKeyPair,
  identityFingerprint,
  linkPath,
  pairingUri,
  parsePairingUri,
  randomToken,
} from 'dsbot-link-wasm'
