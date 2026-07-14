/**
 * OneNET REST API 封装（微信小程序版）
 *
 * 支持两种认证方式：
 * 1. 直接传入 token（从 OneNET 控制台复制）
 * 2. 传入 deviceConfig 对象，自动通过 deviceSecret 生成 token
 */

const app = getApp()

// API 基础地址
const BASE_URL = 'https://iot-api.heclouds.com'

/**
 * 获取有效的 Token：优先使用已有 token，否则通过 deviceSecret 生成
 * @param {object} device 设备配置 { productId, deviceName, token, deviceSecret }
 * @returns {Promise<string>} token
 */
async function ensureToken(device) {
  // 优先使用 deviceSecret 生成新 Token
  if (device.deviceSecret && device.deviceSecret.trim()) {
    try {
      const token = await app.generateToken(device.productId, device.deviceName, device.deviceSecret)
      if (token) return token
    } catch (err) {
      console.error('Token生成异常:', err)
    }
  }
  // 降级：使用已有 Token
  if (device.token && device.token.trim()) return device.token.trim()
  return ''
}

/**
 * 发起 OneNET API 请求
 */
function request(url, options = {}) {
  const { token } = options
  return new Promise((resolve, reject) => {
    wx.request({
      url: BASE_URL + url,
      method: options.method || 'GET',
      header: {
        'authorization': token,
        'Content-Type': 'application/json'
      },
      data: options.data || {},
      timeout: 10000,
      success: (res) => {
        if (res.statusCode === 200 && res.data) {
          resolve(res.data)
        } else {
          console.error('API错误响应:', res.statusCode, JSON.stringify(res.data))
          reject(new Error(`HTTP ${res.statusCode}: ${JSON.stringify(res.data)}`))
        }
      },
      fail: (err) => {
        reject(err)
      }
    })
  })
}

/**
 * 获取设备在线状态
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @returns {Promise<{online: boolean, status: number}>}
 */
function getDeviceStatus(productId, deviceName, token) {
  return request(`/device/detail?product_id=${productId}&device_name=${deviceName}`, { token })
    .then(data => {
      if (data.code === 0 && data.data) {
        return {
          online: data.data.status === 1,
          status: data.data.status,
          lastTime: data.data.last_time
        }
      }
      const errMsg = data.msg || ''
      // 常见 OneNET 认证错误提示
      if (errMsg.includes('authentication failed') || errMsg.includes('authorization')) {
        throw new Error('Token无效或已过期，请在「配置」页重新获取并粘贴Token')
      }
      throw new Error(errMsg || '获取设备状态失败')
    })
}

/**
 * 获取设备当前物模型属性
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @returns {Promise<Array>} 属性列表
 */
function getDeviceProperties(productId, deviceName, token) {
  return request(`/thingmodel/query-device-property?product_id=${productId}&device_name=${deviceName}`, { token })
    .then(data => {
      if (data.code === 0) {
        const list = data.data || []
        // 兼容 data 可能是对象包数组的情况
        const props = Array.isArray(list) ? list : (list.properties || [])
        return props
      }
      throw new Error(data.msg || '获取属性失败')
    })
}

/**
 * 设置设备物模型属性
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @param {object} params 要设置的属性键值对 { key: value }
 * @returns {Promise}
 */
function setDeviceProperty(productId, deviceName, token, params) {
  return request(`/thingmodel/set-device-property`, {
    token,
    method: 'POST',
    data: {
      product_id: productId,
      device_name: deviceName,
      params: params
    }
  }).then(data => {
    if (data.code === 0) {
      return data
    }
    throw new Error(data.msg || '设置属性失败')
  })
}

/**
 * 设置设备期望值属性（设备离线时设置，唤醒后自动获取）
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @param {object} params 要设置的期望值 { key: {value: val} }
 */
function setDeviceDesiredProperty(productId, deviceName, token, params) {
  return request('/thingmodel/set-device-desired-property', {
    token,
    method: 'POST',
    data: {
      product_id: productId,
      device_name: deviceName,
      params: params
    }
  }).then(data => {
    if (data.code === 0) return data
    throw new Error(data.msg || '设置期望值失败')
  })
}

/**
 * 查询设备期望值属性（ReportInterval、LocationMode 等）
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @returns {Promise<object>} 期望值对象 { ReportInterval: {value}, LocationMode: {value} }
 */
function getDeviceDesiredProperties(productId, deviceName, token) {
  return request('/thingmodel/query-device-desired-property', {
    token,
    method: 'POST',
    data: {
      product_id: productId,
      device_name: deviceName,
      params: ['ReportInterval', 'LocationMode']
    }
  }).then(data => {
    if (data.code === 0) return data.data || {}
    throw new Error(data.msg || '获取期望值失败')
  })
}

/**
 * 获取设备属性历史数据
 * @param {string} productId 产品ID
 * @param {string} deviceName 设备名称
 * @param {string} token 认证Token
 * @param {string} identifier 属性标识符
 * @param {number} startTime 开始时间（毫秒时间戳）
 * @param {number} endTime 结束时间（毫秒时间戳）
 * @param {number} limit 数量限制
 * @returns {Promise<Array>} 历史数据列表
 */
function getPropertyHistory(productId, deviceName, token, identifier, startTime, endTime, limit = 100) {
  let url = `/thingmodel/query-device-property-history?product_id=${productId}&device_name=${deviceName}&identifier=${identifier}&limit=${limit}`
  if (startTime) url += `&start_time=${startTime}`
  if (endTime) url += `&end_time=${endTime}`
  return request(url, { token })
    .then(data => {
      if (data.code === 0) {
        return data.data || { list: [] }
      }
      throw new Error(data.msg || '获取历史数据失败')
    })
}

/**
 * 解析宠物定位器的物模型属性
 * @param {Array} properties 原始属性列表
 * @returns {object} 解析后的结构化数据
 */
function parsePetTrackerProperties(properties) {
  const result = {
    location: null,
    locationType: null,
    speed: null,
    satellites: null,
    lbsCount: 0,
    wifiCount: 0,
    reportInterval: null,
    locationMode: null,
    locationModeVal: null
  }

  if (!properties || !Array.isArray(properties)) return result

  properties.forEach(item => {
    const id = item.identifier
    // OneNET 可能把对象/数组存为 JSON 字符串
    let val = item.value
    if (typeof val === 'string') {
      try { val = JSON.parse(val) } catch (e) {}
    }

    switch (id) {
      case 'GeoLocation':
        if (val && val.Longitude && val.Latitude) {
          result.location = {
            lng: parseFloat(val.Longitude),
            lat: parseFloat(val.Latitude),
            altitude: val.Altitude ? parseFloat(val.Altitude) : 0
          }
        }
        break
      case 'LocationType':
        result.locationType = val === 0 ? 'GPS' : val === 1 ? '融合定位' : '未知'
        break
      case 'Speed':
        result.speed = val !== null && val !== undefined ? parseFloat(val) : null
        break
      case 'Satellites':
        result.satellites = val !== null && val !== undefined ? parseInt(val) : null
        break
      case '$OneNET_LBS':
        result.lbsCount = Array.isArray(val) ? val.length : 0
        break
      case '$OneNET_LBS_WIFI':
        result.wifiCount = (val && val.macs) ? (val.macs.split('|').length) : 0
        break
      case 'ReportInterval':
        result.reportInterval = val !== null && val !== undefined ? parseInt(val) : null
        break
      case 'LocationMode':
        result.locationModeVal = val !== null && val !== undefined ? (String(val) === '1' || String(val) === 'OnlyLBS' ? 1 : 0) : null
        result.locationMode = result.locationModeVal === 1 ? '纯LBS' : result.locationModeVal === 0 ? '默认(GPS+LBS)' : '未知'
        break
    }
  })

  return result
}

module.exports = {
  ensureToken,
  getDeviceStatus,
  getDeviceProperties,
  setDeviceProperty,
  setDeviceDesiredProperty,
  getDeviceDesiredProperties,
  getPropertyHistory,
  parsePetTrackerProperties
}
