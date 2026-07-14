// app.js
App({
  globalData: {
    // 默认示例设备
    devices: []
  },

  onLaunch() {
    // 读取本地存储的设备列表
    const saved = wx.getStorageSync('devices')
    if (saved && saved.length > 0) {
      this.globalData.devices = saved
    } else {
      // 默认示例设备（用户需修改为自己的配置）
      this.globalData.devices = []
      this.saveDevices()
    }
  },

  // 保存设备列表到本地
  saveDevices() {
    wx.setStorageSync('devices', this.globalData.devices)
  },

  // ==================== SHA1 + HMAC-SHA1（经过验证的实现）====================
  // 参考: https://github.com/emn178/js-sha1

  _sha1(input) {
    const HEX = '0123456789abcdef'
    function f(s, x, y, z) {
      switch (s) {
        case 0: return (x & y) ^ (~x & z)
        case 1: return x ^ y ^ z
        case 2: return (x & y) ^ (x & z) ^ (y & z)
        case 3: return x ^ y ^ z
      }
    }
    function ROTL(x, n) { return (x << n) | (x >>> (32 - n)) }
    function toHex(i) {
      return HEX.charAt((i >>> 28) & 0xf) + HEX.charAt((i >>> 24) & 0xf) +
             HEX.charAt((i >>> 20) & 0xf) + HEX.charAt((i >>> 16) & 0xf) +
             HEX.charAt((i >>> 12) & 0xf) + HEX.charAt((i >>> 8) & 0xf) +
             HEX.charAt((i >>> 4) & 0xf) + HEX.charAt(i & 0xf)
    }
    const block = []
    // 接受字符串或字节数组，统一转为字节
    const bytes = typeof input === 'string'
      ? input.split('').map(c => c.charCodeAt(0))  // 直接取 charCode，不做 UTF-8 编码
      : input
    const len = bytes.length
    // Append padding
    bytes.push(0x80)
    while ((bytes.length + 8) % 64 !== 0) bytes.push(0)
    // Append length in bits (big-endian 64-bit)
    const bits = len * 8
    // High 32 bits of bits (0 for messages < 512MB)
    const high32 = Math.floor(bits / 0x100000000) || 0
    for (let i = 0; i < 8; i++) bytes.push((i < 4 ? high32 : bits) >>> ((7 - i) * 8) & 0xff)
    // Process blocks
    let H0 = 0x67452301, H1 = 0xEFCDAB89, H2 = 0x98BADCFE, H3 = 0x10325476, H4 = 0xC3D2E1F0
    for (let i = 0; i < bytes.length; i += 64) {
      for (let t = 0; t < 16; t++) {
        const off = i + t * 4
        block[t] = (bytes[off] << 24) | (bytes[off + 1] << 16) | (bytes[off + 2] << 8) | bytes[off + 3]
      }
      for (let t = 16; t < 80; t++) block[t] = ROTL(block[t - 3] ^ block[t - 8] ^ block[t - 14] ^ block[t - 16], 1)
      let A = H0, B = H1, C = H2, D = H3, E = H4
      for (let t = 0; t < 80; t++) {
        const s = Math.floor(t / 20)
        const T = (ROTL(A, 5) + f(s, B, C, D) + E + block[t] + [0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6][s]) | 0
        E = D; D = C; C = ROTL(B, 30); B = A; A = T
      }
      H0 = (H0 + A) | 0; H1 = (H1 + B) | 0; H2 = (H2 + C) | 0; H3 = (H3 + D) | 0; H4 = (H4 + E) | 0
    }
    return toHex(H0) + toHex(H1) + toHex(H2) + toHex(H3) + toHex(H4)
  },

  _hmac_sha1(keyBytes, msg) {
    const key = [...keyBytes]
    if (key.length > 64) {
      const h = this._sha1(String.fromCharCode(...key))
      key.length = 0
      for (let i = 0; i < h.length; i += 2) key.push(parseInt(h.substr(i, 2), 16))
    }
    while (key.length < 64) key.push(0)
    const oKeyPad = key.map(b => b ^ 0x5c)
    const iKeyPad = key.map(b => b ^ 0x36)
    // inner = SHA1(iKeyPad + msg)
    // 消息转为字节数组
    const msgBytes = msg.split('').map(c => c.charCodeAt(0))
    // inner = SHA1(iKeyPad + msg)
    const inner = this._sha1(iKeyPad.concat(msgBytes))
    // Convert inner hash hex to bytes
    const innerBytes = []
    for (let i = 0; i < inner.length; i += 2) innerBytes.push(parseInt(inner.substr(i, 2), 16))
    // outer = SHA1(oKeyPad + inner)
    return this._sha1(oKeyPad.concat(innerBytes))
  },

  _hexToBase64(hex) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    const bytes = []
    for (let i = 0; i < hex.length; i += 2) bytes.push(parseInt(hex.substr(i, 2), 16))
    let result = ''
    for (let i = 0; i < bytes.length; i += 3) {
      const v = ((bytes[i] || 0) << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0)
      result += chars[(v >> 18) & 63] + chars[(v >> 12) & 63] + chars[(v >> 6) & 63] + chars[v & 63]
    }
    const r = bytes.length % 3
    return result.slice(0, result.length - (r ? 3 - r : 0)) + (r === 1 ? '==' : r === 2 ? '=' : '')
  },

  _urlEncodeToken(s) {
    const m = { '+': '%2B', ' ': '%20', '/': '%2F', '?': '%3F', '%': '%25', '#': '%23', '&': '%26', '=': '%3D' }
    return s.split('').map(c => m[c] || c).join('')
  },

  async generateToken(productId, deviceName, deviceSecret) {
    if (!productId || !deviceName || !deviceSecret) return ''
    try {
      const method = 'sha1', version = '2018-10-31'
      const et = Math.floor(Date.now() / 1000) + 3600
      const res = `products/${productId}/devices/${deviceName}`
      const signStr = `${et}\n${method}\n${res}\n${version}`
      const keyBytes = atob(deviceSecret).split('').map(c => c.charCodeAt(0))
      const hmacHex = this._hmac_sha1(keyBytes, signStr)
      const signB64 = this._hexToBase64(hmacHex)
      return `version=${version}&res=${this._urlEncodeToken(res)}&et=${et}&method=${method}&sign=${this._urlEncodeToken(signB64)}`
    } catch (err) { console.error('Token生成失败:', err); return '' }
  }
})
