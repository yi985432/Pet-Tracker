// 设备列表页
const api = require('../../utils/api')
const app = getApp()

Page({
  data: {
    devices: [],
    onlineCount: 0,
    loading: false
  },

  onLoad() {
    this.loadDevices()
  },

  onShow() {
    if (typeof this.getTabBar === 'function' && this.getTabBar()) {
      this.getTabBar().setData({ selected: 0 })
    }
    this.loadDevices()
  },

  onPullDownRefresh() {
    this.refreshAll().then(() => {
      wx.stopPullDownRefresh()
    })
  },

  // 加载设备列表
  loadDevices() {
    const devices = (app.globalData.devices || []).map(d => ({
      ...d,
      avatar: d.name ? d.name.slice(0, 1) : '?'
    }))
    this.setData({ devices })
    this.updateOnlineCount()
    // 自动刷新在线状态
    this.refreshAll()
  },

  // 更新在线设备数量
  updateOnlineCount() {
    const count = this.data.devices.filter(d => d.online).length
    this.setData({ onlineCount: count })
  },

  // 刷新所有设备状态
  async refreshAll() {
    const devices = this.data.devices
    if (devices.length === 0) return

    this.setData({ loading: true })

    for (let i = 0; i < devices.length; i++) {
      const d = devices[i]
      // 检查 Token 是否为空
      if (!d.token || d.token.trim() === '') {
        console.warn(`设备 ${d.name} 未配置 Token，请在「配置」页编辑`)
        d.online = false
        d.tokenMissing = true
        continue
      }
      d.tokenMissing = false
      try {
        // 自动获取 Token（优先使用已保存的，否则通过 deviceSecret 生成）
        const token = await api.ensureToken(d)
        if (!token) {
          console.warn(`设备 ${d.name} 未配置 Token 或 DeviceSecret`)
          d.online = false
          continue
        }
        // 获取在线状态
        const status = await api.getDeviceStatus(d.productId, d.deviceName, token)
        d.online = status.online

        // 获取属性（离线也能看到最近数据）
        const props = await api.getDeviceProperties(d.productId, d.deviceName, token)
        const parsed = api.parsePetTrackerProperties(props)
        d.location = parsed.location
        d.speed = parsed.speed
        d.locationType = parsed.locationType
        d.lastUpdate = this.formatTime(Date.now())
        // 预格式化（WXML 不支持 .toFixed）
        d.locationDisplay = parsed.location
          ? parsed.location.lat.toFixed(4) + ', ' + parsed.location.lng.toFixed(4)
          : ''
        d.speedDisplay = parsed.speed !== null ? parsed.speed.toFixed(1) : '--'
      } catch (err) {
        console.error(`设备 ${d.name} 刷新失败:`, err)
        d.online = false
      }
    }

    app.saveDevices()
    this.setData({ devices })
    this.updateOnlineCount()
    this.setData({ loading: false })
  },

  // 跳转到设备详情
  goToDevice(e) {
    const id = e.currentTarget.dataset.id
    wx.navigateTo({
      url: `/pages/device/device?id=${id}`
    })
  },

  // 添加设备（配置页是 TabBar 页，需用 switchTab + 全局变量传参）
  addDevice() {
    getApp().globalData._addDevice = true
    wx.switchTab({
      url: '/pages/config/config'
    })
  },

  // 格式化时间
  formatTime(ts) {
    const d = new Date(ts)
    const h = d.getHours().toString().padStart(2, '0')
    const m = d.getMinutes().toString().padStart(2, '0')
    const s = d.getSeconds().toString().padStart(2, '0')
    return `${h}:${m}:${s}`
  }
})
