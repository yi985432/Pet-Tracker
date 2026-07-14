// 配置页（设备管理 + 编辑）
const app = getApp()

Page({
  data: {
    // 列表模式
    editing: false,
    isAdd: false,
    editId: '',

    // 设备列表
    devices: [],

    // 表单
    form: {
      name: '',
      productId: '',
      deviceName: '',
      deviceSecret: '',
      token: '',
      remark: ''
    }
  },

  onLoad(options) {
    // 支持从其他页面通过 navigateTo 传参（非 TabBar 跳转）
    const action = options.action
    const id = options.id
    if (action === 'add') {
      this.addDevice()
    } else if (action === 'edit' && id) {
      this.editDeviceById(id)
    }
  },

  onShow() {
    if (typeof this.getTabBar === 'function' && this.getTabBar()) {
      this.getTabBar().setData({ selected: 1 })
    }
    this.loadDevices()
    const gd = getApp().globalData
    // 处理添加设备（从设备列表页通过 switchTab 跳转）
    if (gd._addDevice) {
      gd._addDevice = false
      this.addDevice()
    }
    // 处理编辑设备（从设备详情页通过 switchTab 跳转）
    if (gd._editDeviceId) {
      const id = gd._editDeviceId
      gd._editDeviceId = null
      this.editDeviceById(id)
    }
  },

  loadDevices() {
    const list = (app.globalData.devices || []).map(d => ({
      ...d,
      avatar: d.name ? d.name.slice(0, 1) : '?'
    }))
    this.setData({ devices: list })
  },

  // 添加设备（显示表单）
  addDevice() {
    this.setData({
      editing: true,
      isAdd: true,
      editId: '',
      form: {
        name: '',
        productId: '',
        deviceName: '',
        deviceSecret: '',
        token: '',
        remark: ''
      }
    })
  },

  // 编辑设备
  editDevice(e) {
    const id = e.currentTarget.dataset.id
    this.editDeviceById(id)
  },

  editDeviceById(id) {
    const device = app.globalData.devices.find(d => d.id === id)
    if (!device) return

    this.setData({
      editing: true,
      isAdd: false,
      editId: id,
      form: {
        name: device.name,
        productId: device.productId,
        deviceName: device.deviceName,
        deviceSecret: device.deviceSecret || '',
        token: device.token || '',
        remark: device.remark || ''
      }
    })
  },

  // 表单输入
  onInput(e) {
    const field = e.currentTarget.dataset.field
    const value = e.detail.value
    this.setData({
      ['form.' + field]: value
    })
  },

  // 保存设备
  saveDevice() {
    const { form, isAdd, editId } = this.data

    // 验证
    if (!form.name.trim()) {
      wx.showToast({ title: '请输入设备名称', icon: 'none' })
      return
    }
    if (!form.productId.trim()) {
      wx.showToast({ title: '请输入产品ID', icon: 'none' })
      return
    }
    if (!form.deviceName.trim()) {
      wx.showToast({ title: '请输入设备名称', icon: 'none' })
      return
    }
    if (!form.deviceSecret.trim() && !form.token.trim()) {
      wx.showToast({ title: '请填写设备密钥(DeviceSecret)', icon: 'none' })
      return
    }

    const devices = app.globalData.devices

    if (isAdd) {
      // 添加新设备
      const newDevice = {
        id: 'dev_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6),
        name: form.name.trim(),
        productId: form.productId.trim(),
        deviceName: form.deviceName.trim(),
        deviceSecret: form.deviceSecret.trim(),
        token: form.token.trim(),
        remark: form.remark.trim(),
        online: false,
        location: null
      }
      devices.push(newDevice)
    } else {
      // 编辑已有设备
      const idx = devices.findIndex(d => d.id === editId)
      if (idx > -1) {
        devices[idx] = {
          ...devices[idx],
          name: form.name.trim(),
          productId: form.productId.trim(),
          deviceName: form.deviceName.trim(),
          deviceSecret: form.deviceSecret.trim(),
          token: form.token.trim(),
          remark: form.remark.trim()
        }
      }
    }

    app.saveDevices()

    wx.showToast({ title: isAdd ? '添加成功' : '保存成功', icon: 'success' })

    this.setData({
      editing: false,
      devices: devices
    })
  },

  // 取消编辑
  cancelEdit() {
    this.setData({ editing: false })
  },

  // 删除设备
  deleteDevice(e) {
    const id = e.currentTarget.dataset.id
    wx.showModal({
      title: '确认删除',
      content: '删除后不可恢复，确定要删除吗？',
      success: (res) => {
        if (res.confirm) {
          const devices = app.globalData.devices
          const idx = devices.findIndex(d => d.id === id)
          if (idx > -1) {
            devices.splice(idx, 1)
            app.saveDevices()
            this.loadDevices()
            wx.showToast({ title: '已删除', icon: 'success' })
          }
        }
      }
    })
  }
})
