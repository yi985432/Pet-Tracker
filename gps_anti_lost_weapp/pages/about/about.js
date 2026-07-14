// 关于页
Page({
  onShow() {
    if (typeof this.getTabBar === 'function' && this.getTabBar()) {
      this.getTabBar().setData({ selected: 2 })
    }
  },

  // 复制仓库地址
  copyRepo() {
    wx.setClipboardData({
      data: 'https://github.com/yi985432/Pet-Tracker',
      success: () => {
        wx.showToast({ title: '仓库地址已复制', icon: 'success' })
      }
    })
  }
})
