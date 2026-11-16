// A Relay Server for the tests: the wasm RelayCore, the rules the real one runs, behind a
// `ws` server on a free local port.
import { WebSocketServer } from 'ws'
import { LINK_PATH, RelayCore } from '../../link.js'

const TICK_MS = 100

/** options: the RelayCore's, for example `{graceMs}`. */
export async function startRelay(options = {}) {
  const core = new RelayCore(options, undefined, Date.now())
  const sockets = new Map()
  let nextConn = 1

  const act = (action) => {
    const socket = sockets.get(action.conn)
    if (socket === undefined) return
    if (action.type === 'sendText') socket.send(action.text)
    else if (action.type === 'sendBinary') socket.send(action.data)
    else if (action.type === 'ping') socket.ping()
    else if (action.type === 'close') {
      sockets.delete(action.conn)
      socket.close(action.code, action.reason)
    }
  }
  const run = (fn) => {
    fn(core, Date.now())
    for (let action = core.pollAction(); action !== undefined; action = core.pollAction()) act(action)
  }

  const server = new WebSocketServer({
    host: '127.0.0.1',
    port: 0,
    path: LINK_PATH,
    maxPayload: 1024 * 1024,
    // The count of an address's sockets ends with the TCP socket, upgraded or not.
    verifyClient: ({ req }, done) => {
      const address = req.socket.remoteAddress ?? ''
      const refused = core.admitSocket(address)
      if (refused !== undefined) return done(false, refused)
      req.socket.once('close', () => core.releaseSocket(address))
      done(true)
    },
  })
  server.on('connection', (socket, req) => {
    const conn = nextConn++
    sockets.set(conn, socket)
    run((relay, now) => relay.socketOpened(conn, req.socket.remoteAddress ?? '', now))
    socket.on('message', (data, binary) => run((relay, now) => (binary
      ? relay.socketBinary(conn, data, now)
      : relay.socketText(conn, data.toString('utf8'), now))))
    socket.on('pong', () => run((relay, now) => relay.socketPong(conn, now)))
    socket.on('close', () => {
      if (sockets.delete(conn)) run((relay, now) => relay.socketClosed(conn, now))
    })
    socket.on('error', () => {})
  })
  await new Promise(resolve => server.once('listening', resolve))
  const ticker = setInterval(() => run((relay, now) => relay.tick(now)), TICK_MS)
  ticker.unref()

  return {
    url: `ws://127.0.0.1:${server.address().port}${LINK_PATH}`,
    core,
    close: async () => {
      clearInterval(ticker)
      for (const socket of server.clients) socket.terminate()
      await new Promise(resolve => server.close(resolve))
    },
  }
}
