/**
 * 弹琴页（原 demo 自测页翻新）：两个八度的真实琴键 C4–B5（24 键，14 白 + 10 黑）
 *
 * 按下 → 0x87 note vel（二进制单音，FPGA rtl/ble_cmd.v 的 C_NON）
 * 松开 → 0x88 note     （C_NOFF）
 *
 * 【力度】小程序拿不到按压力度（touch 事件没有压力分量），所以帧里的 vel 是
 * 固定值 VEL_DEFAULT=96（与 FPGA 旧 ASCII 通路的 96 一致）。"力度由 FSR 输入"
 * 是固件侧的事：FPGA 用板上 FSR 的实时读数覆盖 vel（见 docs/PROTOCOL.md 与
 * rtl/top_touch_ble.v 里 fsr_code → vel_now 那套）。本页不读 FSR，也不猜力度。
 *
 * 纪律：所有帧一律走 utils/sender.js 全局队列，页面不许直接 ble.write。
 * 旧的 ASCII 通路（"60+"/"60-"）不再从界面发；FPGA 侧 uart_key 仍兼容，留作调试。
 */
const ble = require('../../utils/ble.js')
const sender = require('../../utils/sender.js')
const proto = require('../../utils/protocol.js')

// 两个八度：C4(60) … B5(83)
const WHITE_NOTES = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79, 81, 83]
// 黑键：音号 → 它左边第几个白键（0 基）
const BLACK_AFTER = [
  { note: 61, after: 0 }, { note: 63, after: 1 },
  { note: 66, after: 3 }, { note: 68, after: 4 }, { note: 70, after: 5 },
  { note: 73, after: 7 }, { note: 75, after: 8 },
  { note: 78, after: 10 }, { note: 80, after: 11 }, { note: 82, after: 12 }
]

// 布局在 rpx 里算：屏幕宽固定 750rpx，14 个白键等分 → 一个白键 750/14 rpx
const KBD_RPX = 750
const WHITE_RPX = KBD_RPX / WHITE_NOTES.length
const BLACK_RPX = 34

// 帧里固定带的力度（0x87 的第二个数据字节，1~127）。
// 若固件改成"用 FSR 实时读数"，这个值会被忽略，发多少都不影响手感。
const VEL_DEFAULT = 96

function buildWhites() {
  // 不标音名：FPGA 侧音域偏移（0x81）随时会改实际音高，屏上写死 C4/C5 反而会错。
  return WHITE_NOTES.map(n => ({ note: n, on: false }))
}

function buildBlacks() {
  return BLACK_AFTER.map(b => ({
    note: b.note,
    left: ((b.after + 1) * WHITE_RPX - BLACK_RPX / 2).toFixed(1),
    on: false
  }))
}

function hexOf(u8) {
  return Array.from(u8).map(b => (b < 16 ? '0' : '') + b.toString(16).toUpperCase()).join(' ')
}

Page({
  data: {
    // 连接
    connected: false,
    connecting: false,
    scanning: false,
    deviceName: '未连接',
    deviceSub: '点右上「连接」扫描 HC-04',
    devices: [],
    // 琴键
    whites: buildWhites(),
    blacks: buildBlacks(),
    // 状态行
    lastText: '—',
    ackText: ''
  },

  onLoad() {
    this._refs = {}          // { note: 引用计数 }，几根手指按着这个音
    this._touchNotes = {}    // { touch identifier: note }，每根手指当前在哪个键上
    this._keys = []          // [{note, black, x1,x2,y1,y2}]，量出来的键矩形
    this._keysReady = false
    this._wIdx = {}
    this._bIdx = {}
    this.data.whites.forEach((k, i) => { this._wIdx[k.note] = i })
    this.data.blacks.forEach((k, i) => { this._bIdx[k.note] = i })

    this._offConn = ble.onConnState(res => {
      if (!res.connected && this.data.connected) {
        this.setData({ connected: false, deviceName: '已断开', deviceSub: '点右上「连接」重新扫描' })
        this.releaseAllVisual()   // 断线后 FPGA 会一直响着按住的音，只能先把界面复位
      }
    })
  },

  onReady() {
    this.measureKeys()       // 首帧渲染完才能量到键矩形
  },

  onResize() {
    this._keysReady = false
    this.measureKeys()       // 横竖屏切换后矩形会变
  },

  onShow() {
    if (!this._offBytes) {
      this._decoder = proto.createDecoder()
      this._offBytes = ble.onBytes(buf => this.onRx(buf))
    }
    const on = ble.isConnected()
    if (on) {
      // 连接是全局单例：可能是在首页连上的，本页没有本地名字 → 用 ble 记住的那个
      this.setData({
        connected: true,
        deviceName: (this.data.deviceName && this.data.deviceName !== '未连接') ? this.data.deviceName : (ble.deviceName || '已连接'),
        deviceSub: 'FFE1 · 已连接'
      })
    } else if (this.data.connected) {
      this.setData({ connected: false, deviceName: '未连接', deviceSub: '点右上「连接」扫描 HC-04' })
    }
    if (!this._keysReady) this.measureKeys()   // 从后台回来/首次进页面补量一次
  },

  onHide() {
    if (this._offBytes) { this._offBytes(); this._offBytes = null }
    // 离开页面时把所有还按着的音松掉，避免 FPGA 挂着一个长音（还有电就一直响）
    this.releaseAll()
  },

  onUnload() {
    if (this._offBytes) { this._offBytes(); this._offBytes = null }
    if (this._offConn) { this._offConn(); this._offConn = null }
    this.releaseAll()
  },

  // ================= 琴键（支持滑弦：手指划过去连续触发） =================
  //
  // 做法：事件挂在整块键盘容器上（不是每个键），用每根手指的坐标去命中键矩形。
  //   - 黑键在白键上层，命中时先查黑键；
  //   - 每根手指单独记「当前按着哪个音」（按 identifier），滑到新键 → 旧音发 0x88、新音发 0x87；
  //   - 同一个音可能被两根手指同时按着，用引用计数避免第二个手指把第一个的音响掉。
  // 键矩形用 createSelectorQuery 量（横屏/页面重进时要重量）。

  measureKeys() {
    const q = wx.createSelectorQuery().in(this)
    q.selectAll('.wkey').boundingClientRect()
    q.selectAll('.bkey').boundingClientRect()
    q.exec(res => {
      const w = (res && res[0]) || []
      const b = (res && res[1]) || []
      if (!w.length) return          // 还没渲染出来，下次再量
      const keys = []
      w.forEach((r, i) => {
        const k = this.data.whites[i]
        if (k) keys.push({ note: k.note, black: false, x1: r.left, x2: r.left + r.width, y1: r.top, y2: r.top + r.height })
      })
      b.forEach((r, i) => {
        const k = this.data.blacks[i]
        if (k) keys.push({ note: k.note, black: true, x1: r.left, x2: r.left + r.width, y1: r.top, y2: r.top + r.height })
      })
      this._keys = keys
      this._keysReady = true
    })
  },

  // 坐标 → 音号（黑键优先，因为它画在白键上面）
  noteAt(x, y) {
    const keys = this._keys || []
    let white = null
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i]
      if (x < k.x1 || x > k.x2 || y < k.y1 || y > k.y2) continue
      if (k.black) return k.note
      if (white == null) white = k.note
    }
    return white
  },

  onKbdStart(e) {
    if (!this.data.connected) {
      wx.showToast({ title: '请先连接蓝牙', icon: 'none' })
      return
    }
    if (!this._keysReady) this.measureKeys()
    const ts = e.changedTouches || e.touches || []
    for (let i = 0; i < ts.length; i++) {
      const t = ts[i]
      let note = this.noteAt(t.clientX, t.clientY)
      // 兜底：矩形还没量到时，用触摸目标自己的 dataset（只有按下那一刻准）
      if (note == null && t.target && t.target.dataset) note = Number(t.target.dataset.note)
      if (note == null || isNaN(note)) continue
      this._touchNotes[t.identifier] = note
      this.pressNote(note)
    }
  },

  onKbdMove(e) {
    const ts = e.touches || []
    for (let i = 0; i < ts.length; i++) {
      const t = ts[i]
      const prev = this._touchNotes[t.identifier]
      const now = this.noteAt(t.clientX, t.clientY)
      if (now === prev) continue
      if (prev != null) this.releaseNote(prev)
      if (now != null) {
        this._touchNotes[t.identifier] = now
        this.pressNote(now)
      } else {
        delete this._touchNotes[t.identifier]   // 滑出键盘：松开，等滑回来再触发
      }
    }
  },

  onKbdEnd(e) {
    const ts = e.changedTouches || e.touches || []
    for (let i = 0; i < ts.length; i++) {
      const id = ts[i].identifier
      const note = this._touchNotes[id]
      if (note == null) continue
      delete this._touchNotes[id]
      this.releaseNote(note)
    }
  },

  // 引用计数：同一个音被多根手指按着时，只发一次 0x87 / 一次 0x88
  pressNote(note) {
    const n = (this._refs[note] || 0) + 1
    this._refs[note] = n
    if (n > 1) return
    this.setKeyOn(note, true)
    this.sendNote(note, true)
  },

  releaseNote(note) {
    const n = this._refs[note] || 0
    if (n <= 0) return
    if (n > 1) { this._refs[note] = n - 1; return }
    delete this._refs[note]
    this.setKeyOn(note, false)
    this.sendNote(note, false)
  },

  setKeyOn(note, on) {
    const wi = this._wIdx[note]
    if (wi != null) { this.setData({ ['whites[' + wi + '].on']: on }); return }
    const bi = this._bIdx[note]
    if (bi != null) this.setData({ ['blacks[' + bi + '].on']: on })
  },

  sendNote(note, on) {
    const bytes = on ? proto.encodeNoteOn(note, VEL_DEFAULT) : proto.encodeNoteOff(note)
    // 不逐帧记日志（弹琴时一秒好几帧），只在状态行显示最后一帧
    sender.send(bytes, null).catch(() => {
      // 失败原因已由 sender 写进队列日志回调；界面只回滚按键高亮与引用计数
      if (on) { delete this._refs[note]; this.setKeyOn(note, false) }
    })
    // 只显示"发出去的音号"，不显示音名：音域偏移（0x81）会改实际音高，屏上写死 C4/C5 会骗人
    this.setData({ lastText: note + ' · ' + hexOf(bytes) })
  },

  // 把所有按住的音松掉（走队列，尽力而为）
  releaseAll() {
    const notes = Object.keys(this._refs || {}).map(Number)
    if (notes.length && ble.isConnected()) {
      notes.forEach(n => { sender.send(proto.encodeNoteOff(n), null).catch(() => {}) })
    }
    this._refs = {}
    this._touchNotes = {}
    this.releaseAllVisual()
  },

  releaseAllVisual() {
    this._refs = {}
    this._touchNotes = {}
    const w = {}
    const b = {}
    this.data.whites.forEach((k, i) => { if (k.on) w['whites[' + i + '].on'] = false })
    this.data.blacks.forEach((k, i) => { if (k.on) b['blacks[' + i + '].on'] = false })
    if (Object.keys(w).length || Object.keys(b).length) this.setData(Object.assign(w, b))
  },

  // ================= 连接（沿用已调通的扫描/连接流程） =================

  async onConnectTap() {
    if (this.data.connected) {
      this.releaseAll()
      await ble.disconnect()
      this.setData({ connected: false, deviceName: '未连接', deviceSub: '点右上「连接」扫描 HC-04' })
      return
    }
    this.setData({ connecting: true, scanning: true, devices: [], deviceSub: '扫描中(最多8秒)…' })
    this._scanStopped = false
    try {
      await ble.openAdapter()
      const found = []
      await ble.startScan(d => {
        const i = found.findIndex(x => x.deviceId === d.deviceId)
        if (i >= 0) found[i] = d
        else found.push(d)
        this.setData({ devices: found.slice() })
      })
      this._scanTimer = setTimeout(() => {
        if (this._scanStopped) return
        this.setData({ scanning: false, connecting: false })
        this.setData({ deviceSub: found.length
          ? '发现 ' + found.length + ' 台，点列表里的设备连接'
          : '没扫到设备：确认模块没被电脑占用、安卓给微信开位置权限、模块重新上电' })
      }, 8500)
    } catch (e) {
      this.setData({ connecting: false, scanning: false, deviceSub: '蓝牙初始化失败: ' + e.errMsg })
    }
  },

  onDeviceTap(e) {
    const id = e.currentTarget.dataset.id
    const d = this.data.devices.find(x => x.deviceId === id)
    if (d && !this.data.connected && !this._connecting) this.doConnect(d)
  },

  async doConnect(d) {
    if (this.data.connected || this._connecting) return
    if (this.data.scanning) {
      this._scanStopped = true
      clearTimeout(this._scanTimer)
      await ble.stopScan()
      this.setData({ scanning: false })
    }
    this._connecting = true
    this.setData({ deviceSub: '正在连接 ' + (d.name || '(无名)') + '…' })
    try {
      await ble.connect(d.deviceId, d.name)
      if (this._decoder) this._decoder.reset()
      this.setData({
        connected: true, connecting: false,
        deviceName: d.name || '(无名)', deviceSub: 'FFE1 · 已连接',
        devices: []
      })
    } catch (e) {
      this.setData({ connecting: false, deviceSub: '连接失败: ' + e.message })
    }
    this._connecting = false
  },

  // ================= 下行应答（只有 PING 会回 ACK） =================

  onRx(buf) {
    if (!this._decoder) return
    const frames = this._decoder.pushAll(new Uint8Array(buf))
    frames.filter(f => f.cmd >= 0xA0 && f.cmd <= 0xA2).forEach(f => {
      if (f.cmd === proto.CMD.ACK) {
        const c = f.data[0] | 0x80
        if (c === proto.CMD.PING) {
          // 往返时间：PING 发出去 → FPGA 的 A1 回来。单程≈RTT/2（含 App/蓝牙栈/串口）
          const rtt = this._pingT ? (Date.now() - this._pingT) : 0
          this._pingT = 0
          this.setData({ ackText: rtt ? ('FPGA 在线 · PING 往返 ' + rtt + ' ms') : 'FPGA 在线' })
          wx.showToast({ title: rtt ? ('FPGA 在线 ' + rtt + 'ms') : 'FPGA 在线', icon: 'none' })
        }
      } else if (f.cmd === proto.CMD.NACK) {
        wx.showModal({
          title: 'FPGA 拒绝 0x' + (f.data[0] | 0x80).toString(16).toUpperCase(),
          content: proto.ackReason(f.data[1]),
          showCancel: false
        })
      }
    })
  },

  async onPing() {
    if (!this.data.connected) { wx.showToast({ title: '请先连接蓝牙', icon: 'none' }); return }
    this.setData({ ackText: '等待应答…' })
    this._pingT = Date.now()
    try { await sender.send(proto.encodePing(), null) } catch (e) { this._pingT = 0; this.setData({ ackText: '发送失败' }) }
  }
})
