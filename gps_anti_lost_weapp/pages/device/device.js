// 设备详情页
const api = require('../../utils/api')
const app = getApp()

Page({
  data: {
    // 设备信息
    deviceId: '',
    deviceName: '',
    productId: '',
    token: '',
    online: false,

    // 属性
    location: null,
    locationType: '',
    locationMode: '',
    locationModeValue: 0,
    speed: null,
    satellites: null,
    lbsCount: 0,
    wifiCount: 0,
    reportInterval: null,

    // 地图
    markers: [],

    // 控制
    intervalOptions: ['1分钟', '5分钟', '10分钟', '15分钟', '30分钟', '60分钟'],
    loading: true,
    satellite: false
  },

  onLoad(options) {
    const deviceId = options.id
    if (!deviceId) {
      wx.showToast({ title: '参数错误', icon: 'none' })
      return
    }

    this.setData({ deviceId })
    this.loadDevice(deviceId)
  },

  onShow() {
    if (this.data.deviceId) {
      this.loadDevice(this.data.deviceId)
    }
  },

  // 加载设备数据
  loadDevice(deviceId) {
    const devices = app.globalData.devices
    const device = devices.find(d => d.id === deviceId)
    if (!device) {
      wx.showToast({ title: '设备不存在', icon: 'none' })
      return
    }

    this.setData({
      deviceName: device.deviceName,
      deviceAvatar: device.deviceName.slice(0, 1),
      productId: device.productId,
      token: device.token
    })

    this.refreshDevice()
  },

  // 刷新设备数据
  async refreshDevice() {
    this.setData({ loading: true })
    const { productId, deviceName, deviceId } = this.data

    // 从全局获取完整设备配置（含 deviceSecret）
    const devConfig = app.globalData.devices.find(d => d.id === deviceId) || {}
    const token = await api.ensureToken(devConfig)
    if (!token) {
      wx.showToast({ title: '请在「配置」页填写设备密钥', icon: 'none', duration: 3000 })
      this.setData({ loading: false })
      return
    }

    try {
      // 获取在线状态
      const status = await api.getDeviceStatus(productId, deviceName, token)
      this.setData({ online: status.online })

      // 无论在线与否，都获取最新物模型属性（设备离线也能看到最近数据）
      const props = await api.getDeviceProperties(productId, deviceName, token)
      const parsed = api.parsePetTrackerProperties(props)

      // 获取期望值属性（ReportInterval、LocationMode 不上报，只能通过期望值 API 查）
      let desiredInterval = null, desiredMode = null
      try {
        const desired = await api.getDeviceDesiredProperties(productId, deviceName, token)
        if (desired.ReportInterval && desired.ReportInterval.value) {
          desiredInterval = parseInt(desired.ReportInterval.value)
        }
        if (desired.LocationMode && desired.LocationMode.value !== undefined) {
          const v = String(desired.LocationMode.value)
          desiredMode = (v === '1' || v === 'OnlyLBS') ? 1 : 0
        }
      } catch (e) { /* 期望值查询可选，失败不影响主体 */ }

      // 取实际值：优先已上报，其次期望值，最后默认
      const reportInterval = parsed.reportInterval || desiredInterval
      const locationModeVal = desiredMode !== null ? desiredMode : (parsed.locationModeVal)
      const locationModeTxt = locationModeVal === 0 ? '默认(GPS+LBS)' : locationModeVal === 1 ? '纯LBS' : (parsed.locationMode || '默认(GPS+LBS)')

      // 预格式化数值（WXML 不支持 .toFixed() 等方法调用）
      const fmtSpeed = parsed.speed !== null ? parsed.speed.toFixed(1) : '--'
      const fmtInterval = reportInterval !== null ? (reportInterval / 60000).toFixed(0) : '--'
      const fmtIntervalDesc = reportInterval !== null ? (reportInterval / 60000).toFixed(0) + ' 分钟' : '30 分钟'
      const fmtLng = parsed.location ? parsed.location.lng.toFixed(6) : ''
      const fmtLat = parsed.location ? parsed.location.lat.toFixed(6) : ''

      const updateData = {
        location: parsed.location,
        locationType: parsed.locationType,
        speed: parsed.speed,
        speedFormatted: fmtSpeed,
        satellites: parsed.satellites,
        lbsCount: parsed.lbsCount,
        wifiCount: parsed.wifiCount,
        reportInterval: reportInterval,
        reportIntervalFormatted: fmtInterval,
        reportIntervalDesc: fmtIntervalDesc,
        locationLngFormatted: fmtLng,
        locationLatFormatted: fmtLat,
        locationMode: locationModeTxt,
        locationModeValue: locationModeVal !== null ? locationModeVal : 0
      }

        // 设置地图标记
        if (parsed.location) {
          updateData.markers = [{
            id: 0,
            longitude: parsed.location.lng,
            latitude: parsed.location.lat,
            width: 30,
            height: 30,
            callout: {
              content: deviceName,
              fontSize: 12,
              borderRadius: 8,
              padding: 8,
              display: 'ALWAYS'
            }
          }]
        }

        this.setData(updateData)
    } catch (err) {
      console.error('刷新设备数据失败:', err)
      wx.showToast({ title: '刷新失败', icon: 'none' })
    }

    this.setData({ loading: false })
  },

  // 获取当前设备的 token
  async _getToken() {
    const devConfig = app.globalData.devices.find(d => d.id === this.data.deviceId) || {}
    return await api.ensureToken(devConfig)
  },

  // 设置定位模式（保存为期望值，设备唤醒后自动获取）
  async setLocationMode(e) {
    const mode = parseInt(e.currentTarget.dataset.mode)
    const modeVal = mode  // 枚举传整数
    const { productId, deviceName } = this.data
    const token = await this._getToken()
    if (!token) return

    try {
      await api.setDeviceDesiredProperty(productId, deviceName, token, {
        LocationMode: modeVal
      })
      wx.showToast({ title: '切换成功', icon: 'success' })
      this.setData({ locationModeValue: mode })
      this.refreshDevice()
    } catch (err) {
      wx.showToast({ title: '切换失败: ' + err.message, icon: 'none' })
    }
  },

  // 设置上报间隔（保存为期望值，设备唤醒后自动获取）
  async setInterval(e) {
    const index = e.detail.value
    const intervals = [60000, 300000, 600000, 900000, 1800000, 3600000]
    const intervalMs = intervals[index]
    const { productId, deviceName } = this.data
    const token = await this._getToken()
    if (!token) return

    try {
      await api.setDeviceDesiredProperty(productId, deviceName, token, {
        ReportInterval: intervalMs
      })
      wx.showToast({ title: '设置成功', icon: 'success' })
      this.refreshDevice()
    } catch (err) {
      wx.showToast({ title: '设置失败: ' + err.message, icon: 'none' })
    }
  },

  // 查看历史数据
  async viewHistory() {
    const token = await this._getToken()
    if (!token) return
    wx.navigateTo({
      url: `/pages/history/history?deviceId=${this.data.deviceId}&productId=${this.data.productId}&deviceName=${this.data.deviceName}`
    })
  },

  // 编辑设备（配置页是 TabBar 页，需用 switchTab + 全局变量传参）
  editDevice() {
    getApp().globalData._editDeviceId = this.data.deviceId
    wx.switchTab({
      url: '/pages/config/config'
    })
  },

  // 删除设备
  deleteDevice() {
    wx.showModal({
      title: '确认删除',
      content: `确定要删除设备 "${this.data.deviceName}" 吗？`,
      success: (res) => {
        if (res.confirm) {
          const devices = app.globalData.devices
          const idx = devices.findIndex(d => d.id === this.data.deviceId)
          if (idx > -1) {
            devices.splice(idx, 1)
            app.saveDevices()
            wx.showToast({ title: '已删除', icon: 'success' })
            wx.navigateBack()
          }
        }
      }
    })
  },

  // 切换卫星视图
  toggleSatellite() {
    this.setData({ satellite: !this.data.satellite })
  },

  // 复制坐标
  copyCoords() {
    const { locationLatFormatted, locationLngFormatted } = this.data
    wx.setClipboardData({
      data: `${locationLatFormatted}, ${locationLngFormatted}`,
      success: () => wx.showToast({ title: '坐标已复制', icon: 'success' })
    })
  },

  // 打开外部地图导航
  openMap() {
    const { location } = this.data
    if (!location) return
    wx.openLocation({
      latitude: location.lat,
      longitude: location.lng,
      scale: 15,
      name: this.data.deviceName
    })
  }
})
