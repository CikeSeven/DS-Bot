import { Driver } from './driver.js'
import { HostCore } from './wasm.js'

/**
 * The computer's end of the link: one socket to the Relay Server, a link per phone, and
 * the phones' calls handed to `options.handle`. It runs a call once and never repeats one.
 *
 * options: `{url, identity, accessToken, name?, admits(deviceId, key), authorize(deviceId,
 * key, hello) (may return a Promise), handle(method, params, {deviceId, signal}),
 * createSocket?, maxTunnels?, onStatus?, onReadyCount?}`
 */
export class HostLink {
  #options
  #core
  #driver
  #calls = new Map()
  #waiters = new Set()

  constructor(options) {
    this.#options = options
    this.#core = new HostCore({
      server: options.url,
      identity: options.identity,
      accessToken: options.accessToken,
      name: options.name,
      maxLinks: options.maxTunnels,
    }, Date.now())
    this.#driver = new Driver(this.#core, action => this.#act(action), options.createSocket)
  }

  /** 'stopped' | 'connecting' | 'online' | 'offline' */
  get status() { return this.#core.status() }

  /** Why the last socket ended, for surfaces that show 'offline'. */
  get error() { return this.#core.error() }

  start() {
    this.#driver.run((core, now) => core.start(now))
  }

  async stop() {
    this.#driver.run((core, now) => core.stop(now))
    this.#driver.halt()
  }

  async waitOnline(timeoutMs = 10_000) {
    const deadline = Date.now() + timeoutMs
    while (this.status !== 'online') {
      const left = deadline - Date.now()
      if (left <= 0) throw new Error('The computer did not reach the Server in time.')
      await new Promise(resolve => {
        const done = () => { clearTimeout(timer); this.#waiters.delete(done); resolve() }
        const timer = setTimeout(done, left)
        this.#waiters.add(done)
      })
    }
  }

  /** Phones with a finished handshake that are on the Server now. */
  connectedDevices() {
    return this.#core.connectedDevices()
  }

  /** Ends every link of a device, for example when the user removes it. */
  disconnect(deviceId) {
    this.#driver.run((core, now) => core.disconnect(deviceId, now))
  }

  /** Tells every phone with a link that something changed; a phone away for now hears it when back. */
  emit(event, data) {
    const json = JSON.stringify(data ?? null)
    this.#driver.run((core, now) => core.emit(event, json, now))
  }

  #act(action) {
    switch (action.type) {
      case 'status': return this.#status(action.status)
      case 'authorize': return void this.#authorize(action)
      case 'request': return void this.#serve(action)
      case 'cancel': return this.#cancel(action)
      case 'readyCount': return this.#options.onReadyCount?.(action.count)
    }
  }

  #status(status) {
    for (const waiter of this.#waiters) waiter()
    this.#options.onStatus?.(status)
  }

  async #authorize({ link, deviceId, identityKey, name, pairingCode }) {
    const hello = { ...(name === undefined ? {} : { name }), ...(pairingCode === undefined ? {} : { pairingCode }) }
    let allowed = false
    try {
      allowed = Boolean(this.#options.admits(deviceId, identityKey) && await this.#options.authorize(deviceId, identityKey, hello))
    } catch { /* a check that fails refuses */ }
    this.#driver.run((core, now) => core.authorize(link, allowed, now))
  }

  async #serve({ link, request, deviceId, method, params }) {
    const key = `${link} ${request}`
    const controller = new AbortController()
    this.#calls.set(key, controller)
    let answer
    try {
      const result = await this.#options.handle(method, JSON.parse(params), { deviceId, signal: controller.signal })
      const json = JSON.stringify(result ?? null) ?? 'null'
      answer = (core, now) => core.respond(link, request, json, now)
    } catch (error) {
      const code = typeof error?.code === 'string' ? error.code : 'HOST_ERROR'
      const message = error instanceof Error ? error.message : String(error)
      answer = (core, now) => core.respondError(link, request, code, message, now)
    }
    if (this.#calls.get(key) !== controller) return
    this.#calls.delete(key)
    this.#driver.run(answer)
  }

  #cancel({ link, request }) {
    const key = `${link} ${request}`
    this.#calls.get(key)?.abort(new Error('The phone link closed.'))
    this.#calls.delete(key)
  }
}
