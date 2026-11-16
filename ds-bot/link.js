// Generated from ../link by `npm run build` (scripts/build-link.mjs). Do not edit by hand.
// source-hash: 08bdcca833b39937095beb6e951915762c725762e8942adeff2d6eaa5dfade08
// js/wasm.js
import { readFileSync } from "node:fs";

// wasm-bindgen:dsbot-link-wasm
var ClientCore = class {
  __destroy_into_raw() {
    const ptr = this.__wbg_ptr;
    this.__wbg_ptr = 0;
    ClientCoreFinalization.unregister(this);
    return ptr;
  }
  free() {
    const ptr = this.__destroy_into_raw();
    wasm.__wbg_clientcore_free(ptr, 0);
  }
  /**
   * @param {number} now
   */
  close(now) {
    wasm.clientcore_close(this.__wbg_ptr, now);
  }
  /**
   * @returns {string | undefined}
   */
  hostName() {
    const ret = wasm.clientcore_hostName(this.__wbg_ptr);
    let v1;
    if (ret[0] !== 0) {
      v1 = getStringFromWasm0(ret[0], ret[1]);
      wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
    }
    return v1;
  }
  /**
   * @param {number} now
   */
  networkChanged(now) {
    wasm.clientcore_networkChanged(this.__wbg_ptr, now);
  }
  /**
   * `options`: `{server, identity: {deviceId?, publicKey, privateKey}, accessToken, hostDeviceId, hostKey, name?, pairingCode?}`.
   * @param {any} options
   * @param {number} now
   */
  constructor(options, now) {
    const ret = wasm.clientcore_new(options, now);
    if (ret[2]) {
      throw takeFromExternrefTable0(ret[1]);
    }
    this.__wbg_ptr = ret[0];
    ClientCoreFinalization.register(this, this.__wbg_ptr, this);
    return this;
  }
  /**
   * @returns {number | undefined}
   */
  nextDeadline() {
    const ret = wasm.clientcore_nextDeadline(this.__wbg_ptr);
    return ret[0] === 0 ? void 0 : ret[1];
  }
  /**
   * The next action, or `undefined`.
   * @returns {any}
   */
  pollAction() {
    const ret = wasm.clientcore_pollAction(this.__wbg_ptr);
    return ret;
  }
  /**
   * Sends a call with JSON `params`; returns the id its `rpcDone` action carries.
   * A `timeoutMs` of 0 means the default.
   * @param {string} method
   * @param {string} params
   * @param {number} timeout_ms
   * @param {number} now
   * @returns {number}
   */
  rpc(method, params, timeout_ms, now) {
    const val3 = +timeout_ms;
    const val4 = +now;
    let ptr0, len0, ptr1, len1;
    try {
      ptr0 = passStringToWasm0(method, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(params, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    const ret = wasm.clientcore_rpc(this.__wbg_ptr, ptr0, len0, ptr1, len1, val3, val4);
    return ret;
  }
  /**
   * @param {boolean} foreground
   * @param {number} now
   */
  setForeground(foreground, now) {
    wasm.clientcore_setForeground(this.__wbg_ptr, foreground, now);
  }
  /**
   * @param {number} socket
   * @param {Uint8Array | number[]} data
   * @param {number} now
   */
  socketBinary(socket, data, now) {
    const val2 = +socket;
    const val3 = +now;
    const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.clientcore_socketBinary(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} socket
   * @param {string | null | undefined} reason
   * @param {number} now
   */
  socketClosed(socket, reason, now) {
    const val2 = +socket;
    const val3 = +now;
    var ptr0 = isLikeNone(reason) ? 0 : passStringToWasm0(reason, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    var len0 = WASM_VECTOR_LEN;
    wasm.clientcore_socketClosed(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} socket
   * @param {number} now
   */
  socketOpened(socket, now) {
    wasm.clientcore_socketOpened(this.__wbg_ptr, socket, now);
  }
  /**
   * @param {number} socket
   * @param {string} text
   * @param {number} now
   */
  socketText(socket, text, now) {
    const val2 = +socket;
    const val3 = +now;
    const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.clientcore_socketText(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} now
   */
  start(now) {
    wasm.clientcore_start(this.__wbg_ptr, now);
  }
  /**
   * The status as the `status` action carries it, or `undefined` before `start`.
   * @returns {any}
   */
  status() {
    const ret = wasm.clientcore_status(this.__wbg_ptr);
    return ret;
  }
  /**
   * @param {number} now
   */
  tick(now) {
    wasm.clientcore_tick(this.__wbg_ptr, now);
  }
};
if (Symbol.dispose) ClientCore.prototype[Symbol.dispose] = ClientCore.prototype.free;
var DeviceRegistry = class {
  __destroy_into_raw() {
    const ptr = this.__wbg_ptr;
    this.__wbg_ptr = 0;
    DeviceRegistryFinalization.unregister(this);
    return ptr;
  }
  free() {
    const ptr = this.__destroy_into_raw();
    wasm.__wbg_deviceregistry_free(ptr, 0);
  }
  /**
   * @param {string} device_id
   * @param {string} identity_key
   * @param {number} now
   * @returns {boolean}
   */
  admits(device_id, identity_key, now) {
    const val3 = +now;
    let ptr0, len0, ptr1, len1;
    try {
      ptr0 = passStringToWasm0(device_id, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(identity_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    const ret = wasm.deviceregistry_admits(this.__wbg_ptr, ptr0, len0, ptr1, len1, val3);
    return ret !== 0;
  }
  /**
   * Returns `{allowed, changed}`; `changed` means the list is to be saved.
   * @param {string} device_id
   * @param {string} identity_key
   * @param {string | null | undefined} name
   * @param {string | null | undefined} pairing_code
   * @param {number} now
   * @returns {any}
   */
  authorize(device_id, identity_key, name, pairing_code, now) {
    const val5 = +now;
    let ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3;
    try {
      ptr0 = passStringToWasm0(device_id, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(identity_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
      ptr2 = isLikeNone(name) ? 0 : passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len2 = WASM_VECTOR_LEN;
      ptr3 = isLikeNone(pairing_code) ? 0 : passStringToWasm0(pairing_code, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len3 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr3) {
        wasm.__wbindgen_free(ptr3, len3 * 1, 1);
      }
      if (ptr2) {
        wasm.__wbindgen_free(ptr2, len2 * 1, 1);
      }
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    const ret = wasm.deviceregistry_authorize(this.__wbg_ptr, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, val5);
    return ret;
  }
  closePairing() {
    wasm.deviceregistry_closePairing(this.__wbg_ptr);
  }
  /**
   * @returns {any}
   */
  list() {
    const ret = wasm.deviceregistry_list(this.__wbg_ptr);
    if (ret[2]) {
      throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
  }
  /**
   * Entries that are not paired devices are skipped, so a damaged file loses only them.
   * @param {any} devices
   */
  constructor(devices) {
    const ret = wasm.deviceregistry_new(devices);
    this.__wbg_ptr = ret;
    DeviceRegistryFinalization.register(this, this.__wbg_ptr, this);
    return this;
  }
  /**
   * @param {number} ttl_ms
   * @param {number} now
   * @returns {any}
   */
  openPairing(ttl_ms, now) {
    const ret = wasm.deviceregistry_openPairing(this.__wbg_ptr, ttl_ms, now);
    return ret;
  }
  /**
   * @param {number} now
   * @returns {boolean}
   */
  pairingOpen(now) {
    const ret = wasm.deviceregistry_pairingOpen(this.__wbg_ptr, now);
    return ret !== 0;
  }
  /**
   * @param {string} device_id
   * @returns {boolean}
   */
  revoke(device_id) {
    const ptr0 = passStringToWasm0(device_id, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.deviceregistry_revoke(this.__wbg_ptr, ptr0, len0);
    return ret !== 0;
  }
};
if (Symbol.dispose) DeviceRegistry.prototype[Symbol.dispose] = DeviceRegistry.prototype.free;
var HostCore = class {
  __destroy_into_raw() {
    const ptr = this.__wbg_ptr;
    this.__wbg_ptr = 0;
    HostCoreFinalization.unregister(this);
    return ptr;
  }
  free() {
    const ptr = this.__destroy_into_raw();
    wasm.__wbg_hostcore_free(ptr, 0);
  }
  /**
   * @param {string} link
   * @param {boolean} allowed
   * @param {number} now
   */
  authorize(link, allowed, now) {
    const val2 = +allowed;
    const val3 = +now;
    const ptr0 = passStringToWasm0(link, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.hostcore_authorize(this.__wbg_ptr, ptr0, len0, val2, val3);
  }
  /**
   * @returns {string[]}
   */
  connectedDevices() {
    const ret = wasm.hostcore_connectedDevices(this.__wbg_ptr);
    var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]);
    wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
    return v1;
  }
  /**
   * @param {string} device_id
   * @param {number} now
   */
  disconnect(device_id, now) {
    const val2 = +now;
    const ptr0 = passStringToWasm0(device_id, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.hostcore_disconnect(this.__wbg_ptr, ptr0, len0, val2);
  }
  /**
   * `data` is JSON.
   * @param {string} event
   * @param {string} data
   * @param {number} now
   */
  emit(event, data, now) {
    const val3 = +now;
    let ptr0, len0, ptr1, len1;
    try {
      ptr0 = passStringToWasm0(event, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(data, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    wasm.hostcore_emit(this.__wbg_ptr, ptr0, len0, ptr1, len1, val3);
  }
  /**
   * @returns {string | undefined}
   */
  error() {
    const ret = wasm.hostcore_error(this.__wbg_ptr);
    let v1;
    if (ret[0] !== 0) {
      v1 = getStringFromWasm0(ret[0], ret[1]);
      wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
    }
    return v1;
  }
  /**
   * `options`: `{server, identity: {deviceId?, publicKey, privateKey}, accessToken, name?, maxLinks?}`.
   * @param {any} options
   * @param {number} now
   */
  constructor(options, now) {
    const ret = wasm.hostcore_new(options, now);
    if (ret[2]) {
      throw takeFromExternrefTable0(ret[1]);
    }
    this.__wbg_ptr = ret[0];
    HostCoreFinalization.register(this, this.__wbg_ptr, this);
    return this;
  }
  /**
   * @returns {number | undefined}
   */
  nextDeadline() {
    const ret = wasm.hostcore_nextDeadline(this.__wbg_ptr);
    return ret[0] === 0 ? void 0 : ret[1];
  }
  /**
   * The next action, or `undefined`.
   * @returns {any}
   */
  pollAction() {
    const ret = wasm.hostcore_pollAction(this.__wbg_ptr);
    return ret;
  }
  /**
   * @param {string} link
   * @param {string} request
   * @param {string} code
   * @param {string} message
   * @param {number} now
   */
  respondError(link, request, code, message, now) {
    const val5 = +now;
    let ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3;
    try {
      ptr0 = passStringToWasm0(link, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(request, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
      ptr2 = passStringToWasm0(code, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len2 = WASM_VECTOR_LEN;
      ptr3 = passStringToWasm0(message, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len3 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr3) {
        wasm.__wbindgen_free(ptr3, len3 * 1, 1);
      }
      if (ptr2) {
        wasm.__wbindgen_free(ptr2, len2 * 1, 1);
      }
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    wasm.hostcore_respondError(this.__wbg_ptr, ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, val5);
  }
  /**
   * `result` is the call's answer as JSON.
   * @param {string} link
   * @param {string} request
   * @param {string} result
   * @param {number} now
   */
  respond(link, request, result, now) {
    const val4 = +now;
    let ptr0, len0, ptr1, len1, ptr2, len2;
    try {
      ptr0 = passStringToWasm0(link, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len0 = WASM_VECTOR_LEN;
      ptr1 = passStringToWasm0(request, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len1 = WASM_VECTOR_LEN;
      ptr2 = passStringToWasm0(result, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      len2 = WASM_VECTOR_LEN;
    } catch (e) {
      if (ptr2) {
        wasm.__wbindgen_free(ptr2, len2 * 1, 1);
      }
      if (ptr1) {
        wasm.__wbindgen_free(ptr1, len1 * 1, 1);
      }
      if (ptr0) {
        wasm.__wbindgen_free(ptr0, len0 * 1, 1);
      }
      throw e;
    }
    wasm.hostcore_respond(this.__wbg_ptr, ptr0, len0, ptr1, len1, ptr2, len2, val4);
  }
  /**
   * @param {number} socket
   * @param {Uint8Array | number[]} data
   * @param {number} now
   */
  socketBinary(socket, data, now) {
    const val2 = +socket;
    const val3 = +now;
    const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.hostcore_socketBinary(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} socket
   * @param {string | null | undefined} reason
   * @param {number} now
   */
  socketClosed(socket, reason, now) {
    const val2 = +socket;
    const val3 = +now;
    var ptr0 = isLikeNone(reason) ? 0 : passStringToWasm0(reason, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    var len0 = WASM_VECTOR_LEN;
    wasm.hostcore_socketClosed(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} socket
   * @param {number} now
   */
  socketOpened(socket, now) {
    wasm.hostcore_socketOpened(this.__wbg_ptr, socket, now);
  }
  /**
   * @param {number} socket
   * @param {string} text
   * @param {number} now
   */
  socketText(socket, text, now) {
    const val2 = +socket;
    const val3 = +now;
    const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.hostcore_socketText(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} now
   */
  start(now) {
    wasm.hostcore_start(this.__wbg_ptr, now);
  }
  /**
   * `'stopped' | 'connecting' | 'online' | 'offline'`.
   * @returns {string}
   */
  status() {
    let deferred1_0;
    let deferred1_1;
    try {
      const ret = wasm.hostcore_status(this.__wbg_ptr);
      deferred1_0 = ret[0];
      deferred1_1 = ret[1];
      return getStringFromWasm0(ret[0], ret[1]);
    } finally {
      wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
    }
  }
  /**
   * @param {number} now
   */
  stop(now) {
    wasm.hostcore_stop(this.__wbg_ptr, now);
  }
  /**
   * @param {number} now
   */
  tick(now) {
    wasm.hostcore_tick(this.__wbg_ptr, now);
  }
};
if (Symbol.dispose) HostCore.prototype[Symbol.dispose] = HostCore.prototype.free;
var RelayCore = class {
  __destroy_into_raw() {
    const ptr = this.__wbg_ptr;
    this.__wbg_ptr = 0;
    RelayCoreFinalization.unregister(this);
    return ptr;
  }
  free() {
    const ptr = this.__destroy_into_raw();
    wasm.__wbg_relaycore_free(ptr, 0);
  }
  /**
   * Before the WebSocket upgrade: `undefined` to go on, else the HTTP status to refuse with.
   * @param {string} address
   * @returns {number | undefined}
   */
  admitSocket(address) {
    const ptr0 = passStringToWasm0(address, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.relaycore_admitSocket(this.__wbg_ptr, ptr0, len0);
    return ret === 16777215 ? void 0 : ret;
  }
  /**
   * The device table as JSON, to save.
   * @returns {string}
   */
  devices() {
    let deferred1_0;
    let deferred1_1;
    try {
      const ret = wasm.relaycore_devices(this.__wbg_ptr);
      deferred1_0 = ret[0];
      deferred1_1 = ret[1];
      return getStringFromWasm0(ret[0], ret[1]);
    } finally {
      wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
    }
  }
  /**
   * @returns {number}
   */
  linkCount() {
    const ret = wasm.relaycore_linkCount(this.__wbg_ptr);
    return ret;
  }
  /**
   * `options`: `{graceMs?, maxSockets?, maxLinks?, maxSocketsPerAddress?, maxNewDevicesPerHour?}`;
   * `devices` is the device table's JSON, if there is one.
   * @param {any} options
   * @param {string | null | undefined} devices
   * @param {number} now
   */
  constructor(options, devices, now) {
    const val2 = +now;
    var ptr0 = isLikeNone(devices) ? 0 : passStringToWasm0(devices, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    var len0 = WASM_VECTOR_LEN;
    const ret = wasm.relaycore_new(options, ptr0, len0, val2);
    if (ret[2]) {
      throw takeFromExternrefTable0(ret[1]);
    }
    this.__wbg_ptr = ret[0];
    RelayCoreFinalization.register(this, this.__wbg_ptr, this);
    return this;
  }
  /**
   * The next action, or `undefined`.
   * @returns {any}
   */
  pollAction() {
    const ret = wasm.relaycore_pollAction(this.__wbg_ptr);
    return ret;
  }
  /**
   * The TCP socket of an admitted address ended, upgraded or not.
   * @param {string} address
   */
  releaseSocket(address) {
    const ptr0 = passStringToWasm0(address, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.relaycore_releaseSocket(this.__wbg_ptr, ptr0, len0);
  }
  /**
   * @param {number} conn
   * @param {Uint8Array | number[]} data
   * @param {number} now
   */
  socketBinary(conn, data, now) {
    const val2 = +conn;
    const val3 = +now;
    const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.relaycore_socketBinary(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} conn
   * @param {number} now
   */
  socketClosed(conn, now) {
    wasm.relaycore_socketClosed(this.__wbg_ptr, conn, now);
  }
  /**
   * @param {number} conn
   * @param {string} address
   * @param {number} now
   */
  socketOpened(conn, address, now) {
    const val2 = +conn;
    const val3 = +now;
    const ptr0 = passStringToWasm0(address, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.relaycore_socketOpened(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} conn
   * @param {number} now
   */
  socketPong(conn, now) {
    wasm.relaycore_socketPong(this.__wbg_ptr, conn, now);
  }
  /**
   * @param {number} conn
   * @param {string} text
   * @param {number} now
   */
  socketText(conn, text, now) {
    const val2 = +conn;
    const val3 = +now;
    const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    wasm.relaycore_socketText(this.__wbg_ptr, val2, ptr0, len0, val3);
  }
  /**
   * @param {number} now
   */
  tick(now) {
    wasm.relaycore_tick(this.__wbg_ptr, now);
  }
};
if (Symbol.dispose) RelayCore.prototype[Symbol.dispose] = RelayCore.prototype.free;
function deviceIdFor(public_key) {
  let deferred3_0;
  let deferred3_1;
  try {
    const ptr0 = passStringToWasm0(public_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.deviceIdFor(ptr0, len0);
    var ptr2 = ret[0];
    var len2 = ret[1];
    if (ret[3]) {
      ptr2 = 0;
      len2 = 0;
      throw takeFromExternrefTable0(ret[2]);
    }
    deferred3_0 = ptr2;
    deferred3_1 = len2;
    return getStringFromWasm0(ptr2, len2);
  } finally {
    wasm.__wbindgen_free(deferred3_0, deferred3_1, 1);
  }
}
function generateKeyPair(private_key) {
  var ptr0 = isLikeNone(private_key) ? 0 : passArray8ToWasm0(private_key, wasm.__wbindgen_malloc);
  var len0 = WASM_VECTOR_LEN;
  const ret = wasm.generateKeyPair(ptr0, len0);
  if (ret[2]) {
    throw takeFromExternrefTable0(ret[1]);
  }
  return takeFromExternrefTable0(ret[0]);
}
function identityFingerprint(public_key) {
  let deferred3_0;
  let deferred3_1;
  try {
    const ptr0 = passStringToWasm0(public_key, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.identityFingerprint(ptr0, len0);
    var ptr2 = ret[0];
    var len2 = ret[1];
    if (ret[3]) {
      ptr2 = 0;
      len2 = 0;
      throw takeFromExternrefTable0(ret[2]);
    }
    deferred3_0 = ptr2;
    deferred3_1 = len2;
    return getStringFromWasm0(ptr2, len2);
  } finally {
    wasm.__wbindgen_free(deferred3_0, deferred3_1, 1);
  }
}
function linkPath() {
  let deferred1_0;
  let deferred1_1;
  try {
    const ret = wasm.linkPath();
    deferred1_0 = ret[0];
    deferred1_1 = ret[1];
    return getStringFromWasm0(ret[0], ret[1]);
  } finally {
    wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
  }
}
function pairingUri(offer) {
  let deferred2_0;
  let deferred2_1;
  try {
    const ret = wasm.pairingUri(offer);
    var ptr1 = ret[0];
    var len1 = ret[1];
    if (ret[3]) {
      ptr1 = 0;
      len1 = 0;
      throw takeFromExternrefTable0(ret[2]);
    }
    deferred2_0 = ptr1;
    deferred2_1 = len1;
    return getStringFromWasm0(ptr1, len1);
  } finally {
    wasm.__wbindgen_free(deferred2_0, deferred2_1, 1);
  }
}
function parsePairingUri(uri) {
  const ptr0 = passStringToWasm0(uri, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
  const len0 = WASM_VECTOR_LEN;
  const ret = wasm.parsePairingUri(ptr0, len0);
  if (ret[2]) {
    throw takeFromExternrefTable0(ret[1]);
  }
  return takeFromExternrefTable0(ret[0]);
}
function randomToken(bytes) {
  let deferred1_0;
  let deferred1_1;
  try {
    const ret = wasm.randomToken(isLikeNone(bytes) ? Number.MAX_SAFE_INTEGER : bytes >>> 0);
    deferred1_0 = ret[0];
    deferred1_1 = ret[1];
    return getStringFromWasm0(ret[0], ret[1]);
  } finally {
    wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
  }
}
function __wbg_get_imports() {
  const import0 = {
    __proto__: null,
    __wbg___wbindgen_debug_string_f249a2a76caa9a55: function(arg0, arg1) {
      const ret = debugString(arg1);
      const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      const len1 = WASM_VECTOR_LEN;
      getDataViewMemory0().setInt32((arg0 >>> 0) + 4 * 1, len1, true);
      getDataViewMemory0().setInt32((arg0 >>> 0) + 4 * 0, ptr1, true);
    },
    __wbg___wbindgen_is_null_c22311b1cc228e3a: function(arg0) {
      const ret = arg0 === null;
      return ret;
    },
    __wbg___wbindgen_is_undefined_be5b34249ff1fc15: function(arg0) {
      const ret = arg0 === void 0;
      return ret;
    },
    __wbg___wbindgen_string_get_7ce8eee7fd327545: function(arg0, arg1) {
      const obj = arg1;
      const ret = typeof obj === "string" ? obj : void 0;
      var ptr1 = isLikeNone(ret) ? 0 : passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
      var len1 = WASM_VECTOR_LEN;
      getDataViewMemory0().setInt32((arg0 >>> 0) + 4 * 1, len1, true);
      getDataViewMemory0().setInt32((arg0 >>> 0) + 4 * 0, ptr1, true);
    },
    __wbg___wbindgen_throw_4c88d8bf264fd984: function(arg0, arg1) {
      throw new Error(getStringFromWasm0(arg0, arg1));
    },
    __wbg_getRandomValues_5d8c030b527203a6: function() {
      return handleError(function(arg0, arg1) {
        globalThis.crypto.getRandomValues(getArrayU8FromWasm0(arg0, arg1));
      }, arguments);
    },
    __wbg_new_787b9fb330d55d78: function(arg0, arg1) {
      const ret = new Error(getStringFromWasm0(arg0, arg1));
      return ret;
    },
    __wbg_new_cd4348290afae586: function() {
      const ret = new Object();
      return ret;
    },
    __wbg_new_from_slice_b8daf545a41c6aa0: function(arg0, arg1) {
      const ret = new Uint8Array(getArrayU8FromWasm0(arg0, arg1));
      return ret;
    },
    __wbg_parse_c3f72b5a24f83c01: function() {
      return handleError(function(arg0, arg1) {
        const ret = JSON.parse(getStringFromWasm0(arg0, arg1));
        return ret;
      }, arguments);
    },
    __wbg_set_2793479888329cb6: function() {
      return handleError(function(arg0, arg1, arg2) {
        const ret = Reflect.set(arg0, arg1, arg2);
        return ret;
      }, arguments);
    },
    __wbg_stringify_0a0fbf2ef722380a: function() {
      return handleError(function(arg0) {
        const ret = JSON.stringify(arg0);
        return ret;
      }, arguments);
    },
    __wbindgen_generic_0000000000000001: function(arg0) {
      const ret = arg0;
      return ret;
    },
    __wbindgen_generic_0000000000000002: function(arg0, arg1) {
      const ret = getStringFromWasm0(arg0, arg1);
      return ret;
    },
    __wbindgen_init_externref_table: function() {
      const table = wasm.__wbindgen_externrefs;
      table.set(0, void 0);
      table.set(1024, void 0);
      table.set(1025, null);
      table.set(1026, true);
      table.set(1027, false);
    }
  };
  return {
    __proto__: null,
    "./dsbot_link_wasm_bg.js": import0
  };
}
var ClientCoreFinalization = typeof FinalizationRegistry === "undefined" ? { register: () => {
}, unregister: () => {
} } : new FinalizationRegistry((ptr) => wasm.__wbg_clientcore_free(ptr, 1));
var DeviceRegistryFinalization = typeof FinalizationRegistry === "undefined" ? { register: () => {
}, unregister: () => {
} } : new FinalizationRegistry((ptr) => wasm.__wbg_deviceregistry_free(ptr, 1));
var HostCoreFinalization = typeof FinalizationRegistry === "undefined" ? { register: () => {
}, unregister: () => {
} } : new FinalizationRegistry((ptr) => wasm.__wbg_hostcore_free(ptr, 1));
var RelayCoreFinalization = typeof FinalizationRegistry === "undefined" ? { register: () => {
}, unregister: () => {
} } : new FinalizationRegistry((ptr) => wasm.__wbg_relaycore_free(ptr, 1));
function addToExternrefTable0(obj) {
  const idx = wasm.__externref_table_alloc();
  wasm.__wbindgen_externrefs.set(idx, obj);
  return idx;
}
function debugString(val) {
  switch (typeof val) {
    // primitive types
    case "number":
    case "boolean":
    case "undefined":
      return `${val}`;
    case "string":
      return JSON.stringify(val);
    case "bigint":
      return `${val}n`;
    case "symbol":
      return val.description !== void 0 ? `Symbol(${val.description})` : "Symbol";
    case "function":
      return typeof val.name === "string" && val.name !== "" ? `Function(${val.name})` : "Function";
    case "object": {
      if (val === null) {
        return "null";
      }
      if (Array.isArray(val)) {
        return "[" + Array.from(val, debugString).join(", ") + "]";
      }
      if (val instanceof Error) {
        return `${val.name}: ${val.message}
${val.stack}`;
      }
      const toStringOutput = toString.call(val);
      const className = /\[object ([^\]]+)\]/.exec(toStringOutput)?.[1];
      if (className === void 0) {
        return toStringOutput;
      }
      if (className === "Object") {
        try {
          return "Object(" + JSON.stringify(val) + ")";
        } catch (_) {
          return "Object";
        }
      }
      return className;
    }
  }
}
function getArrayJsValueFromWasm0(ptr, len) {
  ptr = ptr >>> 0;
  const mem = getDataViewMemory0();
  const result = [];
  for (let i = ptr; i < ptr + 4 * len; i += 4) {
    result.push(wasm.__wbindgen_externrefs.get(mem.getUint32(i, true)));
  }
  wasm.__externref_drop_slice(ptr, len);
  return result;
}
function getArrayU8FromWasm0(ptr, len) {
  ptr = ptr >>> 0;
  return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}
var cachedDataViewMemory0 = null;
function getDataViewMemory0() {
  if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || cachedDataViewMemory0.buffer.detached === void 0 && cachedDataViewMemory0.buffer !== wasm.memory.buffer) {
    cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
  }
  return cachedDataViewMemory0;
}
function getStringFromWasm0(ptr, len) {
  ptr = ptr >>> 0;
  return decodeText(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}
var cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
  if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
    cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
  }
  return cachedUint8ArrayMemory0;
}
function handleError(f, args) {
  try {
    return f.apply(this, args);
  } catch (e) {
    const idx = addToExternrefTable0(e);
    wasm.__wbindgen_exn_store(idx);
  }
}
function isLikeNone(x) {
  return x === void 0 || x === null;
}
function passArray8ToWasm0(arg, malloc) {
  const ptr = malloc(arg.length * 1, 1) >>> 0;
  getUint8ArrayMemory0().set(arg, ptr / 1);
  WASM_VECTOR_LEN = arg.length;
  return ptr;
}
function passStringToWasm0(arg, malloc, realloc) {
  if (realloc === void 0) {
    const buf = cachedTextEncoder.encode(arg);
    const ptr2 = malloc(buf.length, 1) >>> 0;
    getUint8ArrayMemory0().subarray(ptr2, ptr2 + buf.length).set(buf);
    WASM_VECTOR_LEN = buf.length;
    return ptr2;
  }
  let len = arg.length;
  let ptr = malloc(len, 1) >>> 0;
  const mem = getUint8ArrayMemory0();
  let offset = 0;
  for (; offset < len; offset++) {
    const code = arg.charCodeAt(offset);
    if (code > 127) break;
    mem[ptr + offset] = code;
  }
  if (offset !== len) {
    if (offset !== 0) {
      arg = arg.slice(offset);
    }
    ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
    const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
    const ret = cachedTextEncoder.encodeInto(arg, view);
    offset += ret.written;
    ptr = realloc(ptr, len, offset, 1) >>> 0;
  }
  WASM_VECTOR_LEN = offset;
  return ptr;
}
function takeFromExternrefTable0(idx) {
  const value = wasm.__wbindgen_externrefs.get(idx);
  wasm.__externref_table_dealloc(idx);
  return value;
}
var cachedTextDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
cachedTextDecoder.decode();
var MAX_SAFARI_DECODE_BYTES = 2146435072;
var numBytesDecoded = 0;
function decodeText(bytes) {
  numBytesDecoded += bytes.length;
  if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
    cachedTextDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
    cachedTextDecoder.decode();
    numBytesDecoded = bytes.length;
  }
  return cachedTextDecoder.decode(bytes);
}
var cachedTextEncoder = new TextEncoder();
if (!("encodeInto" in cachedTextEncoder)) {
  cachedTextEncoder.encodeInto = function(arg, view) {
    const buf = cachedTextEncoder.encode(arg);
    view.set(buf);
    return {
      read: arg.length,
      written: buf.length
    };
  };
}
var WASM_VECTOR_LEN = 0;
var wasmModule;
var wasmInstance;
var wasm;
function __wbg_finalize_init(instance, module) {
  wasmInstance = instance;
  wasm = instance.exports;
  wasmModule = module;
  cachedDataViewMemory0 = null;
  cachedUint8ArrayMemory0 = null;
  wasm.__wbindgen_start();
  return wasm;
}
function initSync(module) {
  if (wasm !== void 0) return wasm;
  if (module !== void 0) {
    if (Object.getPrototypeOf(module) === Object.prototype) {
      ({ module } = module);
    } else {
      console.warn("using deprecated parameters for `initSync()`; pass a single object instead");
    }
  }
  const imports = __wbg_get_imports();
  if (!(module instanceof WebAssembly.Module)) {
    module = new WebAssembly.Module(module);
  }
  const instance = new WebAssembly.Instance(module, imports);
  return __wbg_finalize_init(instance, module);
}

// js/wasm.js
initSync({ module: readFileSync(new URL("./link.wasm", import.meta.url)) });

// js/registry.js
var PAIRING_TTL_MS = 5 * 6e4;
var DeviceRegistry2 = class {
  #inner;
  #onChange;
  #now;
  constructor(devices = [], onChange = void 0, now = Date.now) {
    this.#inner = new DeviceRegistry(devices);
    this.#onChange = onChange;
    this.#now = now;
  }
  list() {
    return this.#inner.list();
  }
  openPairing(ttlMs = PAIRING_TTL_MS) {
    return this.#inner.openPairing(ttlMs, this.#now());
  }
  closePairing() {
    this.#inner.closePairing();
  }
  pairingOpen() {
    return this.#inner.pairingOpen(this.#now());
  }
  /** Whether a device may start a handshake: it is paired, or a pairing code is open. */
  admits(deviceId, identityKey) {
    return this.#inner.admits(deviceId, identityKey, this.#now());
  }
  /** The check after the handshake: a paired device, or a new one that holds the open code. */
  authorize(deviceId, identityKey, hello = {}) {
    const { allowed, changed } = this.#inner.authorize(deviceId, identityKey, hello.name, hello.pairingCode, this.#now());
    if (changed) this.#onChange?.(this.list());
    return allowed;
  }
  revoke(deviceId) {
    const removed = this.#inner.revoke(deviceId);
    if (removed) this.#onChange?.(this.list());
    return removed;
  }
};

// js/driver.js
var ignore = () => {
};
var Driver = class {
  #core;
  #onAction;
  #createSocket;
  #sockets = /* @__PURE__ */ new Map();
  #timer;
  /** `onAction` gets every action that is not about a socket. */
  constructor(core, onAction, createSocket = (url) => new WebSocket(url)) {
    this.#core = core;
    this.#onAction = onAction;
    this.#createSocket = createSocket;
  }
  /** Calls `fn(core, now)`, then carries out what the core asks. Returns what `fn` returns. */
  run(fn) {
    try {
      return fn(this.#core, Date.now());
    } finally {
      for (let action = this.#core.pollAction(); action !== void 0; action = this.#core.pollAction()) this.#act(action);
      this.#arm();
    }
  }
  /** Stops the timer and lets go of every socket. */
  halt() {
    clearTimeout(this.#timer);
    for (const id of this.#sockets.keys()) this.#close(id);
  }
  #act(action) {
    switch (action.type) {
      case "connect":
        return this.#connect(action.socket, action.url);
      case "sendText":
        return this.#send(action.socket, action.text);
      case "sendBinary":
        return this.#send(action.socket, action.data);
      case "closeSocket":
        return this.#close(action.socket);
      default:
        return this.#onAction(action);
    }
  }
  #arm() {
    clearTimeout(this.#timer);
    const at = this.#core.nextDeadline();
    if (at === void 0) return;
    this.#timer = setTimeout(() => this.run((core, now) => core.tick(now)), Math.max(0, at - Date.now()));
    this.#timer.unref?.();
  }
  #connect(id, url) {
    let socket;
    try {
      socket = this.#createSocket(url);
    } catch (error) {
      queueMicrotask(() => this.run((core, now) => core.socketClosed(id, messageOf(error), now)));
      return;
    }
    socket.binaryType = "arraybuffer";
    this.#sockets.set(id, socket);
    let opened = false;
    socket.onopen = () => {
      opened = true;
      this.run((core, now) => core.socketOpened(id, now));
    };
    socket.onmessage = ({ data }) => this.run((core, now) => typeof data === "string" ? core.socketText(id, data, now) : core.socketBinary(id, new Uint8Array(data), now));
    socket.onerror = () => this.#lost(id, opened ? "The connection to the Server failed." : "The Server did not answer the connection.");
    socket.onclose = ({ reason }) => this.#lost(id, reason || "The Server closed the connection.");
  }
  #send(id, data) {
    try {
      this.#sockets.get(id)?.send(data);
    } catch (error) {
      this.#lost(id, messageOf(error));
    }
  }
  #lost(id, reason) {
    if (!this.#sockets.has(id)) return;
    this.#close(id);
    this.run((core, now) => core.socketClosed(id, reason, now));
  }
  // The core has already counted the socket gone, so its own close event, which can take
  // minutes on a dead network, is not waited for. A late error from it is swallowed: an
  // EventEmitter socket would throw one that has no listener.
  #close(id) {
    const socket = this.#sockets.get(id);
    if (socket === void 0) return;
    this.#sockets.delete(id);
    socket.onopen = socket.onmessage = socket.onclose = null;
    socket.onerror = ignore;
    try {
      socket.close();
    } catch {
    }
  }
};
function messageOf(error) {
  return error instanceof Error ? error.message : String(error);
}

// js/host.js
var HostLink = class {
  #options;
  #core;
  #driver;
  #calls = /* @__PURE__ */ new Map();
  #waiters = /* @__PURE__ */ new Set();
  constructor(options) {
    this.#options = options;
    this.#core = new HostCore({
      server: options.url,
      identity: options.identity,
      accessToken: options.accessToken,
      name: options.name,
      maxLinks: options.maxTunnels
    }, Date.now());
    this.#driver = new Driver(this.#core, (action) => this.#act(action), options.createSocket);
  }
  /** 'stopped' | 'connecting' | 'online' | 'offline' */
  get status() {
    return this.#core.status();
  }
  /** Why the last socket ended, for surfaces that show 'offline'. */
  get error() {
    return this.#core.error();
  }
  start() {
    this.#driver.run((core, now) => core.start(now));
  }
  async stop() {
    this.#driver.run((core, now) => core.stop(now));
    this.#driver.halt();
  }
  async waitOnline(timeoutMs = 1e4) {
    const deadline = Date.now() + timeoutMs;
    while (this.status !== "online") {
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("The computer did not reach the Server in time.");
      await new Promise((resolve) => {
        const done = () => {
          clearTimeout(timer);
          this.#waiters.delete(done);
          resolve();
        };
        const timer = setTimeout(done, left);
        this.#waiters.add(done);
      });
    }
  }
  /** Phones with a finished handshake that are on the Server now. */
  connectedDevices() {
    return this.#core.connectedDevices();
  }
  /** Ends every link of a device, for example when the user removes it. */
  disconnect(deviceId) {
    this.#driver.run((core, now) => core.disconnect(deviceId, now));
  }
  /** Tells every phone with a link that something changed; a phone away for now hears it when back. */
  emit(event, data) {
    const json = JSON.stringify(data ?? null);
    this.#driver.run((core, now) => core.emit(event, json, now));
  }
  #act(action) {
    switch (action.type) {
      case "status":
        return this.#status(action.status);
      case "authorize":
        return void this.#authorize(action);
      case "request":
        return void this.#serve(action);
      case "cancel":
        return this.#cancel(action);
      case "readyCount":
        return this.#options.onReadyCount?.(action.count);
    }
  }
  #status(status) {
    for (const waiter of this.#waiters) waiter();
    this.#options.onStatus?.(status);
  }
  async #authorize({ link, deviceId, identityKey, name, pairingCode }) {
    const hello = { ...name === void 0 ? {} : { name }, ...pairingCode === void 0 ? {} : { pairingCode } };
    let allowed = false;
    try {
      allowed = Boolean(this.#options.admits(deviceId, identityKey) && await this.#options.authorize(deviceId, identityKey, hello));
    } catch {
    }
    this.#driver.run((core, now) => core.authorize(link, allowed, now));
  }
  async #serve({ link, request, deviceId, method, params }) {
    const key = `${link} ${request}`;
    const controller = new AbortController();
    this.#calls.set(key, controller);
    let answer;
    try {
      const result = await this.#options.handle(method, JSON.parse(params), { deviceId, signal: controller.signal });
      const json = JSON.stringify(result ?? null) ?? "null";
      answer = (core, now) => core.respond(link, request, json, now);
    } catch (error) {
      const code = typeof error?.code === "string" ? error.code : "HOST_ERROR";
      const message = error instanceof Error ? error.message : String(error);
      answer = (core, now) => core.respondError(link, request, code, message, now);
    }
    if (this.#calls.get(key) !== controller) return;
    this.#calls.delete(key);
    this.#driver.run(answer);
  }
  #cancel({ link, request }) {
    const key = `${link} ${request}`;
    this.#calls.get(key)?.abort(new Error("The phone link closed."));
    this.#calls.delete(key);
  }
};

// js/phone.js
var PhoneLink = class {
  #core;
  #driver;
  #calls = /* @__PURE__ */ new Map();
  #eventListeners = /* @__PURE__ */ new Set();
  #statusListeners = /* @__PURE__ */ new Set();
  constructor({ server, identity, accessToken, hostDeviceId, hostKey, name, pairingCode, createSocket }) {
    this.#core = new ClientCore({ server, identity, accessToken, hostDeviceId, hostKey, name, pairingCode }, Date.now());
    this.#driver = new Driver(this.#core, (action) => this.#act(action), createSocket);
  }
  /** `{status, ...}` as `onStatus` hears it, or undefined before `connect`. */
  get status() {
    return this.#core.status();
  }
  get hostName() {
    return this.#core.hostName();
  }
  /** Starts the link. Resolves when it is first online; rejects with the `code` of a refusal. */
  connect() {
    return new Promise((resolve, reject) => {
      const off = this.onStatus((status) => {
        if (status.status === "online") {
          off();
          resolve();
        } else if (status.status === "rejected" || status.status === "closed") {
          off();
          reject(Object.assign(new Error(status.message ?? "The link was closed."), { code: status.code ?? "CLIENT_CLOSED" }));
        }
      });
      this.#driver.run((core, now) => core.start(now));
    });
  }
  /** Calls the computer. A `timeoutMs` of 0 means the default, 60 s. */
  rpc(method, params, { timeoutMs = 0 } = {}) {
    return new Promise((resolve, reject) => {
      const json = JSON.stringify(params ?? null);
      this.#driver.run((core, now) => {
        this.#calls.set(core.rpc(method, json, timeoutMs, now), { resolve, reject });
      });
    });
  }
  /** `listener(name, data)` for each event the computer emits. Returns the unsubscribe. */
  onEvent(listener) {
    this.#eventListeners.add(listener);
    return () => this.#eventListeners.delete(listener);
  }
  /** `listener({status, resumed?, attempt?, error?, code?, message?})` on each change. Returns the unsubscribe. */
  onStatus(listener) {
    this.#statusListeners.add(listener);
    return () => this.#statusListeners.delete(listener);
  }
  /** Drops the socket and dials again at once, as the app does when the network changes. */
  networkChanged() {
    this.#driver.run((core, now) => core.networkChanged(now));
  }
  close() {
    this.#driver.run((core, now) => core.close(now));
    this.#driver.halt();
  }
  #act(action) {
    switch (action.type) {
      case "status": {
        const { type: _, ...status } = action;
        for (const listener of this.#statusListeners) listener(status);
        return;
      }
      case "event":
        for (const listener of this.#eventListeners) listener(action.name, JSON.parse(action.data));
        return;
      case "rpcDone":
        return this.#done(action);
    }
  }
  #done({ call, ok, result, code, message }) {
    const waiting = this.#calls.get(call);
    if (waiting === void 0) return;
    this.#calls.delete(call);
    if (ok) waiting.resolve(JSON.parse(result));
    else waiting.reject(Object.assign(new Error(message), { code }));
  }
};

// js/index.js
var LINK_PATH = linkPath();
export {
  DeviceRegistry2 as DeviceRegistry,
  HostLink,
  LINK_PATH,
  PhoneLink,
  RelayCore,
  deviceIdFor,
  generateKeyPair,
  identityFingerprint,
  pairingUri,
  parsePairingUri,
  randomToken
};
