/**
 * 曲谱库管理页
 *  三种视图（wx:if 切换）：
 *    list   — 曲谱列表（编辑 / 重命名 / 删除）
 *    edit   — 列表式编辑器（名称 + 逐条 note/vel/dur + 增删条目）
 *    import — JSON 文本导入（严格校验，格式见 docs/sample_song.json）
 *  条目上限 512（FPGA 曲谱 RAM），重名：新建/导入自动加后缀，重命名则拒绝。
 */
const songs = require('../../utils/songs.js')
const proto = require('../../utils/protocol.js')

const EMPTY_ENTRY = { note: 60, vel: 96, dur: 50 }

Page({
  data: {
    mode: 'list',
    // 列表
    list: [],
    // 编辑器
    editId: null,            // null = 新建
    editName: '',
    entries: [],
    eNote: EMPTY_ENTRY.note, // 新增条目输入
    eVel: EMPTY_ENTRY.vel,
    eDur: EMPTY_ENTRY.dur,
    // 导入
    importText: '',
    importErrors: null,
    importOk: null
  },

  onShow() { this.refresh() },

  refresh() {
    this.setData({ list: songs.list().map(s => ({
      id: s.id, name: s.name, count: s.entries.length
    })) })
  },

  // ---------------- 视图切换 ----------------

  toImport() { this.setData({ mode: 'import', importErrors: null, importOk: null }) },
  toNew() {
    this.setData({
      mode: 'edit', editId: null, editName: '', entries: [],
      eNote: EMPTY_ENTRY.note, eVel: EMPTY_ENTRY.vel, eDur: EMPTY_ENTRY.dur
    })
  },
  toList() { this.setData({ mode: 'list' }); this.refresh() },

  // ---------------- 列表操作 ----------------

  onEdit(e) {
    const s = songs.get(e.currentTarget.dataset.id)
    if (!s) return
    this.setData({ mode: 'edit', editId: s.id, editName: s.name, entries: s.entries.slice() })
  },

  onRename(e) {
    const id = e.currentTarget.dataset.id
    const s = songs.get(id)
    if (!s) return
    wx.showModal({
      title: '重命名',
      editable: true,
      placeholderText: s.name,
      success: res => {
        if (!res.confirm || !res.content || !res.content.trim()) return
        try {
          songs.rename(id, res.content.trim())
          this.refresh()
        } catch (err) {
          wx.showModal({ title: '重命名失败', content: err.message, showCancel: false })
        }
      }
    })
  },

  onDelete(e) {
    const id = e.currentTarget.dataset.id
    const s = songs.get(id)
    if (!s) return
    wx.showModal({
      title: '删除曲谱',
      content: `确定删除「${s.name}」（${s.entries.length} 条）？不可恢复。`,
      success: res => {
        if (!res.confirm) return
        songs.remove(id)
        this.refresh()
      }
    })
  },

  // ---------------- 编辑器 ----------------

  onNameInput(e) { this.setData({ editName: e.detail.value }) },
  onNoteInput(e) { this.setData({ eNote: e.detail.value }) },
  onVelInput(e)  { this.setData({ eVel: e.detail.value }) },
  onDurInput(e)  { this.setData({ eDur: e.detail.value }) },

  onAddEntry() {
    const entry = {
      note: parseInt(this.data.eNote, 10),
      vel: parseInt(this.data.eVel, 10),
      dur: parseInt(this.data.eDur, 10)
    }
    const errs = []
    songs.validateEntry(entry, this.data.entries.length, errs)
    if (errs.length) {
      wx.showModal({ title: '条目无效', content: errs.join('\n'), showCancel: false })
      return
    }
    if (this.data.entries.length >= proto.MAX_ENTRIES) {
      wx.showModal({
        title: '条目数已达上限',
        content: '上限 ' + proto.MAX_ENTRIES + ' 条（FPGA 曲谱 RAM 容量），无法继续添加。',
        showCancel: false
      })
      return
    }
    this.setData({ entries: this.data.entries.concat(entry) })
  },

  onDelEntry(e) {
    const i = Number(e.currentTarget.dataset.index)
    const entries = this.data.entries.slice()
    entries.splice(i, 1)
    this.setData({ entries })
  },

  onSave() {
    const name = (this.data.editName || '').trim()
    const result = songs.validateSong({ name, entries: this.data.entries })
    if (!result.ok) {
      wx.showModal({ title: '保存失败', content: result.errors.join('\n'), showCancel: false })
      return
    }
    try {
      if (this.data.editId) {
        songs.update(this.data.editId, { name: name, entries: this.data.entries })
        wx.showToast({ title: '已保存', icon: 'success' })
      } else {
        const saved = songs.add(result.song)   // 重名自动加后缀
        if (saved.name !== name) wx.showToast({ title: '已存为「' + saved.name + '」', icon: 'none' })
        else wx.showToast({ title: '已保存', icon: 'success' })
      }
      this.toList()
    } catch (err) {
      wx.showModal({ title: '保存失败', content: err.message, showCancel: false })
    }
  },

  // ---------------- JSON 导入 ----------------

  onImportInput(e) { this.setData({ importText: e.detail.value }) },

  onImport() {
    const result = songs.parseSongJSON(this.data.importText)
    if (!result.ok) {
      this.setData({ importErrors: result.errors, importOk: null })
      return
    }
    const saved = songs.add(result.song)   // 重名自动加后缀
    const renamed = saved.name !== result.song.name
    this.setData({
      importErrors: null,
      importOk: '已导入「' + saved.name + '」（' + result.song.entries.length + ' 条）'
        + (renamed ? ' — 与现有曲谱重名，自动改名' : ''),
      importText: ''
    })
    this.refresh()
  }
})
