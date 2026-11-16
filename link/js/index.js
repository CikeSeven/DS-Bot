// The DS Bot phone link for the computer. The protocol is the Rust in ../crates, built
// to link.wasm; this is the JavaScript around it: sockets, timers and the app's callbacks.
// ds-bot/link.js is bundled from here by ds-bot/scripts/build-link.mjs.
import { linkPath } from './wasm.js'

export { DeviceRegistry } from './registry.js'
export { HostLink } from './host.js'
export { PhoneLink } from './phone.js'
export { RelayCore, deviceIdFor, generateKeyPair, identityFingerprint, pairingUri, parsePairingUri, randomToken } from './wasm.js'

/** Where the Relay Server listens; a bare Server host means this path. */
export const LINK_PATH = linkPath()
