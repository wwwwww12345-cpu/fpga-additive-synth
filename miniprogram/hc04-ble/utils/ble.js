/**
 * HC-04 BLE 串口封装
 *
 * 两套发送接口并存：
 *   1. 二进制协议（v0 控制台用）：writeBytes(ArrayBuffer)，帧格式见 utils/protocol.js
 *      与 docs/PROTOCOL.md；节流分包由 utils/sender.js 全局队列负责。
 *   2. 旧 ASCII 字符串（demo 自测页用）：write("60+") —— 仅为兼容保留，
 *      严禁用它发 >0x7F 的字节（字符串编码会损坏数据）。
 * 接收回调：onBytes(cb) 订阅原始字节（ArrayBuffer），onConnState(cb) 订阅连接状态。
 */

// HC-04 双模固件常用 UUID（如连不上请用 nRF Connect 扫描确认后修改）
const SERVICE_UUID = '0000FFE0-0000-1000-8000-00805F9B34FB'
const CHAR_UUID = '0000FFE1-0000-1000-8000-00805F9B34FB' // 支持 notify + write

const DEVICE_NAME = 'HC-04' // 设备广播名前缀，按实际修改

let deviceId = ''
let charId = ''
let svcId = ''   // connect() 实际命中的服务 UUID（writeBytes 用它，比常量更稳）
let devName = '' // 最近一次连接成功的设备名（connect 时记，供其他页面显示）

const p = (api, opts = {}) => new Promise((resolve, reject) => {
  wx[api]({ ...opts, success: resolve, fail: reject })
})

async function openAdapter() {
  try { await p('openBluetoothAdapter') } catch (e) { /* 已打开时忽略 */ }
  // B2（评审）：setBLEMTU 原先在这里调用，但此刻 deviceId 还是空串 → 协商从未生效
  // （错误被 catch 吞掉）。已移到 connect() 成功之后。在 sender.PACKET_SIZE=20
  // 这个不变量下协商失败不影响功能（20 = 默认 ATT MTU 23 − 3 字节头），见 sender.js 顶部。
}

// B3（评审，原有代码继承问题）：wx.onBluetoothDeviceFound 每次扫描重复注册、
// 永不注销 → 多轮扫描后回调叠加（重复条目/向已销毁页面 setData）。
// 改为模块级只注册一次，内部路由到"当前扫描"的回调；扫描结束/停止时摘掉路由。
//
// N2（第 2 轮复核新发现，本文件必修）：startScan 的 8s 收尾定时器若不被清理，
// 陈旧定时器越过到期点时会【停掉新扫描的 discovery + 清空新扫描的路由】——
// 真实症状："扫描中"却 0 台设备（断线后 8s 内重扫 / index↔demo 换页扫都会踩）。
// 其中"停 discovery"为旧代码继承，"清路由"为 B3 重构引入，此处一并修复：
// 每轮扫描的收尾定时器保存到 scanTimer，开新扫描/停止扫描时先作废旧定时器。
let deviceFoundRouter = null
let deviceHookInstalled = false
let scanTimer = null

function installDeviceHook() {
  if (deviceHookInstalled) return
  deviceHookInstalled = true
  wx.onBluetoothDeviceFound(res => { if (deviceFoundRouter) deviceFoundRouter(res) })
}

function startScan(onFound) {
  return new Promise(async (resolve, reject) => {
    // 先挂回调再开扫描: iOS 上 allowDuplicatesKey=false 时每台设备整个扫描期
    // 只上报一次, 若首包赶在注册之前就永远丢 (实测 0 台的根因之一)
    const seen = {}
    installDeviceHook()
    deviceFoundRouter = res => {
      res.devices.forEach(d => {
        const key = d.deviceId
        if (!seen[key]) {
          seen[key] = true
          onFound({ deviceId: d.deviceId, name: d.name || '', rssi: d.RSSI, raw: d })
        }
      })
    }
    await p('startBluetoothDevicesDiscovery', {
      services: [], // HC-04 广播不一定带 service uuid，空数组扫全部
      allowDuplicatesKey: true, // true: 反复上报, 上层自行去重; false 在 iOS 有缓存坑
      interval: 0
    })
    resolve()
    clearTimeout(scanTimer)   // N2：作废上一轮遗留的收尾定时器（它属于旧扫描，无权动新扫描）
    scanTimer = setTimeout(() => {
      scanTimer = null
      deviceFoundRouter = null // 扫描窗结束，摘掉路由（等效注销）
      wx.stopBluetoothDevicesDiscovery().catch(() => {})
    }, 8000)
  })
}

// 主动停止扫描（点选设备即连时调用, 不等 8 秒超时）
function stopScan() {
  clearTimeout(scanTimer)   // N2：停止即作废收尾定时器，防止其稍后误杀下一轮扫描
  scanTimer = null
  deviceFoundRouter = null
  return p('stopBluetoothDevicesDiscovery').catch(() => {})
}

async function connect(deviceId_, name_) {
  deviceId = deviceId_
  // 2026-11-02: 记住设备名。连接是**模块级单例**，页面之间会互相看得见；
  // 之前只有"发起连接的那个页面"知道名字，另一页进来就显示"未连接"（圆点是绿的）。
  devName = name_ || ''
  await p('createBLEConnection', { deviceId })
  const res = await p('getBLEDeviceServices', { deviceId })
  const svc = res.services.find(s => s.uuid.toUpperCase() === SERVICE_UUID)
    || res.services.find(s => s.uuid.toUpperCase().startsWith('0000FFE0'))
  if (!svc) throw new Error('找不到 FFE0 服务，请确认 UUID')
  const cres = await p('getBLEDeviceCharacteristics', { deviceId, serviceId: svc.uuid })
  const ch = cres.characteristics.find(c => c.uuid.toUpperCase() === CHAR_UUID)
  if (!ch) throw new Error('找不到 FFE1 特征')
  charId = ch.uuid
  svcId = svc.uuid
  await p('notifyBLECharacteristicValueChange', {
    deviceId, serviceId: svc.uuid, characteristicId: charId, state: true
  })
  // B2（评审）：MTU 协商放在连接建立之后才有效（iOS 不保证生效，catch 静默）。
  // 注意：PACKET_SIZE=20 不变量下协商失败无影响；一旦有人调大 PACKET_SIZE，此协商成为必需。
  p('setBLEMTU', { deviceId, mtu: 185 }).catch(() => {})
  return { serviceId: svc.uuid, characteristicId: charId }
}

async function write(str) {
  const data = str + '\n'
  const buffer = new ArrayBuffer(data.length)
  const view = new Uint8Array(buffer)
  for (let i = 0; i < data.length; i++) view[i] = data.charCodeAt(i)
  // BLE 单次写约 20 字节（MTU 协商后可更长），超过则自动分包，间隔 30ms
  const chunk = 20
  for (let i = 0; i < buffer.byteLength; i += chunk) {
    await p('writeBLECharacteristicValue', {
      deviceId,
      serviceId: SERVICE_UUID,
      characteristicId: CHAR_ID(),
      value: buffer.slice(i, Math.min(i + chunk, buffer.byteLength))
    }).catch(() => {})
    if (buffer.byteLength > chunk) await new Promise(r => setTimeout(r, 30))
  }
}

function CHAR_ID() { return charId }

// ---------------------------------------------------------------------------
// ↓↓↓ v0 控制台新增：二进制写接口 + 字节/连接状态回调（扫描/连接逻辑未动） ↓↓↓
// ---------------------------------------------------------------------------

/** 是否处于已连接状态（connect 成功后 true；主动断开或意外掉线后 false） */
function isConnected() { return !!(deviceId && charId) }

/**
 * 二进制写：一次写一个完整 ArrayBuffer（不做拆包/不加延迟——节流分包由 utils/sender.js 全局队列负责）。
 * 严禁把 >0x7F 的字节走字符串封装（字符串编码会损坏数据），必须走本函数。
 */
async function writeBytes(buffer) {
  if (!isConnected()) {
    const err = new Error('BLE 未连接')
    err.errMsg = 'BLE 未连接'
    throw err
  }
  return p('writeBLECharacteristicValue', {
    deviceId,
    serviceId: svcId,
    characteristicId: charId,
    value: buffer
  })
}

// ---- 字节流 / 连接状态 回调注册表 ----
// 旧 demo 页曾直接 wx.onBLECharacteristicValueChange（页面间会重复注册、无法注销），
// 现统一由 ble.js 注册一次 wx 钩子再分发；页面 onShow 订阅、onHide 注销。

const byteCbs = []
const connCbs = []
let hooksInstalled = false

function installHooks() {
  if (hooksInstalled) return
  hooksInstalled = true
  wx.onBLECharacteristicValueChange(res => {
    if (res.deviceId !== deviceId) return
    byteCbs.forEach(cb => { try { cb(res.value, res.deviceId) } catch (e) { /* 页面回调异常不影响分发 */ } })
  })
  wx.onBLEConnectionStateChange(res => {
    if (!res.connected && res.deviceId === deviceId) {
      // 意外掉线：清空连接态， isConnected() 变 false，发送队列会丢弃后续帧
      deviceId = ''; charId = ''; svcId = ''; devName = ''
    }
    connCbs.forEach(cb => { try { cb(res) } catch (e) {} })
  })
}

/** 订阅 RX 字节流（ArrayBuffer）。返回注销函数。 */
function onBytes(cb) { installHooks(); byteCbs.push(cb); return function () {
  const i = byteCbs.indexOf(cb); if (i >= 0) byteCbs.splice(i, 1)
} }

/** 订阅连接状态变化（透传 wx 回调参数）。返回注销函数。 */
function onConnState(cb) { installHooks(); connCbs.push(cb); return function () {
  const i = connCbs.indexOf(cb); if (i >= 0) connCbs.splice(i, 1)
} }
// ↑↑↑ v0 新增结束 ↑↑↑

// N1（记录在案，二期处理）：连接生命周期归属 App 全局而非某个 Page——
// B1 之后断开只由用户点「断开」按钮触发。若将来引入 tabBar / redirectTo
// 导致页面卸载重建，连接会静默存活，届时需在 app.js 加兜底断开。
async function disconnect() {
  if (!deviceId) return
  await p('closeBLEConnection', { deviceId }).catch(() => {})
  await p('closeBluetoothAdapter').catch(() => {})
  deviceId = ''; charId = ''; svcId = ''; devName = ''
}

// 接收： ArrayBuffer -> ASCII 字符串
function buf2str(buf) {
  return String.fromCharCode.apply(null, new Uint8Array(buf))
}

module.exports = {
  openAdapter, startScan, stopScan, connect, write, writeBytes, disconnect, buf2str,
  isConnected, onBytes, onConnState,
  SERVICE_UUID, CHAR_UUID, DEVICE_NAME,
  get deviceId() { return deviceId },
  get deviceName() { return devName }
}
