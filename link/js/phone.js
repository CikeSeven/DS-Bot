import { Driver } from './driver.js'
import { ClientCore } from './wasm.js'

/**
 * The phone's end of the link, for tests on the computer. The phone app runs the same
 * ClientCore natively.
 *
 * options: `{server, identity, accessToken, hostDeviceId, hostKey, name?, pairingCode?, createSocket?}`
 */
export class PhoneLink {
  #core
  #driver
  #calls = new Map()
  #eventListeners = new Set()
  #statusListeners = new Set()

  constructor({ server, identity, accessToken, hostDeviceId, hostKey, name, pairingCode, createSocket }) {
    this.#core = new ClientCore({ server, identity, accessToken, hostDeviceId, hostKey, name, pairingCode }, Date.now())
    this.#driver = new Driver(this.#core, action => this.#act(action), createSocket)
  }

  /** `{status, ...}` as `onStatus` hears it, or undefined before `connect`. */
  get status() { return this.#core.status() }

  get hostName() { return this.#core.hostName() }

  /** Starts the link. Resolves when it is first online; rejects with the `code` of a refusal. */
  connect() {
    return new Promise((resolve, reject) => {
      const off = this.onStatus(status => {
        if (status.status === 'online') {
          off()
          resolve()
        } else if (status.status === 'rejected' || status.status === 'closed') {
          off()
          reject(Object.assign(new Error(status.message ?? 'The link was closed.'), { code: status.code ?? 'CLIENT_CLOSED' }))
        }
      })
      this.#driver.run((core, now) => core.start(now))
    })
  }

  /** Calls the computer. A `timeoutMs` of 0 means the default, 60 s. */
  rpc(method, params, { timeoutMs = 0 } = {}) {
    return new Promise((resolve, reject) => {
      const json = JSON.stringify(params ?? null)
      this.#driver.run((core, now) => { this.#calls.set(core.rpc(method, json, timeoutMs, now), { resolve, reject }) })
    })
  }

  /** `listener(name, data)` for each event the computer emits. Returns the unsubscribe. */
  onEvent(listener) {
    this.#eventListeners.add(listener)
    return () => this.#eventListeners.delete(listener)
  }

  /** `listener({status, resumed?, attempt?, error?, code?, message?})` on each change. Returns the unsubscribe. */
  onStatus(listener) {
    this.#statusListeners.add(listener)
    return () => this.#statusListeners.delete(listener)
  }

  /** Drops the socket and dials again at once, as the app does when the network changes. */
  networkChanged() {
    this.#driver.run((core, now) => core.networkChanged(now))
  }

  close() {
    this.#driver.run((core, now) => core.close(now))
    this.#driver.halt()
  }

  #act(action) {
    switch (action.type) {
      case 'status': {
        const { type: _, ...status } = action
        for (const listener of this.#statusListeners) listener(status)
        return
      }
      case 'event':
        for (const listener of this.#eventListeners) listener(action.name, JSON.parse(action.data))
        return
      case 'rpcDone': return this.#done(action)
    }
  }

  #done({ call, ok, result, code, message }) {
    const waiting = this.#calls.get(call)
    if (waiting === undefined) return
    this.#calls.delete(call)
    if (ok) waiting.resolve(JSON.parse(result))
    else waiting.reject(Object.assign(new Error(message), { code }))
  }
}
