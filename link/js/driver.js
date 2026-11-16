// Runs a core from the wasm. The core decides everything and does no IO; this hands it
// socket events and the time, carries out the actions it returns, and wakes it at its
// next deadline.
const ignore = () => {}

export class Driver {
  #core
  #onAction
  #createSocket
  #sockets = new Map()
  #timer

  /** `onAction` gets every action that is not about a socket. */
  constructor(core, onAction, createSocket = url => new WebSocket(url)) {
    this.#core = core
    this.#onAction = onAction
    this.#createSocket = createSocket
  }

  /** Calls `fn(core, now)`, then carries out what the core asks. Returns what `fn` returns. */
  run(fn) {
    try {
      return fn(this.#core, Date.now())
    } finally {
      for (let action = this.#core.pollAction(); action !== undefined; action = this.#core.pollAction()) this.#act(action)
      this.#arm()
    }
  }

  /** Stops the timer and lets go of every socket. */
  halt() {
    clearTimeout(this.#timer)
    for (const id of this.#sockets.keys()) this.#close(id)
  }

  #act(action) {
    switch (action.type) {
      case 'connect': return this.#connect(action.socket, action.url)
      case 'sendText': return this.#send(action.socket, action.text)
      case 'sendBinary': return this.#send(action.socket, action.data)
      case 'closeSocket': return this.#close(action.socket)
      default: return this.#onAction(action)
    }
  }

  #arm() {
    clearTimeout(this.#timer)
    const at = this.#core.nextDeadline()
    if (at === undefined) return
    this.#timer = setTimeout(() => this.run((core, now) => core.tick(now)), Math.max(0, at - Date.now()))
    this.#timer.unref?.()
  }

  #connect(id, url) {
    let socket
    try {
      socket = this.#createSocket(url)
    } catch (error) {
      queueMicrotask(() => this.run((core, now) => core.socketClosed(id, messageOf(error), now)))
      return
    }
    socket.binaryType = 'arraybuffer'
    this.#sockets.set(id, socket)
    let opened = false
    socket.onopen = () => {
      opened = true
      this.run((core, now) => core.socketOpened(id, now))
    }
    socket.onmessage = ({ data }) => this.run((core, now) => (typeof data === 'string'
      ? core.socketText(id, data, now)
      : core.socketBinary(id, new Uint8Array(data), now)))
    socket.onerror = () => this.#lost(id, opened ? 'The connection to the Server failed.' : 'The Server did not answer the connection.')
    socket.onclose = ({ reason }) => this.#lost(id, reason || 'The Server closed the connection.')
  }

  #send(id, data) {
    try {
      this.#sockets.get(id)?.send(data)
    } catch (error) {
      this.#lost(id, messageOf(error))
    }
  }

  #lost(id, reason) {
    if (!this.#sockets.has(id)) return
    this.#close(id)
    this.run((core, now) => core.socketClosed(id, reason, now))
  }

  // The core has already counted the socket gone, so its own close event, which can take
  // minutes on a dead network, is not waited for. A late error from it is swallowed: an
  // EventEmitter socket would throw one that has no listener.
  #close(id) {
    const socket = this.#sockets.get(id)
    if (socket === undefined) return
    this.#sockets.delete(id)
    socket.onopen = socket.onmessage = socket.onclose = null
    socket.onerror = ignore
    try { socket.close() } catch { /* already closing */ }
  }
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}
