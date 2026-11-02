/**
 * 全局发送队列（全局唯一，所有页面共用）
 *
 * 硬约束（任务书）：
 *   - 页面只管入队，严禁直接调 BLE 写
 *   - 单包 ≤20 字节；包间隔 ≥10ms；串行执行
 *   - 写失败（如 10008）必须 catch 并写入日志，不能让队列卡死
 *
 * 批发送语义：同一批（如整曲下发）中任何一包写失败，
 * 立即丢弃该批剩余帧并 reject，避免 FPGA 收到半截曲谱。
 */

'use strict'

var ble = require('./ble.js')

var PACKET_SIZE = 20   // 【B2 不变量，禁止调大】必须 = 20（默认 ATT MTU 23 − 3 字节头）。
                       // ble.js 的 setBLEMTU 协商在部分平台（尤其 iOS）不保证生效，20 是唯一
                       // 无条件安全值；若要调大，必须先在真机确认 MTU 协商稳定生效，否则静默截断。
var PACKET_GAP = 10    // 相邻两包最小间隔 ms
var MAX_QUEUE = 2000   // B4（评审）：队列溢出保护——任务书要求，超限直接拒绝入队
                       // （512 条满载曲谱 = 514 帧，连点两次 1028 帧仍放行，四连点即拒绝）

var queue = []         // [{ data: ArrayBuffer, note: string|null, batch: object|null, done: function }]
var pumping = false

// ---- 日志订阅（index 页把回调接到日志面板） ----

var logCbs = []
function onLog(cb) {
  logCbs.push(cb)
  return function off() {
    var i = logCbs.indexOf(cb)
    if (i >= 0) logCbs.splice(i, 1)
  }
}
function emitLog(dir, hex, note) {
  for (var i = 0; i < logCbs.length; i++) {
    try { logCbs[i]({ dir: dir, hex: hex, note: note }) } catch (e) { /* 页面回调异常不影响队列 */ }
  }
}

function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms) }) }

function toU8(bytes) {
  if (bytes instanceof Uint8Array) return bytes
  if (bytes instanceof ArrayBuffer) return new Uint8Array(bytes)
  if (Array.isArray(bytes)) return new Uint8Array(bytes)
  throw new Error('不支持的字节类型: ' + typeof bytes)
}

function hexOf(u8) {
  var s = []
  for (var i = 0; i < u8.length; i++) s.push(u8[i].toString(16).padStart(2, '0').toUpperCase())
  return s.join(' ')
}

function bufOf(u8) { return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) }

// ---- 对外 API ----

/**
 * 单帧发送。frame: Uint8Array（或 protocol.js 返回的 {bytes} 项）。
 * note: 日志可读注释；传 null 则不记 TX 行（静默）。
 */
function send(frame, note) {
  var u8 = frame && frame.bytes ? toU8(frame.bytes) : toU8(frame)
  return new Promise(function (resolve, reject) {
    // 兜底分片（当前协议单帧 ≤4 字节，正常不会触发）
    var slices = split(u8)
    if (queue.length + slices.length > MAX_QUEUE) {   // B4：溢出保护
      reject(new Error('发送队列溢出：待发 ' + queue.length + ' + 本次 ' + slices.length + ' > 上限 ' + MAX_QUEUE))
      return
    }
    var left = slices.length
    var failed = false
    var done = function (err) {
      if (failed) return
      if (err) { failed = true; reject(err) }
      else if (--left === 0) resolve()
    }
    slices.forEach(function (s) {
      queue.push({ data: bufOf(s), note: note, batch: null, done: done })
    })
    pump()
  })
}

/**
 * 批量发送（整曲下发）。frames: [{bytes, note}, ...]（protocol.encodeSongFrames 产物）
 * opts.onProgress(sent, total) 可选；任何一包失败：丢弃本批剩余帧并 reject。
 */
function sendBatch(frames, opts) {
  opts = opts || {}
  return new Promise(function (resolve, reject) {
    var total = frames.length
    if (!total) { reject(new Error('批量不能为空')); return }
    if (queue.length + total > MAX_QUEUE) {   // B4：溢出保护（入队前拒绝，一帧都不进队）
      reject(new Error('发送队列溢出：待发 ' + queue.length + ' + 本批 ' + total + ' > 上限 ' + MAX_QUEUE))
      return
    }
    var batch = {}
    var sent = 0
    var settled = false
    var done = function (err) {
      if (settled) return
      if (err) {
        settled = true
        purgeBatch(batch)
        reject(err)
      } else {
        sent++
        if (opts.onProgress) { try { opts.onProgress(sent, total) } catch (e) {} }
        if (sent === total) { settled = true; resolve() }
      }
    }
    frames.forEach(function (f) {
      var u8 = toU8(f.bytes)
      if (u8.length > PACKET_SIZE) throw new Error('帧长 ' + u8.length + ' 超过单包上限 ' + PACKET_SIZE)
      queue.push({ data: bufOf(u8), note: f.note != null ? f.note : null, batch: batch, done: done })
    })
    pump()
  })
}

/** 清空未发送的队列（如断线时）。正在写的一包无法中止，属正常。 */
function clear() { queue.length = 0 }

function pendingCount() { return queue.length }

// ---- 内部 ----

function split(u8) {
  var out = []
  for (var i = 0; i < u8.length; i += PACKET_SIZE) {
    out.push(u8.slice(i, Math.min(i + PACKET_SIZE, u8.length)))
  }
  if (!out.length) out.push(new Uint8Array(0))
  return out
}

function purgeBatch(batch) {
  for (var i = queue.length - 1; i >= 0; i--) {
    if (queue[i].batch === batch) queue.splice(i, 1)
  }
}

async function pump() {
  if (pumping) return
  pumping = true
  while (queue.length) {
    var it = queue.shift()
    if (!ble.isConnected()) {
      emitLog('err', hexOf(new Uint8Array(it.data)), (it.note || '帧') + ' — 未连接，丢弃' + (it.batch ? '（本批中止）' : ''))
      it.done(new Error('BLE 未连接'))
      continue // 未连接的丢弃不占节流间隔
    }
    try {
      await ble.writeBytes(it.data)
      if (it.note !== null) emitLog('tx', hexOf(new Uint8Array(it.data)), it.note)
      it.done()
    } catch (e) {
      var msg = (e && (e.errMsg || e.message)) || String(e)
      emitLog('err', hexOf(new Uint8Array(it.data)), (it.note || '帧') + ' 写失败: ' + msg + (it.batch ? '，本批剩余帧已丢弃' : ''))
      it.done(new Error(msg))
    }
    await sleep(PACKET_GAP) // 包间隔 ≥10ms
  }
  pumping = false
}

module.exports = {
  send: send,
  sendBatch: sendBatch,
  clear: clear,
  pendingCount: pendingCount,
  onLog: onLog,
  PACKET_SIZE: PACKET_SIZE,
  PACKET_GAP: PACKET_GAP,
  MAX_QUEUE: MAX_QUEUE
}
