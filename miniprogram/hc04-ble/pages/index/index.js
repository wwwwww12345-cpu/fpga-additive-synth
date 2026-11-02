/**
 * FPGA 乐器控制台（首页）
 *  - 连接管理（复用原有扫描/连接流程，已验证可用）
 *  - 音域（±12 八度步进 + 重置兜底）
 *  - 音色（钢琴 / 吉他，0x86）以及和弦模式（开关 + 大三/小三/属七）
 *  - 曲谱下发（全局队列串行发送）+ 演奏开始/停止/复位
 *  - 收发日志面板（hex + 协议注释 + 清空）
 * 所有命令字节一律来自 utils/protocol.js，页面不写魔法数字。
 */
const ble = require('../../utils/ble.js')
const sender = require('../../utils/sender.js')
const proto = require('../../utils/protocol.js')
const songs = require('../../utils/songs.js')

// 音域只保留八度两档；按钮直接写「降八度 / 升八度」，不再出现 +12 / −12 这种数字
const RANGE_STEPS = [
  { label: '降八度', delta: -12 }, { label: '升八度', delta: 12 }
]

// 音域偏移 → 人话（±12 即一个八度）
function rangeText(off) {
  if (!off) return '原调'
  const oct = Math.abs(off) / 12
  const n = (oct === 1) ? '1 个八度' : oct + ' 个八度'
  return (off > 0 ? '升 ' : '降 ') + n
}
const CHORD_TYPES = [
  { label: '大三', value: proto.CHORD.MAJOR },
  { label: '小三', value: proto.CHORD.MINOR },
  { label: '属七', value: proto.CHORD.DOM7 }
]
const LOG_CAP = 200

function pad2(n) { return (n < 10 ? '0' : '') + n }

// 只接受当前按钮表里的步进值，杜绝已移除的半音级参数从 dataset 漏进来
function isRangeStep(delta) {
  return RANGE_STEPS.some(s => s.delta === delta)
}

Page({
  data: {
    // 连接
    connected: false,
    connecting: false,
    scanning: false,
    deviceName: '未连接',
    deviceSub: '点击"搜索"开始扫描',
    devices: [],
    // 音域
    rangeOffset: 0,          // 最近一次命令的偏移（半音）；无回读，FPGA 实际状态以此为准（待定：二期状态回显）
    rangeText: '原调',
    rangeSteps: RANGE_STEPS,
    // 和弦
    chordOn: false,
    chordTypes: CHORD_TYPES,
    chordType: proto.CHORD.MAJOR,
    // 音色（0x86）：0=钢琴 1=吉他；无回读，以最近一次命令为准
    timbre: proto.TIMBRE.PIANO,
    // 同一个框里并排两块，点哪块就是哪个音色（默认钢琴）
    timbreOptions: [
      { label: '钢琴', value: proto.TIMBRE.PIANO },
      { label: '吉他', value: proto.TIMBRE.GUITAR }
    ],
    timbreNames: proto.TIMBRE_NAMES,
    // 混响湿度（0x89）：0=干声，127≈全湿；默认 32 = 以前固定的 25%
    reverbMix: proto.REVERB_DEFAULT,
    reverbPct: Math.round(proto.REVERB_DEFAULT / 127 * 100),
    // 滑音（0x8B）：0=关，1..127 越大滑得越慢；默认 0
    glide: proto.GLIDE_DEFAULT,
    // 曲谱
    songNames: [],
    songIndex: 0,
    sending: false,
    sendCur: 0,
    sendTotal: 0,
    // 日志
    log: [{ t: '--:--:--', dir: 'sys', hex: '', note: '系统就绪' }]
  },

  onLoad() {
    // 连接状态：页面存活期间始终监听（掉线提示 + 禁用发送）
    this._offConn = ble.onConnState(res => {
      if (!res.connected && this.data.connected) {
        sender.clear()
        this.setData({ connected: false, deviceName: '已断开', deviceSub: '点击重新搜索' })
        this.addLog('sys', '', '连接已断开，未发送的队列已清空')
      } else if (res.connected) {
        this.refreshConn()
      }
    })
    // 发送队列日志 → 日志面板：订阅放 onShow/onHide（见下）。
    // 原来挂在 onLoad 上、卸载才注销，导致去「弹琴」页时首页仍在后台对每一帧
    // 做 addLog + setData（一串音就是一串 setData），白白拖慢按键延迟。
    this.refreshSongs()
  },

  onShow() {
    if (!this._offQueueLog) {
      this._offQueueLog = sender.onLog(e => {
        this.addLog(e.dir, e.hex, e.note)
      })
    }
    // 字节 RX 回调：仅本页可见时接管（demo 页同样模式，避免双页重复消费）
    if (!this._offBytes) {
      this._decoder = proto.createDecoder()
      this._offBytes = ble.onBytes(buf => this.onRx(buf))
    }
    this.refreshConn()
    this.refreshSongs()   // 曲谱库可能在 songs 页被改动
  },

  onHide() {
    if (this._offBytes) { this._offBytes(); this._offBytes = null }
    if (this._offQueueLog) { this._offQueueLog(); this._offQueueLog = null }
  },

  onUnload() {
    clearTimeout(this._scanTimer)   // B6（评审）：扫描超时定时器随页面销毁清理
    if (this._offBytes) { this._offBytes(); this._offBytes = null }
    if (this._offConn) { this._offConn(); this._offConn = null }
    if (this._offQueueLog) { this._offQueueLog(); this._offQueueLog = null }
    // B1（评审）：不在页面卸载时断开全局连接——ble.js 连接态是模块级单例，
    // 断开只由用户点「断开」按钮触发（与 demo 页行为对齐，防误卸载时断连）
  },

  refreshConn() {
    const on = ble.isConnected()
    if (on !== this.data.connected) {
      this.setData({
        connected: on,
        // 连接是全局单例：可能在"弹琴"页连上再回来，本页没有本地名字，就用 ble 里记住的
        deviceName: on ? (this.data.deviceName !== '未连接' ? this.data.deviceName : (ble.deviceName || '已连接')) : '未连接',
        deviceSub: on ? 'FFE1 · 已连接' : '点击"搜索"开始扫描'
      })
    } else if (on && this.data.deviceName === '未连接') {
      this.setData({ deviceName: ble.deviceName || '已连接', deviceSub: 'FFE1 · 已连接' })
    }
  },

  refreshSongs() {
    const list = songs.list()
    const names = list.map(s => s.name + '（' + s.entries.length + '条）')
    let idx = this.data.songIndex
    // 首次进页面默认选「Love Song」；用户手动切过一次之后就不再覆盖他的选择
    if (!this._songPicked && list.length) {
      const li = list.findIndex(s => String(s.name).indexOf('Love Song') >= 0)
      if (li >= 0) idx = li
    }
    if (idx >= list.length) idx = Math.max(0, list.length - 1)
    // A2（评审）：不参与渲染的簿记字段存实例属性，不走 setData（省一次序列化+视图层通道）
    this._songIds = list.map(s => s.id)
    this.setData({ songNames: names, songIndex: idx })
  },

  // ================= 连接（沿用已调通的扫描/连接流程） =================

  async onConnectTap() {
    if (this.data.connected) {
      await ble.disconnect()
      this.setData({ connected: false, deviceName: '未连接', deviceSub: '点击"搜索"开始扫描' })
      this.addLog('sys', '', '已断开连接')
      return
    }
    this.setData({ connecting: true, scanning: true, devices: [], deviceSub: '扫描中(最多8秒)…' })
    this._scanStopped = false
    this.addLog('sys', '', '开始扫描 BLE 设备…（确认模块没被电脑连着，否则不会广播）')
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
        this.addLog('sys', '', `扫描结束：共 ${found.length} 台。` + (found.length
          ? '在列表里点你的模块连接。'
          : '0 台！排查：1) 电脑/其他手机是否还连着模块(占用后不广播) 2) 安卓给微信开位置权限 3) 模块断电重上电'))
      }, 8500)
    } catch (e) {
      this.setData({ connecting: false, scanning: false, deviceSub: '蓝牙初始化失败: ' + e.errMsg })
      this.addLog('err', '', '蓝牙初始化失败: ' + (e.errMsg || e.message))
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
      this.addLog('sys', '', '已停止扫描，正在连接…')
    }
    this._connecting = true
    this.setData({ deviceSub: '正在连接 ' + (d.name || '(无名)') + '…' })
    try {
      await ble.connect(d.deviceId, d.name)
      if (this._decoder) this._decoder.reset()  // 清掉上次会话残留的半帧
      this.setData({
        connected: true, connecting: false,
        deviceName: d.name || '(无名)', deviceSub: 'FFE1 · 已连接',
        devices: []
      })
      this.addLog('sys', '', '已连接 ' + (d.name || d.deviceId))
    } catch (e) {
      this.setData({ connecting: false, deviceSub: '连接失败: ' + e.message })
      this.addLog('err', '', '连接失败: ' + e.message)
    }
    this._connecting = false
  },

  // ================= 音域 =================

  async onRangeStep(e) {
    const delta = Number(e.currentTarget.dataset.delta)
    if (!isRangeStep(delta)) {   // 只认 ±12；其它入参（含已移除的半音级）一律丢弃
      this.addLog('err', '', '忽略非法音域步进: ' + delta + '（音域只保留 ±12）')
      return
    }
    const next = proto.clamp(this.data.rangeOffset + delta, -proto.RANGE_BIAS, 127 - proto.RANGE_BIAS)
    if (next === this.data.rangeOffset) {
      wx.showToast({ title: '已到音域边界', icon: 'none' })
      return
    }
    // B5（评审）：仅当发送成功才更新本地状态，防 UI 与 FPGA 实际状态漂移
    const ok = await this.sendCmd(proto.encodeRangeSet(next), '音域 ' + rangeText(next))
    if (ok) this.setData({ rangeOffset: next, rangeText: rangeText(next) })
  },

  async onRangeReset() {
    const ok = await this.sendCmd(proto.encodeRangeReset(), '音域重置（兜底归位，含传感器侧偏移）')
    if (ok) this.setData({ rangeOffset: 0, rangeText: '原调' })   // B5（评审）
  },

  // ================= 和弦 =================

  async onChordSwitch(e) {
    const on = !!e.detail.value
    this.setData({ chordOn: on })   // 受控 switch 先跟手回显
    const t = on ? this.data.chordType : proto.CHORD.OFF
    const ok = await this.sendCmd(proto.encodeChordSet(t), '和弦 ' + (on ? proto.CHORD_NAMES[t] : '关'))
    if (!ok) this.setData({ chordOn: !on })   // B5（评审）：发送失败回滚到 FPGA 侧真实状态
  },

  async onChordType(e) {
    const t = Number(e.detail.value)
    const prev = this.data.chordType
    this.setData({ chordType: t })  // 受控 radio 先跟手回显
    if (this.data.chordOn) {
      const ok = await this.sendCmd(proto.encodeChordSet(t), '和弦 ' + proto.CHORD_NAMES[t])
      if (!ok) this.setData({ chordType: prev })   // B5（评审）
    }
  },

  // ================= 音色（0x86） =================

  async onTimbreSelect(e) {
    const next = Number(e.currentTarget.dataset.value)
    if (next === this.data.timbre) return          // 已经选中，不重复发
    if (!this.data.connected) {
      wx.showToast({ title: '请先连接', icon: 'none' })
      return
    }
    const prev = this.data.timbre
    this.setData({ timbre: next })   // 受控选择先跟手回显
    const ok = await this.sendCmd(proto.encodeTimbre(next), '音色 ' + proto.TIMBRE_NAMES[next])
    if (!ok) {
      // B5（评审）：发送失败回滚到 FPGA 侧真实状态，并留痕
      this.setData({ timbre: prev })
      this.addLog('err', '', '音色切换到「' + proto.TIMBRE_NAMES[next] + '」失败，已回滚为「' + proto.TIMBRE_NAMES[prev] + '」')
    }
  },

  // ================= 混响（0x89） =================

  // 拖动中：只更新界面 + 限速下发（每 120ms 最多一帧，避免刷爆发送队列）
  onReverbChanging(e) {
    const v = Number(e.detail.value)
    this.setData({ reverbMix: v, reverbPct: Math.round(v / 127 * 100) })
    const now = Date.now()
    if (now - (this._rvbT || 0) >= 120) {
      this._rvbT = now
      this.sendReverb(v)
    }
  },

  // 松手：再确认一次最终值
  onReverbChange(e) {
    const v = Number(e.detail.value)
    this.setData({ reverbMix: v, reverbPct: Math.round(v / 127 * 100) })
    this.sendReverb(v)
  },

  async sendReverb(v) {
    if (!this.data.connected) return
    try {
      await sender.send(proto.encodeReverb(v), '混响 ' + Math.round(v / 127 * 100) + '%')
    } catch (e) { /* 队列已把失败写进日志面板 */ }
  },

  // ================= 滑音（0x8B） =================

  onGlideChanging(e) {
    const v = Number(e.detail.value)
    this.setData({ glide: v })
    const now = Date.now()
    if (now - (this._gldT || 0) >= 120) {
      this._gldT = now
      this.sendGlide(v)
    }
  },

  onGlideChange(e) {
    const v = Number(e.detail.value)
    this.setData({ glide: v })
    this.sendGlide(v)
  },

  async sendGlide(v) {
    if (!this.data.connected) return
    try {
      await sender.send(proto.encodeGlide(v), '滑音 ' + (v === 0 ? '关' : v + '/127'))
    } catch (e) { /* 队列已把失败写进日志面板 */ }
  },

  // ================= 曲谱下发与演奏 =================

  onSongChange(e) {
    this._songPicked = true      // 用户手动选过曲，刷新列表时不再覆盖
    this.setData({ songIndex: Number(e.detail.value) })
  },

  async onSendSong() {
    if (this.data.sending) return
    if (!this.data.connected) {   // B6（评审）：按钮禁用之外的兜底前置检查
      wx.showToast({ title: '未连接', icon: 'none' })
      return
    }
    const ids = this._songIds || []   // A2（评审）：读实例属性（原 this.data._songIds）
    const song = songs.get(ids[this.data.songIndex])
    if (!song) { wx.showToast({ title: '曲谱库为空', icon: 'none' }); return }
    let frames
    try {
      frames = proto.encodeSongFrames(song)   // 空/超512/越界在此抛错
    } catch (err) {
      wx.showModal({ title: '无法下发', content: err.message, showCancel: false })
      return
    }
    // 条目帧不逐帧记日志（512 条会刷爆日志面板），只记开始/结束帧 + 汇总 + 进度
    const marked = frames.map((f, i) =>
      (f.cmd === proto.CMD.SONG_ENTRY) ? { ...f, note: null } : f)
    this.setData({ sending: true, sendCur: 0, sendTotal: frames.length })
    const t0 = Date.now()
    try {
      await sender.sendBatch(marked, {
        onProgress: (cur, total) => this.setData({ sendCur: cur, sendTotal: total })
      })
      const dt = ((Date.now() - t0) / 1000).toFixed(1)
      this.addLog('sys', '', `《${song.name}》下发完成：${song.entries.length} 条 / ${frames.length} 帧 / ${dt}s`)
      wx.showToast({ title: '下发完成', icon: 'success' })
    } catch (e) {
      this.addLog('err', '', `《${song.name}》下发失败: ` + (e.errMsg || e.message) + '，本批剩余帧已丢弃')
      wx.showToast({ title: '下发失败', icon: 'none' })
    }
    this.setData({ sending: false })
  },

  async onPlayStart() { await this.sendCmd(proto.encodePlayStart(), '演奏开始') },
  async onPlayStop()  { await this.sendCmd(proto.encodePlayStop(), '演奏停止') },
  async onPlayReset() { await this.sendCmd(proto.encodePlayReset(), '演奏复位') },
  async onPing() {
    this._pingT = Date.now()
    await this.sendCmd(proto.encodePing(), 'PING')
  },

  // ================= 发送（统一走全局队列） =================

  async sendCmd(bytes, note) {
    if (!this.data.connected) {
      this.addLog('err', '', '未连接，无法发送「' + note + '」')
      wx.showToast({ title: '未连接', icon: 'none' })
      return false
    }
    try {
      await sender.send({ bytes, note })
      return true
    } catch (e) {
      return false   // 失败详情已由队列写入日志面板
    }
  },

  // ================= RX 与日志 =================

  onRx(buf) {
    const u8 = new Uint8Array(buf)
    const hex = Array.from(u8).map(b => b.toString(16).padStart(2, '0').toUpperCase()).join(' ')
    // ASCII 可打印预览（不可打印字节显示 ·）
    const ascii = Array.from(u8).map(b => (b >= 32 && b < 127) ? String.fromCharCode(b) : '·').join('')
    // 协议解码
    let frames = []
    if (this._decoder) frames = this._decoder.pushAll(u8)
    // 回显过滤：v0 只有 0xA0~0xA2 是真下行，其余都是 FPGA 把刚收到的字节原样回显
    const downs = frames.filter(f => f.cmd >= 0xA0 && f.cmd <= 0xA2)
    const echoes = frames.filter(f => !(f.cmd >= 0xA0 && f.cmd <= 0xA2))
    const desc = downs.map(f => f.desc).join('; ')
    const echoTag = echoes.length ? `（回显 ${echoes.length} 帧）` : ''
    this.addLog('rx', hex, (desc ? desc + ' ' : '') + echoTag + (ascii ? `| "${ascii}"` : ''))
    downs.forEach(f => this.onDownFrame(f))
  },

  // 只处理真正的下行应答：ACK / NACK
  onDownFrame(f) {
    if (f.cmd === proto.CMD.ACK) {
      const c = f.data[0] | 0x80
      if (c === proto.CMD.SONG_END) wx.showToast({ title: '曲谱下发成功', icon: 'success' })
      else if (c === proto.CMD.PING) {
        const rtt = this._pingT ? (Date.now() - this._pingT) : 0
        this._pingT = 0
        wx.showToast({ title: rtt ? ('FPGA 在线 ' + rtt + 'ms') : 'FPGA 在线', icon: 'none' })
      }
    } else if (f.cmd === proto.CMD.NACK) {
      const c = f.data[0] | 0x80, code = f.data[1]
      wx.showModal({
        title: 'FPGA 拒绝 0x' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase(),
        content: proto.ackReason(code),
        showCancel: false
      })
    }
  },

  addLog(dir, hex, note) {
    const d = new Date()
    const t = `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
    const log = this.data.log.concat({ t, dir, hex, note })
    if (log.length > LOG_CAP) log.splice(0, log.length - LOG_CAP)
    this.setData({ log })
  },

  onClearLog() {
    this.setData({ log: [{ t: '--:--:--', dir: 'sys', hex: '', note: '已清空' }] })
  }
})
