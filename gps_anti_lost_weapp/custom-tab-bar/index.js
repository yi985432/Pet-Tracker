// 自定义悬浮底栏（支持点击和滑动切换）
Component({
  data: {
    selected: 0,
    list: [
      { pagePath: '/pages/index/index', text: '设备', iconPath: '/images/device.png', selectedIconPath: '/images/device_active.png' },
      { pagePath: '/pages/config/config', text: '配置', iconPath: '/images/config.png', selectedIconPath: '/images/config_active.png' },
      { pagePath: '/pages/about/about', text: '关于', iconPath: '/images/about.png', selectedIconPath: '/images/about_active.png' }
    ],
    startX: 0
  },
  methods: {
    switchTab(e) {
      const idx = e.currentTarget.dataset.index
      this.goTab(idx)
    },
    goTab(idx) {
      if (idx === this.data.selected) return
      const item = this.data.list[idx]
      if (item) wx.switchTab({ url: item.pagePath })
    },
    onTouchStart(e) {
      this.data.startX = e.touches[0].clientX
    },
    onTouchEnd(e) {
      const dx = e.changedTouches[0].clientX - this.data.startX
      if (Math.abs(dx) < 60) return
      const len = this.data.list.length
      const next = dx < 0
        ? Math.min(this.data.selected + 1, len - 1)
        : Math.max(this.data.selected - 1, 0)
      this.goTab(next)
    }
  }
})
