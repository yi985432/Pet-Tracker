// 历史数据页
const api = require('../../utils/api')
const app = getApp()

Page({
  data: {
    productId: '',
    deviceName: '',
    deviceId: '',

    // 可选属性列表
    propertyList: [
      { id: 'GeoLocation', name: '位置轨迹', icon: '🗺️', unit: '', color: '#4f46e5' },
      { id: 'Speed', name: '速度', icon: '🚀', unit: 'km/h', color: '#3b82f6' },
      { id: 'Satellites', name: '卫星数', icon: '🛰️', unit: '颗', color: '#22c55e' }
    ],

    // 时间范围
    timeRanges: [
      { label: '1小时', value: 1 },
      { label: '6小时', value: 6 },
      { label: '24小时', value: 24 },
      { label: '7天', value: 168 }
    ],

    selectedProp: 'Speed',
    selectedPropName: '速度',
    selectedUnit: 'km/h',
    selectedTime: 24,

    dataList: [],
    locationHistory: [],
    trackMarkers: [],
    trackPolyline: [],
    loading: true,
    avgValue: '--'
  },

  onLoad(options) {
    this.setData({
      productId: options.productId,
      deviceName: options.deviceName,
      deviceId: options.deviceId || ''
    })
    this.loadHistory()
  },

  // 获取有效的 Token
  async _getToken() {
    const { deviceId, productId, deviceName } = this.data
    // 如果有 deviceId，从全局设备配置获取
    if (deviceId) {
      const dev = app.globalData.devices.find(d => d.id === deviceId)
      if (dev) return await api.ensureToken(dev)
    }
    return ''
  },

  // 选择属性
  selectProperty(e) {
    const id = e.currentTarget.dataset.id
    const prop = this.data.propertyList.find(p => p.id === id)
    if (prop) {
      this.setData({
        selectedProp: id,
        selectedPropName: prop.name,
        selectedUnit: prop.unit
      })
      this.loadHistory()
    }
  },

  // 选择时间范围
  selectTime(e) {
    const value = parseInt(e.currentTarget.dataset.value)
    this.setData({ selectedTime: value })
    this.loadHistory()
  },

  // 加载历史数据
  async loadHistory() {
    const { productId, deviceName, selectedProp, selectedTime } = this.data
    if (!productId || !deviceName) return

    const token = await this._getToken()
    if (!token) {
      wx.showToast({ title: '请先在配置页填写设备密钥', icon: 'none' })
      return
    }

    this.setData({ loading: true, dataList: [], locationHistory: [] })

    try {
      const endTime = Date.now()
      const startTime = endTime - selectedTime * 60 * 60 * 1000

      const result = await api.getPropertyHistory(
        productId, deviceName, token,
        selectedProp, startTime, endTime, 200
      )

      const list = result.list || []
      // 按时间正序排列
      list.reverse()

      // 处理位置轨迹（特殊渲染）
      if (selectedProp === 'GeoLocation') {
        const locations = list.map(item => {
          // OneNET 可能把对象存为 JSON 字符串
          let v = item.value
          if (typeof v === 'string') try { v = JSON.parse(v) } catch (e) {}
          v = v || {}
          if (v.Longitude && v.Latitude) {
            const d = new Date(parseInt(item.time))
            return {
              lng: v.Longitude,
              lat: v.Latitude,
              time: `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`
            }
          }
          return null
        }).filter(Boolean)
        // 位置点也限制最多 50 个
        if (locations.length > 50) {
          const step = Math.floor(locations.length / 50)
          const sampled = []
          for (let i = 0; i < locations.length; i += step) sampled.push(locations[i])
          if (sampled[sampled.length - 1] !== locations[locations.length - 1]) sampled.push(locations[locations.length - 1])
          locations.length = 0
          locations.push(...sampled)
        }
        // 生成地图标记（首尾显示标签，中间只留点）
        const markers = locations.map((loc, i) => ({
          id: i,
          longitude: loc.lng,
          latitude: loc.lat,
          width: 24,
          height: 24,
          callout: i === 0 ? { content: '🟢 ' + loc.time, fontSize: 10, borderRadius: 6, padding: 4, display: 'ALWAYS' }
            : i === locations.length - 1 ? { content: '🔴 ' + loc.time, fontSize: 10, borderRadius: 6, padding: 4, display: 'ALWAYS' }
            : {}
        }))
        // 轨迹连线
        const polyline = [{
          points: locations.map(l => ({ longitude: l.lng, latitude: l.lat })),
          color: '#4f46e5',
          width: 4,
          dottedLine: false,
          arrowLine: true
        }]
        this.setData({
          locationHistory: locations,
          trackMarkers: markers,
          trackPolyline: polyline,
          dataList: [],
          loading: false
        })
        return
      }

      // 格式化数据（数值型属性）
      let dataList = list.map(item => {
        const d = new Date(parseInt(item.time))
        const h = d.getHours().toString().padStart(2, '0')
        const m = d.getMinutes().toString().padStart(2, '0')
        return {
          time: `${h}:${m}`,
          value: item.value !== null && item.value !== undefined ? item.value : '-'
        }
      })

      // 数据太多时采样显示，最多 50 个点
      const MAX_POINTS = 50
      if (dataList.length > MAX_POINTS) {
        const step = Math.floor(dataList.length / MAX_POINTS)
        const sampled = []
        for (let i = 0; i < dataList.length; i += step) {
          sampled.push(dataList[i])
        }
        // 确保最后一个点包含在内
        if (sampled[sampled.length - 1] !== dataList[dataList.length - 1]) {
          sampled.push(dataList[dataList.length - 1])
        }
        dataList = sampled
      }

      // 计算平均值
      const nums = dataList.map(d => parseFloat(d.value)).filter(v => !isNaN(v))
      const avgValue = nums.length > 0 ? (nums.reduce((a, b) => a + b, 0) / nums.length).toFixed(1) : '--'

      this.setData({ dataList, locationHistory: [], avgValue })

      // 绘制图表（绘制完成后关闭加载）
      this.drawChart(dataList, () => {
        this.setData({ loading: false })
      })
    } catch (err) {
      console.error('加载历史数据失败:', err)
      this.setData({ dataList: [], loading: false })
    }
  },

  // 绘制折线图
  drawChart(dataList, callback) {
    const query = wx.createSelectorQuery()
    query.select('#historyChart')
      .fields({ node: true, size: true })
      .exec((res) => {
        if (!res || !res[0]) {
          if (callback) callback()
          return
        }
        const canvas = res[0].node
        const ctx = canvas.getContext('2d')
        const width = res[0].width
        const height = res[0].height
        const dpr = wx.getWindowInfo().pixelRatio

        canvas.width = width * dpr
        canvas.height = height * dpr
        ctx.scale(dpr, dpr)

        this.renderChart(ctx, width, height, dataList)
        if (callback) callback()
      })
  },

  // 渲染图表
  renderChart(ctx, width, height, dataList) {
    const padding = { top: 30, right: 20, bottom: 40, left: 50 }
    const chartW = width - padding.left - padding.right
    const chartH = height - padding.top - padding.bottom

    // 清空
    ctx.clearRect(0, 0, width, height)

    if (!dataList || dataList.length === 0) {
      ctx.fillStyle = '#9ca3af'
      ctx.font = '14px sans-serif'
      ctx.textAlign = 'center'
      ctx.fillText('暂无数据', width / 2, height / 2)
      return
    }

    // 提取数值
    const values = dataList.map(d => parseFloat(d.value)).filter(v => !isNaN(v))
    if (values.length === 0) return

    const minVal = Math.min(...values)
    const maxVal = Math.max(...values)
    const range = maxVal - minVal || 1
    const color = this.getPropColor()

    // 绘制网格线
    ctx.strokeStyle = '#f0f0f0'
    ctx.lineWidth = 1
    for (let i = 0; i <= 4; i++) {
      const y = padding.top + (chartH / 4) * i
      ctx.beginPath()
      ctx.moveTo(padding.left, y)
      ctx.lineTo(width - padding.right, y)
      ctx.stroke()
    }

    // 绘制数据线
    const stepX = chartW / Math.max(values.length - 1, 1)
    ctx.strokeStyle = color
    ctx.lineWidth = 2
    ctx.lineJoin = 'round'
    ctx.beginPath()

    values.forEach((v, i) => {
      const x = padding.left + i * stepX
      const y = padding.top + chartH - ((v - minVal) / range) * chartH
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    })
    ctx.stroke()

    // 绘制面积渐变
    const lastIdx = values.length - 1
    const lastX = padding.left + lastIdx * stepX
    ctx.lineTo(lastX, padding.top + chartH)
    ctx.lineTo(padding.left, padding.top + chartH)
    ctx.closePath()

    const gradient = ctx.createLinearGradient(0, padding.top, 0, padding.top + chartH)
    gradient.addColorStop(0, color + '40')
    gradient.addColorStop(1, color + '05')
    ctx.fillStyle = gradient
    ctx.fill()

    // 绘制数据点（最多显示20个点避免拥挤）
    const pointStep = Math.max(1, Math.floor(values.length / 20))
    values.forEach((v, i) => {
      if (i % pointStep !== 0 && i !== 0 && i !== lastIdx) return
      const x = padding.left + i * stepX
      const y = padding.top + chartH - ((v - minVal) / range) * chartH
      ctx.beginPath()
      ctx.arc(x, y, 3, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.fill()
    })

    // Y轴标签
    ctx.fillStyle = '#9ca3af'
    ctx.font = '10px sans-serif'
    ctx.textAlign = 'right'
    for (let i = 0; i <= 4; i++) {
      const val = maxVal - (range / 4) * i
      const y = padding.top + (chartH / 4) * i
      ctx.fillText(val.toFixed(1), padding.left - 8, y + 4)
    }

    // X轴标签（最多5个，避免重叠）
    const maxLabels = 5
    const labelStep = Math.max(1, Math.floor(values.length / maxLabels))
    ctx.textAlign = 'center'
    ctx.fillStyle = '#9ca3af'
    ctx.font = '10px sans-serif'
    const shownLabels = new Set()
    for (let i = 0; i < dataList.length; i += labelStep) {
      if (shownLabels.size >= maxLabels) break
      const x = padding.left + i * stepX
      ctx.fillText(dataList[i].time, x, height - padding.bottom + 16)
      shownLabels.add(i)
    }
    // 始终显示最后一个
    if (!shownLabels.has(lastIdx) && lastIdx >= 0) {
      const x = padding.left + lastIdx * stepX
      ctx.fillText(dataList[lastIdx].time, x, height - padding.bottom + 16)
    }
  },

  getPropColor() {
    const prop = this.data.propertyList.find(p => p.id === this.data.selectedProp)
    return prop ? prop.color : '#4f46e5'
  }
})
