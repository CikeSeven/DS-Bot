import { DeviceRegistry as Registry } from './wasm.js'

const PAIRING_TTL_MS = 5 * 60_000

/**
 * The phones a computer trusts, and the one pairing code it may have open. A code works
 * once, ends after a time limit, and closes after a few wrong tries. `onChange` gets the
 * new list when a phone is paired or removed.
 */
export class DeviceRegistry {
  #inner
  #onChange
  #now

  constructor(devices = [], onChange = undefined, now = Date.now) {
    this.#inner = new Registry(devices)
    this.#onChange = onChange
    this.#now = now
  }

  list() {
    return this.#inner.list()
  }

  openPairing(ttlMs = PAIRING_TTL_MS) {
    return this.#inner.openPairing(ttlMs, this.#now())
  }

  closePairing() {
    this.#inner.closePairing()
  }

  pairingOpen() {
    return this.#inner.pairingOpen(this.#now())
  }

  /** Whether a device may start a handshake: it is paired, or a pairing code is open. */
  admits(deviceId, identityKey) {
    return this.#inner.admits(deviceId, identityKey, this.#now())
  }

  /** The check after the handshake: a paired device, or a new one that holds the open code. */
  authorize(deviceId, identityKey, hello = {}) {
    const { allowed, changed } = this.#inner.authorize(deviceId, identityKey, hello.name, hello.pairingCode, this.#now())
    if (changed) this.#onChange?.(this.list())
    return allowed
  }

  revoke(deviceId) {
    const removed = this.#inner.revoke(deviceId)
    if (removed) this.#onChange?.(this.list())
    return removed
  }
}
