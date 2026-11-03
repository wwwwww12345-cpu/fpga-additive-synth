/**
 * FPGA 乐器串口字节协议 v0 —— 常量 + encode/decode 纯函数
 *
 * 【本文件是协议唯一定义处】页面代码严禁散写命令字节等魔法数字。
 * 详细文档见 docs/PROTOCOL.md。
 *
 * 硬约束：
 *   1. 全二进制，命令帧 = 1 命令字节 + 0~3 数据字节
 *   2. bit7=0（0x00~0x7F）→ 数据字节；bit7=1（0x80~0xFF）→ 命令字节
 *      因此 note/vel/dur 均必须 ≤127，任何数据流都不会被误认成命令
 *   3. 本文件为纯函数，不依赖 BLE / wx，可在 Node 或控制台直接自测
 *
 * 【与任务书的差异，已显式标注】任务书原文写 dur 1~255，但 255 > 127
 * 会撞上命令字节空间（bit7=1），故 v0 定为 dur 1~127（10ms~1270ms），
 * 更长时值用连续多条同音条目拼接。如确需 >127，二期再引入扩展帧（待定）。
 */

'use strict'

var PROTOCOL_VERSION = 'v0.6'   // v0.6（2026-11-03）：补 0x94/0x95 灯带指引弹奏（曲谱下发后按灯带弹）

// ---------------- 命令表（数值可调，表结构保持） ----------------

var CMD = {
  PING:        0x80, // 0 数据字节：连通性探测
  RANGE_SET:   0x81, // 1 数据字节：音域设置（偏移半音数 + 64）
  CHORD_SET:   0x82, // 1 数据字节：和弦开关+类型
  RANGE_RESET: 0x83, // 0 数据字节：音域重置（兜底归位，与传感器挡位并存）
  PLAY_START:  0x84, // 0 数据字节：演奏开始
  PLAY_STOP:   0x85, // 0 数据字节：演奏停止
  TIMBRE_SET:  0x86, // 1 数据字节：音色 0=钢琴 非0=吉他（复位默认钢琴）
  NOTE_ON:     0x87, // 2 数据字节：单音按下 note/vel（小钢琴键盘用，见 §noteName）
  NOTE_OFF:    0x88, // 1 数据字节：单音松开 note
  REVERB_SET:  0x89, // 1 数据字节：混响湿度 0=干声 .. 127=几乎全湿（复位默认 32 = 现有 25%）
  GLIDE_SET:   0x8B, // 1 数据字节：滑音（音与音之间的 portamento）0=关，1=快 .. 127=慢/长（复位默认 0）
  SONG_START:  0x90, // 2 数据字节：曲谱下发开始（条目数低/高）
  SONG_ENTRY:  0x91, // 3 数据字节：曲谱条目 note/vel/dur
  SONG_END:    0x92, // 0 数据字节：曲谱下发结束
  PLAY_RESET:  0x93, // 0 数据字节：演奏复位（曲谱指针/状态归零）
  GUIDE_START: 0x94, // 0 数据字节：灯带指引弹奏开始（要用已下发且校验通过的曲谱，否则 FPGA 回 NACK 码 4）
  GUIDE_STOP:  0x95, // 0 数据字节：灯带指引弹奏停止（退出指引，灯带归零）
  // ---- 下行（FPGA → 手机）----
  ACK:         0xA1, // 1 数据字节：被确认的命令字节
  NACK:        0xA2  // 2 数据字节：出错命令字节 + 错误码
}

// 每条命令的数据字节长度（decode 状态机也用它）
var CMD_DATA_LEN = {
  0x80: 0, 0x81: 1, 0x82: 1, 0x83: 0, 0x84: 0, 0x85: 0,
  0x86: 1,
  0x87: 2, 0x88: 1,   // 单音按下/松开（FPGA ble_cmd.v C_NON/C_NOFF 已实现）
  0x89: 1,            // 混响湿度（FPGA ble_cmd.v C_VERB）
  0x8B: 1,            // 滑音（FPGA ble_cmd.v C_GLID）
  0x90: 2, 0x91: 3, 0x92: 0, 0x93: 0,
  0x94: 0, 0x95: 0,   // 灯带指引弹奏开始/停止（FPGA ble_cmd.v C_GSTR/C_GSTP，0 数据字节）
  0xA1: 1, 0xA2: 2
}

// 命令可读名（日志用）
var CMD_NAMES = {
  0x80: 'PING', 0x81: '音域设置', 0x82: '和弦设置', 0x83: '音域重置',
  0x84: '演奏开始', 0x85: '演奏停止',
  0x86: '音色切换',
  0x89: '混响湿度',
  0x8B: '滑音',
  0x87: '单音按下', 0x88: '单音松开',
  0x90: '曲谱开始', 0x91: '曲谱条目', 0x92: '曲谱结束', 0x93: '演奏复位',
  0x94: '指引弹奏开始', 0x95: '指引弹奏停止',
  0xA1: 'ACK', 0xA2: 'NACK'
}

// NACK 错误码（与 RTL ack_tx / ble_cmd.evt_code 对齐）
var ACK_REASONS = {
  1: '条目数不符（实际写入条数与 0x90 声明的 N 不一致）',
  2: 'N 超范围（N>512 或 N=0）',
  3: '还没开始下发就发了 0x92',
  4: '未下发曲谱 / 曲谱无效（0x94 指引弹奏要求 0x92 已校验通过）'
}

function ackReason(code) {
  return ACK_REASONS[code] || ('未知错误码 ' + code)
}

function toHex2(b) {
  var s = (b & 0xff).toString(16).toUpperCase()
  return s.length < 2 ? '0' + s : s
}

// ---------------- 数据约束常量 ----------------

var RANGE_BIAS  = 64          // 音域偏移编码：数据字节 = 半音偏移 + 64（64→0 半音，范围 -64~+63）
var CHORD       = { OFF: 0, MAJOR: 1, MINOR: 2, DOM7: 3 }
var CHORD_NAMES = { 0: '关', 1: '大三', 2: '小三', 3: '属七' }
// 音色（0x86）：FPGA 语义为「非 0 即吉他」，本端只发 0/1 两个规范值
var TIMBRE       = { PIANO: 0, GUITAR: 1 }
var TIMBRE_NAMES = { 0: '钢琴', 1: '吉他' }
var NOTE_REST   = 0           // note=0 表示休止符
var MAX_ENTRIES = 512         // FPGA 侧曲谱 RAM 按 512 条设计（任务书硬约束）
var NOTE_MIN = 0,  NOTE_MAX = 127
var VEL_MIN  = 1,  VEL_MAX  = 127
var DUR_MIN  = 1,  DUR_MAX  = 127   // 见文件头【差异标注】：不是 255
var DUR_UNIT_MS = 10          // dur 单位：10ms

// ---------------- 内部工具 ----------------

function assertInt(v, name, min, max, where) {
  if (!Number.isInteger(v)) throw new Error((where || '') + name + ' 必须为整数，得到: ' + v)
  if (v < min || v > max) throw new Error((where || '') + name + ' 超范围 [' + min + ',' + max + ']，得到: ' + v)
}

// 组帧：命令字节 + 数据字节 → Uint8Array
function frame(cmd, data) {
  var out = new Uint8Array(1 + (data ? data.length : 0))
  out[0] = cmd
  if (data) for (var i = 0; i < data.length; i++) out[1 + i] = data[i]
  return out
}

function clamp(v, min, max) { return v < min ? min : (v > max ? max : v) }

// ---------------- encode：单帧命令 ----------------

function encodePing() { return frame(CMD.PING) }

// semitones: -64~+63 半音；编码为 semitones + 64
function encodeRangeSet(semitones) {
  assertInt(semitones, '音域偏移', -RANGE_BIAS, 127 - RANGE_BIAS)
  return frame(CMD.RANGE_SET, [semitones + RANGE_BIAS])
}

function encodeRangeReset() { return frame(CMD.RANGE_RESET) }

// type: CHORD.OFF / MAJOR / MINOR / DOM7
function encodeChordSet(type) {
  assertInt(type, '和弦类型', 0, 3)
  return frame(CMD.CHORD_SET, [type])
}

function encodePlayStart()  { return frame(CMD.PLAY_START) }
function encodePlayStop()   { return frame(CMD.PLAY_STOP) }
function encodePlayReset()  { return frame(CMD.PLAY_RESET) }

// ---------------- encode：灯带指引弹奏（0x94 / 0x95，v0.6） ----------------
// 语义（FPGA 侧 rtl/ble_cmd.v + rtl/guide_ctrl.v）：
//   - 0x94 用「已下发且 0x92 校验通过」的曲谱开始指引：目标音灯亮黄；
//     按对→该灯绿并保持到松开；松开→下一个音黄；按错→红 0.5s 后回黄；
//     休止符自动跳过；曲末自动结束。
//   - 没有有效曲谱时 0x94 被拒（NACK 码 4），所以页面必须先「下发成功」。
//   - 灯带只有 24 颗，对应 MIDI 60~83（C4~B5）；超出范围的音不亮灯但流程照走。
//   - 0x84 自动演奏 / 0x90 重新下发 / 0x93 复位 都会让 FPGA 侧退出指引，本端要同步清状态。
function encodeGuideStart() { return frame(CMD.GUIDE_START) }
function encodeGuideStop()  { return frame(CMD.GUIDE_STOP) }

// v: 0/1（其它真值一律规范化为 1，非真值一律 0）→ 0x86 + 1 数据字节
function encodeTimbre(v) { return frame(CMD.TIMBRE_SET, [v ? 1 : 0]) }

// ---------------- encode：单音（0x87 按下 / 0x88 松开，钢琴键盘用） ----------------
// 注意：vel 必须 ≥1。FPGA 侧用 vel!=0 判"按下"，vel=0 会被当成松开，
//      所以"松开"只能走 0x88，不许发 0x87 note 0。

// note: 0~127（MIDI 音号，60=C4）；vel: 1~127
function encodeNoteOn(note, vel) {
  assertInt(note, 'note', NOTE_MIN, NOTE_MAX, '单音按下: ')
  assertInt(vel, 'vel', VEL_MIN, VEL_MAX, '单音按下: ')
  return frame(CMD.NOTE_ON, [note, vel])
}

// note: 0~127
function encodeNoteOff(note) {
  assertInt(note, 'note', NOTE_MIN, NOTE_MAX, '单音松开: ')
  return frame(CMD.NOTE_OFF, [note])
}

// ---------------- encode：混响湿度（0x89，单音/演奏通用） ----------------
// mix: 0..127。0 = 干声（混响全关），127 ≈ 全湿；复位默认 32（= 原来的固定 25% 湿声）。
var REVERB_DEFAULT = 32
function encodeReverb(mix) {
  assertInt(mix, '混响湿度', 0, 127, '混响: ')
  return frame(CMD.REVERB_SET, [mix])
}

// ---------------- encode：滑音（0x8B，音与音之间的 portamento） ----------------
// amt: 0=关；1=快（约 50ms 滑到目标音）；127=慢（约 1s）。复位默认 0（关），不影响正常演奏。
var GLIDE_DEFAULT = 0
function encodeGlide(amt) {
  assertInt(amt, '滑音', 0, 127, '滑音: ')
  return frame(CMD.GLIDE_SET, [amt])
}

// MIDI 音号 → 音名（60→C4）。只在日志/界面显示用，纯函数。
var MIDI_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
function noteName(n) {
  if (!Number.isInteger(n) || n < NOTE_MIN || n > NOTE_MAX) return '?' + n
  return MIDI_NAMES[n % 12] + (Math.floor(n / 12) - 1)
}

// ---------------- encode：曲谱下发帧序列 ----------------

function validateEntry(e, i) {
  var where = '第 ' + (i + 1) + ' 条: '
  if (typeof e !== 'object' || e === null) throw new Error(where + '必须是对象')
  assertInt(e.note, 'note', NOTE_MIN, NOTE_MAX, where)
  assertInt(e.vel,  'vel',  VEL_MIN,  VEL_MAX,  where)
  assertInt(e.dur,  'dur',  DUR_MIN,  DUR_MAX,  where)
}

function encodeSongStart(count) {
  assertInt(count, '条目数', 1, MAX_ENTRIES)
  return frame(CMD.SONG_START, [count & 0x7F, (count >> 7) & 0x7F]) // 低 7 位 / 高 7 位（均 ≤127）
}

// e: {note, vel, dur}
function encodeSongEntry(e, index) {
  validateEntry(e, index == null ? -1 : index)
  return frame(CMD.SONG_ENTRY, [e.note, e.vel, e.dur])
}

function encodeSongEnd() { return frame(CMD.SONG_END) }

/**
 * 整曲下发帧序列。
 * song: { name, entries: [{note, vel, dur}] }
 * 返回: [{ cmd, bytes: Uint8Array, note: '可读注释' }, ...]
 * 长音/超 512 条在此抛错，页面 catch 后提示。
 */
function encodeSongFrames(song) {
  if (!song || typeof song !== 'object') throw new Error('曲谱对象无效')
  var entries = song.entries || []
  if (!entries.length) throw new Error('曲谱为空，无法下发')
  if (entries.length > MAX_ENTRIES) {
    throw new Error('条目数 ' + entries.length + ' 超过 FPGA 上限 ' + MAX_ENTRIES)
  }
  var frames = [{
    cmd: CMD.SONG_START,
    bytes: encodeSongStart(entries.length),
    note: '曲谱开始《' + (song.name || '未命名') + '》共 ' + entries.length + ' 条'
  }]
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    validateEntry(e, i)
    frames.push({
      cmd: CMD.SONG_ENTRY,
      bytes: frame(CMD.SONG_ENTRY, [e.note, e.vel, e.dur]),
      note: e.note === NOTE_REST
        ? '休止 ' + (e.dur * DUR_UNIT_MS) + 'ms'
        : '条目#' + (i + 1) + ' note=' + e.note + ' vel=' + e.vel + ' dur=' + e.dur
    })
  }
  frames.push({ cmd: CMD.SONG_END, bytes: encodeSongEnd(), note: '曲谱结束' })
  return frames
}

// ---------------- decode：字节流 → 帧状态机 ----------------
// 用于解析 FPGA→小程序的应答（二期启用；接口先留好，v0 先解析任何遵循
// 同一帧格式的字节流）。规则：
//   - 遇 bit7=1 的字节视为新命令帧开始（若上一帧未凑满，上一帧作废并记录 error）
//   - 遇 bit7=0 的字节视为当前帧数据；凑满 CMD_DATA_LEN[cmd] 后产出帧
//   - 未知命令字节：产出 {cmd, data:[], unknown:true}

function createDecoder() {
  var cur = null // { cmd, data: [] }
  return {
    /**
     * 推入一个字节，返回数组（0~1 个完成的帧，批量推入时可多帧）。
     * 帧结构: { cmd, data: [..], desc: '可读注释', error?: string, unknown?: bool }
     */
    push: function (b) {
      var out = []
      if (b & 0x80) {
        if (cur && cur.data.length < (CMD_DATA_LEN[cur.cmd] != null ? CMD_DATA_LEN[cur.cmd] : 0)) {
          out.push({ cmd: cur.cmd, data: cur.data.slice(), error: '帧未凑满即遇新命令', desc: describeFrame(cur.cmd, cur.data) + '（不完整，丢弃）' })
        }
        cur = { cmd: b, data: [] }
        if (CMD_DATA_LEN[b] == null) {
          var f = { cmd: b, data: [], unknown: true, desc: '未知命令 0x' + b.toString(16) }
          cur = null
          out.push(f)
        } else if (CMD_DATA_LEN[b] === 0) {
          out.push({ cmd: b, data: [], desc: describeFrame(b, []) })
          cur = null
        }
      } else {
        if (!cur) { out.push({ cmd: -1, data: [b], error: '游离数据字节', desc: '游离数据 0x' + b.toString(16) }) }
        else {
          cur.data.push(b)
          if (cur.data.length >= CMD_DATA_LEN[cur.cmd]) {
            out.push({ cmd: cur.cmd, data: cur.data.slice(), desc: describeFrame(cur.cmd, cur.data) })
            cur = null
          }
        }
      }
      return out
    },
    /** 批量推入 Uint8Array/Array，返回全部完成的帧 */
    pushAll: function (u8) {
      var out = []
      for (var i = 0; i < u8.length; i++) {
        var fs = this.push(u8[i])
        for (var j = 0; j < fs.length; j++) out.push(fs[j])
      }
      return out
    },
    /** 复位（如断线重连后清残留半帧） */
    reset: function () { cur = null }
  }
}

// ---------------- 帧的可读注释（日志面板用） ----------------

function describeFrame(cmd, data) {
  var name = CMD_NAMES[cmd] || ('未知0x' + cmd.toString(16))
  switch (cmd) {
    case CMD.RANGE_SET:
      var off = (data && data.length) ? data[0] - RANGE_BIAS : 0
      return name + ' → ' + (off >= 0 ? '+' : '') + off + ' 半音'
    case CMD.CHORD_SET:
      return name + ' → ' + (CHORD_NAMES[(data && data[0]) != null ? data[0] : 0] || '?')
    case CMD.TIMBRE_SET:
      // FPGA 语义：0=钢琴，非 0=吉他
      var tv = (data && data.length) ? data[0] : 0
      return name + ' → ' + (tv ? '吉他' : '钢琴')
    case CMD.NOTE_ON:
      if (data && data.length === 2) {
        return name + ' → ' + noteName(data[0]) + ' vel=' + data[1]
      }
      return name
    case CMD.NOTE_OFF:
      if (data && data.length === 1) return name + ' → ' + noteName(data[0])
      return name
    case CMD.REVERB_SET:
      if (data && data.length === 1) {
        return name + ' → ' + data[0] + '/127（约 ' + Math.round(data[0] / 127 * 100) + '% 湿）'
      }
      return name
    case CMD.GLIDE_SET:
      if (data && data.length === 1) {
        return data[0] === 0 ? (name + ' → 关') : (name + ' → ' + data[0] + '/127（越大滑得越慢）')
      }
      return name
    case CMD.SONG_START:
      if (data && data.length === 2) return name + ' → ' + (data[0] | (data[1] << 7)) + ' 条'
      return name
    case CMD.SONG_ENTRY:
      if (data && data.length === 3) {
        return name + ' note=' + data[0] + ' vel=' + data[1] + ' dur=' + data[2]
          + (data[0] === NOTE_REST ? '（休止）' : '')
      }
      return name
    case CMD.ACK:
      if (data && data.length === 1) return 'ACK → 0x' + toHex2(data[0] | 0x80) + ' 已执行'
      return name
    case CMD.NACK:
      if (data && data.length === 2) {
        return 'NACK → 0x' + toHex2(data[0] | 0x80) + ' 失败：' + ackReason(data[1])
      }
      return name
    default:
      return name
  }
}

// ---------------- 自测（模拟器测不了 BLE，这是唯一自动化验证） ----------------
// 用法：微信开发者工具控制台输入  require('../../utils/protocol.js').selfTest()
//       或在本目录用 node 直接运行：node -e "console.log(require('./utils/protocol.js').selfTest())"

function selfTest() {
  var results = []
  function check(name, fn) {
    try { fn(); results.push({ name: name, pass: true }) }
    catch (e) { results.push({ name: name, pass: false, msg: e.message }) }
  }
  function eq(a, b, what) {
    var sa = Array.from(a).map(function (x) { return x.toString(16) }).join(' ')
    var sb = Array.from(b).map(function (x) { return x.toString(16) }).join(' ')
    if (sa !== sb) throw new Error(what + ' 不符: 得到[' + sa + '] 期望[' + sb + ']')
  }
  function throws(fn, what) {
    try { fn() } catch (e) { return }
    throw new Error(what + ' 应当抛错但没有')
  }

  // 1. 单帧编码
  check('PING 编码', function () { eq(encodePing(), [0x80], 'PING') })
  check('音域 +12', function () { eq(encodeRangeSet(12), [0x81, 76], 'RANGE+12') })
  check('音域 -12', function () { eq(encodeRangeSet(-12), [0x81, 52], 'RANGE-12') })
  check('音域 0', function () { eq(encodeRangeSet(0), [0x81, 64], 'RANGE0') })
  check('音域重置', function () { eq(encodeRangeReset(), [0x83], 'RANGE_RESET') })
  check('和弦大三', function () { eq(encodeChordSet(CHORD.MAJOR), [0x82, 1], 'CHORD') })
  check('和弦关', function () { eq(encodeChordSet(CHORD.OFF), [0x82, 0], 'CHORD_OFF') })
  check('演奏开始/停止/复位', function () {
    eq(encodePlayStart(), [0x84], 'PLAY_START')
    eq(encodePlayStop(), [0x85], 'PLAY_STOP')
    eq(encodePlayReset(), [0x93], 'PLAY_RESET')
  })
  // 音色切换（0x86）：FPGA 早已实现，本端补齐
  check('音色 0=钢琴', function () { eq(encodeTimbre(TIMBRE.PIANO), [0x86, 0x00], 'TIMBRE_PIANO') })
  check('音色 1=吉他', function () { eq(encodeTimbre(TIMBRE.GUITAR), [0x86, 0x01], 'TIMBRE_GUITAR') })
  check('音色切换解码 = 1 帧（不得是未知命令+游离数据）', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x86, 0x01])
    if (r.length !== 1) throw new Error('应产出 1 帧，得到 ' + r.length + ' 帧: ' + JSON.stringify(r))
    if (r[0].unknown) throw new Error('0x86 不应被当作未知命令')
    if (r[0].error) throw new Error('不应有 error: ' + r[0].error)
    if (r[0].cmd !== CMD.TIMBRE_SET) throw new Error('cmd=' + r[0].cmd)
    if (r[0].data.length !== 1 || r[0].data[0] !== 1) throw new Error('data=' + JSON.stringify(r[0].data))
    if (r[0].desc !== '音色切换 → 吉他') throw new Error('desc=' + r[0].desc)
  })

  // 单音（0x87 按下 / 0x88 松开）：小钢琴键盘用。vel=0 必须拦死——
  // FPGA ble_cmd.v 用 vel!=0 判"按下"，发 0x87 node 0 会被当成松开。
  check('单音按下 0x87', function () { eq(encodeNoteOn(60, 96), [0x87, 60, 96], 'NOTE_ON') })
  check('单音松开 0x88', function () { eq(encodeNoteOff(60), [0x88, 60], 'NOTE_OFF') })
  check('单音 vel=0 必须抛错（松开只能走 0x88）', function () {
    throws(function () { encodeNoteOn(60, 0) }, 'vel=0')
  })
  check('单音 note/vel 越界抛错', function () {
    throws(function () { encodeNoteOn(128, 96) }, 'note=128')
    throws(function () { encodeNoteOn(-1, 96) }, 'note=-1')
    throws(function () { encodeNoteOn(60, 128) }, 'vel=128')
    throws(function () { encodeNoteOn(60, 1.5) }, 'vel 非整数')
    throws(function () { encodeNoteOff(200) }, 'note=200')
  })
  check('MIDI 音名 noteName', function () {
    if (noteName(60) !== 'C4') throw new Error('60 → ' + noteName(60))
    if (noteName(61) !== 'C#4') throw new Error('61 → ' + noteName(61))
    if (noteName(83) !== 'B5') throw new Error('83 → ' + noteName(83))
    if (noteName(0) !== 'C-1') throw new Error('0 → ' + noteName(0))
    if (noteName(128) !== '?128') throw new Error('128 → ' + noteName(128))
  })
  check('单音 0x87/0x88 decode 往返', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x87, 60, 96, 0x88, 60])
    if (r.length !== 2) throw new Error('应 2 帧，得到 ' + r.length)
    if (r[0].cmd !== CMD.NOTE_ON || r[0].data[0] !== 60 || r[0].data[1] !== 96) {
      throw new Error('NOTE_ON 解析错: ' + JSON.stringify(r[0]))
    }
    if (r[1].cmd !== CMD.NOTE_OFF || r[1].data[0] !== 60) {
      throw new Error('NOTE_OFF 解析错: ' + JSON.stringify(r[1]))
    }
    if (r[0].desc !== '单音按下 → C4 vel=96') throw new Error('desc=' + r[0].desc)
    if (r[1].desc !== '单音松开 → C4') throw new Error('desc=' + r[1].desc)
  })
  // 混响湿度（0x89）：0=干声，32=现有默认，127≈全湿
  check('混响 0x89 编码', function () {
    eq(encodeReverb(0), [0x89, 0], 'REVERB 0')
    eq(encodeReverb(REVERB_DEFAULT), [0x89, 32], 'REVERB 32')
    eq(encodeReverb(127), [0x89, 127], 'REVERB 127')
  })
  check('混响参数越界抛错', function () {
    throws(function () { encodeReverb(128) }, 'mix=128')
    throws(function () { encodeReverb(-1) }, 'mix=-1')
    throws(function () { encodeReverb(32.5) }, 'mix 非整数')
  })
  check('混响 0x89 decode 往返', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x89, 32])
    if (r.length !== 1) throw new Error('应 1 帧，得到 ' + r.length)
    if (r[0].cmd !== CMD.REVERB_SET || r[0].data[0] !== 32) throw new Error('解析错: ' + JSON.stringify(r[0]))
    if (r[0].desc !== '混响湿度 → 32/127（约 25% 湿）') throw new Error('desc=' + r[0].desc)
  })
  // 滑音（0x8B）：0=关，1..127 越大越慢
  check('滑音 0x8B 编码', function () {
    eq(encodeGlide(0), [0x8B, 0], 'GLIDE 0')
    eq(encodeGlide(64), [0x8B, 64], 'GLIDE 64')
    eq(encodeGlide(127), [0x8B, 127], 'GLIDE 127')
  })
  check('滑音参数越界抛错', function () {
    throws(function () { encodeGlide(128) }, 'glide=128')
    throws(function () { encodeGlide(-1) }, 'glide=-1')
    throws(function () { encodeGlide(1.5) }, 'glide 非整数')
  })
  check('滑音 0x8B decode 往返', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x8B, 0, 0x8B, 64])
    if (r.length !== 2) throw new Error('应 2 帧，得到 ' + r.length)
    if (r[0].cmd !== CMD.GLIDE_SET || r[0].data[0] !== 0) throw new Error('解析错: ' + JSON.stringify(r[0]))
    if (r[0].desc !== '滑音 → 关') throw new Error('desc=' + r[0].desc)
    if (r[1].desc !== '滑音 → 64/127（越大滑得越慢）') throw new Error('desc=' + r[1].desc)
  })

  // 灯带指引弹奏（0x94 / 0x95，v0.6）：0 数据字节，和相邻 0 数据命令连发也不能串帧
  check('指引弹奏 0x94 / 停止指引 0x95 编码', function () {
    eq(encodeGuideStart(), [0x94], 'GUIDE_START')
    eq(encodeGuideStop(), [0x95], 'GUIDE_STOP')
  })
  check('指引 0x94/0x95 decode 往返（与前后 0 数据命令连发）', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x92, 0x94, 0x95, 0x84])
    if (r.length !== 4) throw new Error('应 4 帧，得到 ' + r.length + ': ' + JSON.stringify(r))
    if (r[1].cmd !== CMD.GUIDE_START || r[2].cmd !== CMD.GUIDE_STOP) throw new Error('解析错: ' + JSON.stringify(r))
    if (r[1].unknown) throw new Error('0x94 不应被当作未知命令')
    if (r[1].data.length || r[2].data.length) throw new Error('0x94/0x95 不该带数据字节')
    if (r[1].desc !== '指引弹奏开始') throw new Error('desc=' + r[1].desc)
    if (r[2].desc !== '指引弹奏停止') throw new Error('desc=' + r[2].desc)
  })
  check('NACK 码 4 = 未下发曲谱 / 曲谱无效（0x94 被拒，线上 A2 14 04）', function () {
    if (ackReason(4).indexOf('曲谱') < 0) throw new Error('文案: ' + ackReason(4))
    var dec = createDecoder()
    var r = dec.pushAll([0xA2, 0x14, 0x04])
    if (r.length !== 1) throw new Error('应 1 帧，得到 ' + r.length)
    if (r[0].desc.indexOf('0x94') < 0) throw new Error('desc 未还原出 0x94: ' + r[0].desc)
    if (r[0].desc.indexOf('曲谱') < 0) throw new Error('desc 未带原因: ' + r[0].desc)
  })

  // 2. 曲谱帧
  check('曲谱开始 512 条 = 低7位/高7位', function () { eq(encodeSongStart(512), [0x90, 0x00, 0x04], 'SONG_START') })
  check('曲谱开始 130 条', function () { eq(encodeSongStart(130), [0x90, 0x02, 0x01], 'SONG_START130') })
  check('曲谱条目', function () { eq(encodeSongEntry({ note: 60, vel: 100, dur: 8 }), [0x91, 60, 100, 8], 'ENTRY') })
  check('整曲帧数 = 条目数+2', function () {
    var f = encodeSongFrames({ name: 't', entries: [{ note: 1, vel: 1, dur: 1 }, { note: 0, vel: 1, dur: 5 }] })
    if (f.length !== 4) throw new Error('帧数=' + f.length)
    if (f[0].cmd !== CMD.SONG_START || f[3].cmd !== CMD.SONG_END) throw new Error('首尾帧错')
  })

  // 3. 参数校验（越界必须抛错）
  check('非法参数必须抛错', function () {
    throws(function () { encodeRangeSet(64) }, '音域超上限')
    throws(function () { encodeRangeSet(-65) }, '音域超下限')
    throws(function () { encodeChordSet(4) }, '和弦类型非法')
    throws(function () { encodeSongEntry({ note: 128, vel: 1, dur: 1 }) }, 'note=128')
    throws(function () { encodeSongEntry({ note: 60, vel: 0, dur: 1 }) }, 'vel=0')
    throws(function () { encodeSongEntry({ note: 60, vel: 1, dur: 128 }) }, 'dur=128')
    throws(function () { encodeSongStart(513) }, '513 条')
    throws(function () { encodeSongFrames({ name: 'x', entries: [] }) }, '空曲谱')
  })

  // 4. 帧格式硬约束：单帧 ≤20 字节、命令字节 bit7=1、数据字节 bit7=0
  check('帧格式硬约束', function () {
    var frames = encodeSongFrames({
      name: 'x',
      entries: Array.from({ length: 8 }, function (_, i) { return { note: 60 + i, vel: 127, dur: 127 } })
    })
    frames.forEach(function (f) {
      if (f.bytes.length > 20) throw new Error('帧长 ' + f.bytes.length + ' >20')
      if (!(f.bytes[0] & 0x80)) throw new Error('命令字节 bit7=0: ' + f.bytes[0])
      for (var i = 1; i < f.bytes.length; i++) {
        if (f.bytes[i] & 0x80) throw new Error('数据字节 bit7=1: ' + f.bytes[i])
      }
    })
  })

  // 5. encode → decode 往返还原
  check('整曲 encode→decode 往返还原', function () {
    var song = {
      name: '往返测试',
      entries: [
        { note: 60, vel: 96, dur: 50 }, { note: 0, vel: 1, dur: 25 },
        { note: 67, vel: 127, dur: 100 }, { note: 72, vel: 1, dur: 1 }
      ]
    }
    var frames = encodeSongFrames(song)
    var flat = []
    frames.forEach(function (f) { for (var i = 0; i < f.bytes.length; i++) flat.push(f.bytes[i]) })
    var dec = createDecoder()
    var got = dec.pushAll(flat)
    if (got.length !== frames.length) throw new Error('帧数不符: ' + got.length + ' vs ' + frames.length)
    for (var k = 0; k < frames.length; k++) {
      if (got[k].cmd !== frames[k].cmd) throw new Error('第' + k + '帧命令不符')
      var exp = Array.from(frames[k].bytes).slice(1)
      if (got[k].data.join(',') !== exp.join(',')) {
        throw new Error('第' + k + '帧数据不符: [' + got[k].data + '] vs [' + exp + ']')
      }
    }
  })

  // 6. 单帧命令往返 + 畸形流
  check('单帧命令往返', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x81, 76, 0x80])
    if (r.length !== 2 || r[0].cmd !== 0x81 || r[0].data[0] !== 76 || r[1].cmd !== 0x80) {
      throw new Error('结果: ' + JSON.stringify(r))
    }
  })
  check('半帧作废 + 未知命令', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0x91, 1, 2, 0xAB, 0x80]) // 条目只到 2/3 数据就遇到未知命令 0xAB，再 PING
    if (r.length !== 3) throw new Error('应产出 3 帧（残帧+未知+PING），得到 ' + r.length)
    if (!r[0].error) throw new Error('残帧应带 error')
    if (!r[1].unknown) throw new Error('0xAB 应标记 unknown')
    if (r[2].cmd !== 0x80) throw new Error('PING 应正常解析')
  })

  check('ACK / NACK 下行解码', function () {
    var dec = createDecoder()
    var r = dec.pushAll([0xA1, 0x12, 0xA2, 0x10, 0x02])
    if (r.length !== 2) throw new Error('应 2 帧（A1 92 / A2 90 02），得到 ' + r.length)
    if (r[0].cmd !== 0xA1 || r[0].data[0] !== 0x12) throw new Error('ACK 解析错: ' + JSON.stringify(r[0]))
    if (r[1].cmd !== 0xA2 || r[1].data[0] !== 0x10 || r[1].data[1] !== 2) throw new Error('NACK 解析错: ' + JSON.stringify(r[1]))
    if (r[1].desc.indexOf('N 超范围') < 0) throw new Error('NACK 文案未带原因: ' + r[1].desc)
  })

  var pass = results.filter(function (r) { return r.pass }).length
  var summary = 'protocol.selfTest: ' + pass + '/' + results.length + ' 通过 (' + PROTOCOL_VERSION + ')'
  var fails = results.filter(function (r) { return !r.pass })
  if (fails.length) {
    console.error(summary)
    fails.forEach(function (f) { console.error('  ✗ ' + f.name + ': ' + f.msg) })
  } else {
    console.log(summary)
  }
  return { pass: pass, total: results.length, results: results, summary: summary }
}

module.exports = {
  PROTOCOL_VERSION: PROTOCOL_VERSION,
  CMD: CMD,
  CMD_DATA_LEN: CMD_DATA_LEN,
  CMD_NAMES: CMD_NAMES,
  RANGE_BIAS: RANGE_BIAS,
  CHORD: CHORD,
  CHORD_NAMES: CHORD_NAMES,
  TIMBRE: TIMBRE,
  TIMBRE_NAMES: TIMBRE_NAMES,
  NOTE_REST: NOTE_REST,
  MAX_ENTRIES: MAX_ENTRIES,
  NOTE_MIN: NOTE_MIN, NOTE_MAX: NOTE_MAX,
  VEL_MIN: VEL_MIN, VEL_MAX: VEL_MAX,
  DUR_MIN: DUR_MIN, DUR_MAX: DUR_MAX,
  DUR_UNIT_MS: DUR_UNIT_MS,
  clamp: clamp,
  encodePing: encodePing,
  encodeRangeSet: encodeRangeSet,
  encodeRangeReset: encodeRangeReset,
  encodeChordSet: encodeChordSet,
  encodePlayStart: encodePlayStart,
  encodePlayStop: encodePlayStop,
  encodePlayReset: encodePlayReset,
  encodeGuideStart: encodeGuideStart,
  encodeGuideStop: encodeGuideStop,
  encodeTimbre: encodeTimbre,
  encodeNoteOn: encodeNoteOn,
  encodeNoteOff: encodeNoteOff,
  encodeReverb: encodeReverb,
  REVERB_DEFAULT: REVERB_DEFAULT,
  encodeGlide: encodeGlide,
  GLIDE_DEFAULT: GLIDE_DEFAULT,
  noteName: noteName,
  encodeSongStart: encodeSongStart,
  encodeSongEntry: encodeSongEntry,
  encodeSongEnd: encodeSongEnd,
  encodeSongFrames: encodeSongFrames,
  createDecoder: createDecoder,
  describeFrame: describeFrame,
  ACK_REASONS: ACK_REASONS,
  ackReason: ackReason,
  selfTest: selfTest
}
