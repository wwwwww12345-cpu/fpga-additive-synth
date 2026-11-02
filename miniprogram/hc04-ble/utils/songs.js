/**
 * 曲谱库管理：存储 / 校验 / 导入 / 内置曲
 *
 * 数据模型: { id, name, entries: [{note, vel, dur}] }
 *   note: 0~127（0=休止符） vel: 1~127 dur: 1~127（单位 10ms，见 protocol.js）
 * 存储: wx.setStorageSync('songs_v1', [song, ...])，key 带版本号
 * 条目上限: 512（FPGA 侧曲谱 RAM 容量，与 protocol.MAX_ENTRIES 对齐）
 *
 * 校验/解析函数为纯函数（不碰 wx），可在 Node 里自测。
 */

'use strict'

var proto = require('./protocol.js')

var STORAGE_KEY = 'songs_v1'
var VER_KEY = 'songs_builtin_ver'   // 已并入的内置曲版本（用于给老用户补新增内置曲）
var BUILTIN_VER = 2                 // 每次改 BUILTIN 列表就 +1

// ---------------- 内置示例曲（首次启动时装入） ----------------

var BUILTIN = [
  {
    name: '小星星（示例）',
    entries: [
      { note: 60, vel: 96, dur: 50 }, { note: 60, vel: 96, dur: 50 },
      { note: 67, vel: 96, dur: 50 }, { note: 67, vel: 96, dur: 50 },
      { note: 69, vel: 96, dur: 50 }, { note: 69, vel: 96, dur: 50 },
      { note: 67, vel: 96, dur: 100 },
      { note: 65, vel: 96, dur: 50 }, { note: 65, vel: 96, dur: 50 },
      { note: 64, vel: 96, dur: 50 }, { note: 64, vel: 96, dur: 50 },
      { note: 62, vel: 96, dur: 50 }, { note: 62, vel: 96, dur: 50 },
      { note: 60, vel: 96, dur: 100 }
    ]
  },
  {
    name: '两只老虎（示例）',
    entries: [
      { note: 60, vel: 96, dur: 50 }, { note: 62, vel: 96, dur: 50 },
      { note: 64, vel: 96, dur: 50 }, { note: 60, vel: 96, dur: 50 },
      { note: 60, vel: 96, dur: 50 }, { note: 62, vel: 96, dur: 50 },
      { note: 64, vel: 96, dur: 50 }, { note: 60, vel: 96, dur: 50 },
      { note: 64, vel: 96, dur: 50 }, { note: 65, vel: 96, dur: 50 },
      { note: 67, vel: 96, dur: 100 },
      { note: 64, vel: 96, dur: 50 }, { note: 65, vel: 96, dur: 50 },
      { note: 67, vel: 96, dur: 100 }
    ]
  },
  {
    name: 'C大调音阶（联调测试）',
    entries: [
      { note: 60, vel: 100, dur: 30 }, { note: 62, vel: 100, dur: 30 },
      { note: 64, vel: 100, dur: 30 }, { note: 65, vel: 100, dur: 30 },
      { note: 67, vel: 100, dur: 30 }, { note: 69, vel: 100, dur: 30 },
      { note: 71, vel: 100, dur: 30 }, { note: 72, vel: 100, dur: 60 },
      { note: 71, vel: 100, dur: 30 }, { note: 69, vel: 100, dur: 30 },
      { note: 67, vel: 100, dur: 30 }, { note: 65, vel: 100, dur: 30 },
      { note: 64, vel: 100, dur: 30 }, { note: 62, vel: 100, dur: 30 },
      { note: 60, vel: 100, dur: 60 }
    ]
  },
  {
    // 方大同《Love Song》片段：主歌起到第一次「Love Song 一直想写一首」唱完为止
    // 来源：用户提供的 1=C 4/4 ♩=100 简谱（移动端截图），按 1=C4 展开，四分音符=60(600ms)
    name: 'Love Song（方大同·片段）',
    entries: [
      // —— 我写了这首歌，是一首简单的，不复杂 ——
      { note: 0, vel: 96, dur: 60 }, { note: 72, vel: 96, dur: 60 },
      { note: 71, vel: 96, dur: 60 }, { note: 69, vel: 96, dur: 60 },
      { note: 67, vel: 96, dur: 60 }, { note: 64, vel: 96, dur: 60 },
      { note: 62, vel: 96, dur: 60 }, { note: 0, vel: 96, dur: 60 },
      { note: 0, vel: 96, dur: 60 }, { note: 60, vel: 96, dur: 60 },
      { note: 60, vel: 96, dur: 60 }, { note: 62, vel: 96, dur: 60 },
      { note: 64, vel: 96, dur: 60 }, { note: 67, vel: 96, dur: 60 },
      { note: 67, vel: 96, dur: 60 }, { note: 0, vel: 96, dur: 60 },
      { note: 0, vel: 96, dur: 60 }, { note: 72, vel: 96, dur: 60 },
      { note: 71, vel: 96, dur: 60 }, { note: 69, vel: 96, dur: 60 },
      // —— 也不难唱的那一种歌 ——
      { note: 67, vel: 96, dur: 60 }, { note: 64, vel: 96, dur: 60 },
      { note: 62, vel: 96, dur: 60 }, { note: 60, vel: 96, dur: 60 },
      { note: 60, vel: 96, dur: 60 }, { note: 62, vel: 96, dur: 60 },
      { note: 64, vel: 96, dur: 60 }, { note: 60, vel: 96, dur: 60 },
      // —— 这不是那种只剩下那钢琴的歌 ——
      { note: 60, vel: 96, dur: 60 }, { note: 0, vel: 96, dur: 30 },
      { note: 69, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 67, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      { note: 64, vel: 96, dur: 30 },
      { note: 67, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 69, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      { note: 64, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      // —— 也不是那种 ——
      { note: 67, vel: 96, dur: 30 }, { note: 0, vel: 96, dur: 30 },
      { note: 0, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 69, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      { note: 67, vel: 96, dur: 30 }, { note: 64, vel: 96, dur: 30 },
      // —— 不能只是朋友的歌 ——
      { note: 65, vel: 96, dur: 30 }, { note: 65, vel: 96, dur: 30 },
      { note: 65, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      { note: 64, vel: 96, dur: 30 }, { note: 62, vel: 96, dur: 30 },
      { note: 60, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      // —— 这不是那种 ——
      { note: 67, vel: 96, dur: 30 }, { note: 0, vel: 96, dur: 30 },
      { note: 0, vel: 96, dur: 30 }, { note: 67, vel: 96, dur: 30 },
      { note: 67, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 60, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      // —— 两个人的故事写在一本小说那 ——
      { note: 76, vel: 96, dur: 30 }, { note: 76, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 72, vel: 96, dur: 30 },
      { note: 69, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 76, vel: 96, dur: 30 }, { note: 76, vel: 96, dur: 30 },
      { note: 74, vel: 96, dur: 30 }, { note: 74, vel: 96, dur: 30 },
      { note: 71, vel: 96, dur: 60 }, { note: 67, vel: 96, dur: 90 },
      { note: 67, vel: 96, dur: 30 },
      // —— 小说里有谁会在花田里犯了错，这就 ——
      { note: 67, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 74, vel: 96, dur: 30 },
      { note: 74, vel: 96, dur: 30 }, { note: 72, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 69, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 60 },
      { note: 72, vel: 96, dur: 30 }, { note: 74, vel: 96, dur: 30 },
      // —— 是一首写给你听的 ——
      { note: 75, vel: 96, dur: 60 }, { note: 75, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 30 }, { note: 70, vel: 96, dur: 60 },
      { note: 67, vel: 96, dur: 30 }, { note: 65, vel: 96, dur: 30 },
      { note: 64, vel: 96, dur: 60 }, { note: 67, vel: 96, dur: 60 },
      { note: 69, vel: 96, dur: 60 }, { note: 72, vel: 96, dur: 60 },
      // —— Love Song（第一次出现），一直想写一首 ——
      // 5̇ = 高音 sol = G5(79)；3̇ = 高音 mi = E5(76)
      { note: 79, vel: 96, dur: 120 }, { note: 76, vel: 96, dur: 120 },
      { note: 76, vel: 96, dur: 30 }, { note: 77, vel: 96, dur: 30 },
      { note: 76, vel: 96, dur: 30 }, { note: 74, vel: 96, dur: 30 },
      { note: 72, vel: 96, dur: 60 }, { note: 71, vel: 96, dur: 60 }
    ]
  }
]

// ---------------- 存储 ----------------

function loadRaw() {
  try {
    var v = wx.getStorageSync(STORAGE_KEY)
    return Array.isArray(v) ? v : []
  } catch (e) { return [] }
}

function persist(list) { wx.setStorageSync(STORAGE_KEY, list) }

function genId() {
  return 's' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
}

/** 读取曲谱库；首次（空库）装入内置示例曲；老库按 BUILTIN_VER 补入新增内置曲 */
function list() {
  var l = loadRaw()
  if (!l.length) {
    BUILTIN.forEach(function (s) { l.push({ id: genId(), name: s.name, entries: s.entries.slice() }) })
    persist(l)
    setVer(BUILTIN_VER)
    return l
  }
  // 迁移：已有库只补「库里还没有的内置曲」，同名（用户可能改过）一律不覆盖
  if (getVer() < BUILTIN_VER) {
    var names = {}
    l.forEach(function (s) { names[s.name] = true })
    var added = false
    BUILTIN.forEach(function (s) {
      if (!names[s.name]) {
        l.push({ id: genId(), name: s.name, entries: s.entries.slice() })
        names[s.name] = true
        added = true
      }
    })
    if (added) persist(l)
    setVer(BUILTIN_VER)
  }
  return l
}

function getVer() {
  try { return Number(wx.getStorageSync(VER_KEY)) || 0 } catch (e) { return 0 }
}

function setVer(v) {
  try { wx.setStorageSync(VER_KEY, v) } catch (e) { /* 忽略：下次启动再补 */ }
}

function get(id) {
  return list().find(function (s) { return s.id === id }) || null
}

/** 取不重复的名字：重名时自动加 " (2)" " (3)" …（导入/新建用） */
function uniqueName(name, exceptId) {
  var names = {}
  list().forEach(function (s) { if (s.id !== exceptId) names[s.name] = true })
  if (!names[name]) return name
  var i = 2
  while (names[name + ' (' + i + ')']) i++
  return name + ' (' + i + ')'
}

/** 新增。song: {name, entries}（须已通过校验）。返回保存后的对象（含 id，name 可能已去重） */
function add(song) {
  var l = list()
  var s = { id: genId(), name: uniqueName(song.name.trim()), entries: song.entries.slice() }
  l.push(s)
  persist(l)
  return s
}

/** 编辑保存（改名字和/或条目）。名字与其他曲重复时抛错（编辑是显式行为，不自动改名） */
function update(id, patch) {
  var l = list()
  var i = l.findIndex(function (s) { return s.id === id })
  if (i < 0) throw new Error('曲谱不存在（可能已被删除）')
  if (patch.name != null) {
    var name = patch.name.trim()
    var dup = l.some(function (s) { return s.id !== id && s.name === name })
    if (dup) throw new Error('已存在同名曲谱「' + name + '」，请换个名字')
    l[i].name = name
  }
  if (patch.entries != null) {
    // B7（评审）：公开 API 的 entries patch 同样过校验，防绕过 UI 写入脏数据
    var r = validateSong({ name: l[i].name, entries: patch.entries })
    if (!r.ok) throw new Error('条目校验失败：' + r.errors.join('；'))
    l[i].entries = r.song.entries
  }
  persist(l)
  return l[i]
}

function rename(id, name) { return update(id, { name: name }) }

function remove(id) {
  var l = list().filter(function (s) { return s.id !== id })
  persist(l)
}

// ---------------- 校验与导入（纯函数，无 wx 依赖） ----------------

var NAME_MAX = 32

function validateEntry(e, i, errors) {
  var where = '第 ' + (i + 1) + ' 条: '
  if (typeof e !== 'object' || e === null || Array.isArray(e)) { errors.push(where + '必须是对象'); return }
  var keys = Object.keys(e).sort().join(',')
  if (keys !== 'dur,note,vel') { errors.push(where + '字段必须且只能是 note/vel/dur，得到: ' + keys); return }
  if (!Number.isInteger(e.note)) { errors.push(where + 'note 必须为整数'); return }
  if (!Number.isInteger(e.vel))  { errors.push(where + 'vel 必须为整数'); return }
  if (!Number.isInteger(e.dur))  { errors.push(where + 'dur 必须为整数'); return }
  if (e.note < proto.NOTE_MIN || e.note > proto.NOTE_MAX) errors.push(where + 'note 范围 ' + proto.NOTE_MIN + '~' + proto.NOTE_MAX + '（0=休止），得到 ' + e.note)
  if (e.vel < proto.VEL_MIN || e.vel > proto.VEL_MAX) errors.push(where + 'vel 范围 ' + proto.VEL_MIN + '~' + proto.VEL_MAX + '，得到 ' + e.vel)
  if (e.dur < proto.DUR_MIN || e.dur > proto.DUR_MAX) {
    errors.push(where + 'dur 范围 ' + proto.DUR_MIN + '~' + proto.DUR_MAX + '（单位10ms，长音用连续同音条目拼接），得到 ' + e.dur)
  }
}

/**
 * 校验曲谱对象（内置编辑器与 JSON 导入共用）。
 * obj: { name, entries }。返回 { ok, song?, errors: [] }
 */
function validateSong(obj) {
  var errors = []
  if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) return { ok: false, errors: ['顶层必须是对象'] }
  var keys = Object.keys(obj)
  for (var k = 0; k < keys.length; k++) {
    if (keys[k] !== 'name' && keys[k] !== 'entries') errors.push('多余字段 "' + keys[k] + '"（只允许 name / entries）')
  }
  var name = obj.name
  if (typeof name !== 'string' || !name.trim()) errors.push('name 必须为非空字符串')
  else if (name.trim().length > NAME_MAX) errors.push('name 长度须 ≤' + NAME_MAX + ' 字符')
  if (!Array.isArray(obj.entries)) {
    errors.push('entries 必须为数组')
  } else {
    if (obj.entries.length < 1) errors.push('entries 至少 1 条')
    if (obj.entries.length > proto.MAX_ENTRIES) errors.push('条目数 ' + obj.entries.length + ' 超过上限 ' + proto.MAX_ENTRIES + '（FPGA 曲谱 RAM 容量）')
    obj.entries.forEach(function (e, i) { validateEntry(e, i, errors) })
  }
  if (errors.length) return { ok: false, errors: errors }
  return {
    ok: true,
    song: { name: name.trim(), entries: obj.entries.map(function (e) { return { note: e.note, vel: e.vel, dur: e.dur } }) }
  }
}

/**
 * 解析导入的 JSON 文本（电脑端 MID→JSON 转换器的产物，格式见 docs/sample_song.json）。
 * 纯函数。返回 { ok, song?, errors: [] }
 */
function parseSongJSON(text) {
  if (typeof text !== 'string' || !text.trim()) return { ok: false, errors: ['内容为空'] }
  var obj
  try { obj = JSON.parse(text) } catch (e) { return { ok: false, errors: ['JSON 语法错误: ' + e.message] } }
  return validateSong(obj)
}

module.exports = {
  STORAGE_KEY: STORAGE_KEY,
  NAME_MAX: NAME_MAX,
  list: list,
  get: get,
  add: add,
  update: update,
  rename: rename,
  remove: remove,
  uniqueName: uniqueName,
  validateSong: validateSong,
  validateEntry: validateEntry,
  parseSongJSON: parseSongJSON
}
