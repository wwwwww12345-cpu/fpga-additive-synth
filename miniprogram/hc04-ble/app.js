const sender = require('./utils/sender.js')
const proto = require('./utils/protocol.js')

App({
  onLaunch() {},

  // 切后台：尽力停掉灯带指引（0x95）。
  // 首页可见时页面 onHide 也会发一次（两条 0x95 幂等，重复无害）；
  // 但如果当时正停在「琴键」页（首页不可见），这里是唯一的机会——
  // 不静默丢掉的话，手机锁屏后灯带会一直挂着最后一个目标音黄灯。
  // 失败一律忽略：后台里不能弹 UI，也不值得为它弹。
  onHide() {
    try {
      sender.send(proto.encodeGuideStop(), null).catch(() => {})
    } catch (e) { /* 未连接 / 队列未就绪：忽略 */ }
  },

  globalData: {}
})
