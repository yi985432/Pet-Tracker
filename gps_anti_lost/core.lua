--[[
@module  core
@summary 4G GPS/北斗宠物定位器 核心功能实现
@version 1.0.0
@date    2026.07.13
@author  Jun (AI协助: GitHub Copilot)
@usage
实现4G GPS/北斗宠物定位器的核心功能，包括网络连接、定位、OneNET MQTT数据上传和低功耗管理
]]

local config = require("config")
local exgnss = require("exgnss")
local iotauth = require("iotauth")
local httpplus = require("httpplus")  -- 融合定位(HTTP API)使用

-- 坐标转换相关常量定义
local x_PI = 3.14159265358979324 * 3000.0 / 180.0
local PI = 3.1415926535897932384626
local a = 6378245.0
local ee = 0.00669342162296594323

-- 核心功能模块
local core = {}

-- ============================ GSensor运动检测模块 ============================

-- GSensor状态
local gsensor_motion_detected = false
local gsensor_initialized = false
local gsensor_int_pin = gpio.WAKEUP2  -- DA221中断引脚
-- 最近一次静止的时间戳
local last_motion_time = 0

-- GSensor中断处理
local function gsensor_irq_handler()
    gsensor_motion_detected = true
    last_motion_time = mcu.ticks()
end

-- 初始化GSensor（DA221加速度传感器，仅Air780EGP/EGG支持）
function core.init_gsensor()
    log.info("GSENSOR", "初始化DA221加速度传感器")
    local exvib = require("exvib")
    if not exvib then
        log.warn("GSENSOR", "exvib库加载失败，跳过GSensor初始化")
        return false
    end

    -- 打开运动检测模式（模式2：运动检测，加速度量程4g）
    exvib.open(2)
    log.info("GSENSOR", "运动检测模式已开启")

    -- 设置GPIO中断（WAKEUP2，下降沿触发）
    gpio.debounce(gsensor_int_pin, 50)
    gpio.setup(gsensor_int_pin, gsensor_irq_handler, nil, gpio.FALLING)

    gsensor_initialized = true
    gsensor_motion_detected = false
    last_motion_time = 0  -- 0表示未检测到运动，设备初始为静止状态
    log.info("GSENSOR", "DA221初始化完成")
    return true
end

-- 判断设备是否在运动中
-- 如果最近30秒内有GSensor中断触发，认为在运动
-- 否则认为静止
function core.is_moving()
    if not gsensor_initialized then
        -- GSensor未初始化，默认认为在运动（不限制定位）
        return true
    end

    -- last_motion_time == 0 表示自开机以来未检测到任何运动
    -- 此时认为设备静止
    if last_motion_time == 0 then
        return false
    end

    -- 检查30秒内是否有运动中断
    local now = mcu.ticks()
    local elapsed = now - last_motion_time

    -- 30秒 = 30000ms
    if elapsed < 30000 then
        return true
    end

    return false
end

-- 获取最后运动时间
function core.get_last_motion_time()
    return last_motion_time
end

-- ============================ 网络连接模块 ============================

-- 初始化移动网络
function core.init_network()
    log.info("NETWORK", "初始化移动网络")

    -- 设置SIM卡
    mobile.simid(config.NETWORK.SIM_ID, config.NETWORK.AUTO_SELECT_SIM)

    -- 设置APN
    mobile.apn(0, 1, config.NETWORK.APN, config.NETWORK.APN_USER, config.NETWORK.APN_PWD, nil, 0)

    -- 开启自动恢复功能
    mobile.setAuto(10000, 30000, 5)

    log.info("NETWORK", "移动网络初始化完成")
end

-- 检查网络连接状态
function core.check_network()
    log.info("NETWORK", "检查网络连接状态")

    -- 等待网络连接
    for i=1, config.NETWORK.RETRY_COUNT do
        if socket.adapter(socket.dft()) then
            log.info("NETWORK", "网络连接正常")
            -- 获取并打印本机IP地址
            local local_ip = socket.localIP()
            if local_ip then
                log.info("NETWORK", "本机IPv4: " .. local_ip)
            end
            -- 获取网关和子网掩码
            local ip, netmask, gateway = socket.localIP(socket.dft())
            if gateway then
                log.info("NETWORK", "网关: " .. gateway)
                log.info("NETWORK", "子网掩码: " .. (netmask or "未知"))
            end
            -- 检查是否使用IPv4（MQTT默认使用IPv4）
            log.info("NETWORK", "网络协议: IPv4 (默认, 禁用IPv6)")
            return true
        end
        log.info("NETWORK", "等待网络连接...", i)
        sys.wait(config.NETWORK.RETRY_INTERVAL)
    end

    log.error("NETWORK", "网络连接失败")
    return false
end

-- ============================ 坐标转换模块 ============================

-- 判断是否在中国境内，不在国内则不做偏移
local function out_of_china(lng, lat)
    local lng = tonumber(lng)
    local lat = tonumber(lat)
    -- 纬度 3.86~53.55, 经度 73.66~135.05
    return not (lng > 73.66 and lng < 135.05 and lat > 3.86 and lat < 53.55)
end

-- 纬度转换
local function transformlat(lng, lat)
    local lat = tonumber(lat)
    local lng = tonumber(lng)
    local ret = -100.0 + 2.0 * lng + 3.0 * lat + 0.2 * lat * lat + 0.1 * lng * lat + 0.2 * math.sqrt(math.abs(lng))
    ret = ret + (20.0 * math.sin(6.0 * lng * PI) + 20.0 * math.sin(2.0 * lng * PI)) * 2.0 / 3.0
    ret = ret + (20.0 * math.sin(lat * PI) + 40.0 * math.sin(lat / 3.0 * PI)) * 2.0 / 3.0
    ret = ret + (160.0 * math.sin(lat / 12.0 * PI) + 320 * math.sin(lat * PI / 30.0)) * 2.0 / 3.0
    return ret
end

-- 经度转换
local function transformlng(lng, lat)
    local lat = tonumber(lat)
    local lng = tonumber(lng)
    local ret = 300.0 + lng + 2.0 * lat + 0.1 * lng * lng + 0.1 * lng * lat + 0.1 * math.sqrt(math.abs(lng))
    ret = ret + (20.0 * math.sin(6.0 * lng * PI) + 20.0 * math.sin(2.0 * lng * PI)) * 2.0 / 3.0
    ret = ret + (20.0 * math.sin(lng * PI) + 40.0 * math.sin(lng / 3.0 * PI)) * 2.0 / 3.0
    ret = ret + (150.0 * math.sin(lng / 12.0 * PI) + 300.0 * math.sin(lng / 30.0 * PI)) * 2.0 / 3.0
    return ret
end

-- WGS-84 转 GCJ-02（火星坐标系）
function core.wgs84_to_gcj02(lng, lat)
    log.info("坐标转换", "开始WGS84→GCJ02转换")
    log.info("坐标转换", "WGS84坐标", string.format("%.6f,%.6f", lng, lat))

    local lat = tonumber(lat)
    local lng = tonumber(lng)

    if not lat or not lng then
        log.error("坐标转换", "无效的WGS84坐标")
        return nil, nil
    end

    if out_of_china(lng, lat) then
        log.info("坐标转换", "坐标不在中国境内，无需转换")
        return lng, lat
    else
        local dlat = transformlat(lng - 105.0, lat - 35.0)
        local dlng = transformlng(lng - 105.0, lat - 35.0)
        local radlat = lat / 180.0 * PI
        local magic = math.sin(radlat)
        magic = 1 - ee * magic * magic
        local sqrtmagic = math.sqrt(magic)
        dlat = (dlat * 180.0) / ((a * (1 - ee)) / (magic * sqrtmagic) * PI)
        dlng = (dlng * 180.0) / (a / sqrtmagic * math.cos(radlat) * PI)
        local mglat = lat + dlat
        local mglng = lng + dlng

        log.info("坐标转换", "转换成功")
        log.info("坐标转换", "GCJ02坐标", string.format("%.6f,%.6f", mglng, mglat))
        return mglng, mglat
    end
end

-- ============================ GPS定位模块 ============================

-- GPS定位回调函数
local gps_callback = nil
local gps_result = nil

local function gpstest_cb(tag)
    log.info("GPS_CALLBACK", tag)

    -- 获取rmc数据，使用正确的UART2端口
    local rmc = exgnss.rmc(2)
    log.info("nmea", "rmc", json.encode(rmc))

    -- 获取gga数据，用于定位质量检查
    local gga = exgnss.gga(2)
    log.info("nmea", "gga", json.encode(gga))

    if rmc and rmc.valid then
        -- 打印完整的rmc数据结构，便于调试
        log.info("GPS定位成功", "完整rmc数据", json.encode(rmc, "\t"))

        -- 打印完整的gga数据结构，便于调试定位质量
        if gga then
            log.info("GPS定位成功", "完整gga数据", json.encode(gga, "\t"))
        end

        log.info("GPS定位成功", "====================")
        log.info("GPS定位成功", "原始WGS84坐标", string.format('"lat":%.6f, "lng":%.6f', rmc.lat, rmc.lng))
        log.info("GPS定位成功", "经纬度顺序确认", string.format('lng:%.6f, lat:%.6f', rmc.lng, rmc.lat))
        local time_str = rmc.time or (rmc.hour ~= nil and string.format("%02d:%02d:%02d", rmc.hour, rmc.min, rmc.sec) or "未知")
        log.info("GPS定位成功", "时间:" .. time_str)
        log.info("GPS定位成功", "速度:" .. string.format("%.2f", rmc.speed or 0) .. "节")
        log.info("GPS定位成功", "航向:" .. string.format("%.1f", rmc.course or 0) .. "度")

        -- 定位质量检查
        local hdop = gga and gga.hdop or 99.99
        local satellites = gga and gga.satellites_tracked or 0
        log.info("GPS定位成功", "定位质量", string.format("卫星数量:%d, HDOP:%.2f", satellites, hdop))
        log.info("GPS定位成功", "====================")

        -- 验证坐标是否合理（在地球范围内）
        if rmc.lat < -90 or rmc.lat > 90 or rmc.lng < -180 or rmc.lng > 180 then
            log.error("GPS定位成功", "无效的经纬度坐标", string.format('lat:%.6f, lng:%.6f', rmc.lat, rmc.lng))
            gps_result = nil
        else
            -- 调整：增加0.3的容差，处理边缘情况
            if satellites >= config.GPS.SATELLITE_THRESHOLD and hdop <= config.GPS.HDOP_THRESHOLD + 0.3 then
                log.info("GPS定位", "定位质量满足要求")

                -- 进行坐标转换
                local gcj_lng, gcj_lat = core.wgs84_to_gcj02(rmc.lng, rmc.lat)

                if gcj_lng and gcj_lat then
                    gps_result = {
                        lat = gcj_lat,
                        lon = gcj_lng,
                        original_lat = rmc.lat,
                        original_lon = rmc.lng,
                        speed = rmc.speed or 0,
                        course = rmc.course or 0,
                        altitude = gga and gga.altitude or 0,
                        hdop = hdop,
                        satellites = satellites,
                        is_gps = true,
                        time = rmc.time
                    }
                    log.info("GPS定位", "坐标转换完成")
                end
            else
                log.warn("GPS定位", "定位质量不满足要求")
                -- 调整：即使质量不满足要求，也保存定位结果，避免直接失败
                local gcj_lng, gcj_lat = core.wgs84_to_gcj02(rmc.lng, rmc.lat)
                if gcj_lng and gcj_lat then
                    gps_result = {
                        lat = gcj_lat,
                        lon = gcj_lng,
                        original_lat = rmc.lat,
                        original_lon = rmc.lng,
                        speed = rmc.speed or 0,
                        course = rmc.course or 0,
                        altitude = gga and gga.altitude or 0,
                        hdop = hdop,
                        satellites = satellites,
                        is_gps = true,
                        time = rmc.time
                    }
                    log.info("GPS定位", "尽管质量不满足要求，仍保存定位结果")
                else
                    gps_result = nil
                end
            end
        end
    else
        log.warn("GPS定位", "定位无效或未获取到数据")
        gps_result = nil
    end

    -- 调用外部回调函数
    if gps_callback then
        gps_callback(gps_result)
    end
end

-- 初始化GPS
function core.init_gps()
    log.info("GPS", "初始化GPS")

    -- 开启GPS电源
    log.info("POWER", "开启GPS电源")
    pm.power(pm.GPS, true)

    -- 配置GNSS参数
    local gnssopts = {
        gnssmode = config.GPS.MODE,
        agps_enable = config.GPS.AGPS_ENABLE,
        auto_open = config.GPS.AUTO_OPEN,
        uart = config.GPS.UART,
        uartbaud = config.GPS.BAUD_RATE,
        rtc = true,
        timeout = config.GPS.TIMEOUT,
        debug = true, -- 增加GPS调试信息
        -- 优化星历下载和处理
        url = "http://download.openluat.com/9501-xingli/HXXT_GPS_BDS_AGNSS_DATA.dat" -- 明确指定星历下载地址
    }

    exgnss.setup(gnssopts)
    log.info("GPS", "GNSS参数设置完成")
end

-- 启动GPS定位
function core.start_gps(callback)
    log.info("GPS", "启动GPS定位")

    gps_callback = callback
    gps_result = nil

    -- 使用TIMERORSUC模式：超时或定位成功后自动关闭
    local mode = config.GPS.LOCATION_MODE or exgnss.TIMERORSUC
    exgnss.open(mode, {tag="gpstest", val=config.GPS.TIMEOUT, cb=gpstest_cb})
end

-- 关闭GPS
function core.close_gps()
    log.info("GPS", "关闭GPS")
    exgnss.close_all()
    pm.power(pm.GPS, false)
end

-- ============================ 融合定位模块 ============================

-- WiFi 初始化状态标志，避免重复初始化
local _wifi_inited = false

-- 初始化WiFi
function core.init_wifi()
    if _wifi_inited then return end
    _wifi_inited = true
    log.info("WiFi", "初始化WiFi")
    wlan.init()
    log.info("WiFi", "WiFi初始化完成")
end

-- 获取基站信息
function core.get_cell_info()
    log.info("LBS", "开始获取基站信息")

    -- 尝试多种方式获取基站信息
    local cell_info = nil
    local attempts = 0
    local max_attempts = 3

    while not cell_info and attempts < max_attempts do
        attempts = attempts + 1
        log.info("LBS", "尝试获取基站信息，第" .. attempts .. "次")

        -- 请求基站信息
        mobile.reqCellInfo(config.LBS.CELL_INFO_REQ_TIME)

        -- 等待CELL_INFO_UPDATE事件
        local cell_updated = sys.waitUntil("CELL_INFO_UPDATE", config.LBS.CELL_INFO_TIMEOUT)
        if cell_updated then
            -- 获取基站信息
            cell_info = mobile.getCellInfo()

            -- 检查基站信息是否有效
            if cell_info and type(cell_info) == "table" and #cell_info > 0 then
                log.info("LBS", "基站信息获取成功，发现" .. #cell_info .. "个基站")
                -- 打印基站信息，便于调试
                log.info("LBS", "基站信息: " .. json.encode(cell_info))
                return cell_info
            else
                log.warn("LBS", "基站信息获取失败或为空，尝试重新获取")
                sys.wait(1000)  -- 等待1秒后重试
            end
        else
            log.warn("LBS", "基站信息获取超时，尝试重新获取")
            sys.wait(1000)  -- 等待1秒后重试
        end
    end

    -- 如果多次尝试后仍未获取到基站信息，使用mobile.scell()获取当前服务小区信息
    if not cell_info then
        log.info("LBS", "尝试使用mobile.scell()获取当前服务小区信息")
        local scell_info = mobile.scell()
        if scell_info and type(scell_info) == "table" and scell_info.mcc and scell_info.mnc and scell_info.cid then
            log.info("LBS", "成功获取当前服务小区信息: " .. json.encode(scell_info))
            return {scell_info}
        else
            log.error("LBS", "无法获取任何基站信息")
            return {}
        end
    end

    return {}
end

-- 构建基站参数字符串
function core.build_cell_param(cell_info)
    if not cell_info or type(cell_info) ~= "table" or #cell_info == 0 then
        log.warn("CELLULAR", "没有有效的基站信息")
        return nil
    end

    local cell_params = {}
    for i, cell in ipairs(cell_info) do
        if type(cell) == "table" then
            -- 尝试获取各种可能的字段名
            local mcc = cell.mcc
            local mnc = cell.mnc
            local lac = cell.lac or cell.tac
            local cid = cell.cid or cell.cellId
            local rsrp = cell.rsrp
            local rssi = cell.rssi

            if mcc and mnc and lac and cid then
                -- 信号强度，使用rsrp或rssi，单位是dBm
                local signal_strength = rsrp or rssi or -90
                table.insert(cell_params, string.format("%d,%d,%d,%d,%d", mcc, mnc, lac, cid, signal_strength))
                log.info("CELLULAR", "添加基站参数: " .. cell_params[#cell_params])
            else
                log.warn("CELLULAR", "跳过无效的基站信息: " .. json.encode(cell))
            end
        end
    end

    if #cell_params > 0 then
        local result = table.concat(cell_params, ";")
        log.info("CELLULAR", "构建的基站参数: " .. result)
        return result
    else
        log.warn("CELLULAR", "无法构建有效的基站参数")
        return nil
    end
end

-- 扫描WiFi并获取结果
function core.scan_wifi()
    log.info("WiFi", "开始扫描WiFi")

    -- 发送扫描请求
    wlan.scan()

    -- 等待扫描结果
    local scan_done = sys.waitUntil("WLAN_SCAN_DONE", config.WIFI.SCAN_TIMEOUT)
    if scan_done then
        local results = wlan.scanResult()
        log.info("WiFi", "扫描完成，发现" .. #results .. "个WiFi热点")
        -- 按信号强度排序
        table.sort(results, function(a, b) return a.rssi > b.rssi end)
        return results
    else
        log.warn("WiFi", "WiFi扫描超时")
        return nil
    end
end

-- 构建WiFi参数字符串
function core.build_wifi_param(wifi_results)
    if not wifi_results or type(wifi_results) ~= "table" or #wifi_results == 0 then
        log.warn("WiFi", "没有有效的WiFi热点信息")
        return nil
    end

    local wifi_params = {}
    for i, wifi in ipairs(wifi_results) do
        if type(wifi) == "table" and wifi.bssid then
            -- 获取MAC地址（转换为十六进制字符串）
            local mac_address = wifi.bssid:toHex()
            -- 格式化MAC地址为XX:XX:XX:XX:XX:XX格式
            mac_address = string.upper(mac_address):gsub("(%x%x)", "%1:"):sub(1, 17)
            -- 信号强度，单位是dBm
            local signal_strength = wifi.rssi or -90

            table.insert(wifi_params, string.format("%s,%d", mac_address, signal_strength))
            log.info("WiFi", "添加WiFi参数: " .. wifi_params[#wifi_params])
        end
    end

    if #wifi_params > 0 then
        local result = table.concat(wifi_params, ";")
        log.info("WiFi", "构建的WiFi参数: " .. result)
        return result
    else
        log.warn("WiFi", "无法构建有效的WiFi参数")
        return nil
    end
end

-- 将原始 WiFi 扫描结果转为 OneNET $OneNET_LBS_WIFI 格式
function core.build_onenet_wifi_data(raw_results)
    if not raw_results or type(raw_results) ~= "table" or #raw_results == 0 then
        return nil
    end
    table.sort(raw_results, function(a, b) return a.rssi > b.rssi end)
    local mac_list = {}
    for i = 1, math.min(8, #raw_results) do
        if raw_results[i].bssid then
            local mac = raw_results[i].bssid:toHex()
            mac = string.upper(mac):gsub("(%x%x)", "%1:"):sub(1, 17)
            table.insert(mac_list, mac .. "," .. (raw_results[i].rssi or -90))
        end
    end
    if #mac_list == 0 then return nil end
    return {
        macs = table.concat(mac_list, "|"),
        imsi = mobile.imsi and mobile.imsi() or "",
        serverip = "",
        mmac = mac_list[1] or "",
        smac = "",
        idfa = ""
    }
end

-- ============= OneNET LBS基站定位 =============

-- 生成 OneNET REST API token（复用逻辑）
local function _onenet_token()
    local pid = config.ONENET.PRODUCT_ID
    local device = config.ONENET.DEVICE_NAME or mobile.imei()
    local device_secret = config.ONENET.DEVICE_SECRET
    local et = tostring(os.time() + 3600)
    local key_bytes = crypto.base64_decode(device_secret)
    local sign_str = string.format("%s\n%s\n%s\n%s", et, "sha1",
        string.format("products/%s/devices/%s", pid, device), "2018-10-31")
    local hmac_hex = crypto.hmac_sha1(sign_str, key_bytes)
    local hmac_raw = hmac_hex and hmac_hex.fromHex and hmac_hex:fromHex() or hmac_hex
    local sign_b64 = crypto.base64_encode(hmac_raw)
    local res_enc = string.urlEncode(string.format("products/%s/devices/%s", pid, device))
    local sign_enc = string.urlEncode(sign_b64)
    return string.format("version=%s&res=%s&et=%s&method=%s&sign=%s",
        "2018-10-31", res_enc, et, "sha1", sign_enc)
end

-- 查询 OneNET LBS 最新位置（返回 lat, lng, accuracy 或 nil）
local function _query_onenet_lbs()
    local pid = config.ONENET.PRODUCT_ID
    local device = config.ONENET.DEVICE_NAME or mobile.imei()
    local token = _onenet_token()
    local code, resp = httpplus.request({
        url = string.format("https://iot-api.heclouds.com/fuse-lbs/latest-location?product_id=%s&device_name=%s",
            pid, device),
        method = "GET",
        headers = {["authorization"] = token},
        timeout = 10
    })
    if type(code) == "number" and code >= 100 and resp and resp.body then
        local body_str = resp.body:query()
        if body_str and body_str ~= "" then
            local ok_j, jdata = pcall(json.decode, body_str)
            if ok_j and jdata and jdata.code == 0 and jdata.data then
                local lat = tonumber(jdata.data.lat)
                local lng = tonumber(jdata.data.lon)
                if lat and lng then
                    return lat, lng, jdata.data.accuracy
                end
            end
        end
    end
    return nil
end

-- 通过 MQTT 上传 LBS 数据触发 OneNET 位置计算
local function _publish_lbs_data(wifi_data, lbs_list)
    local lbs_data = {
        id = tostring(mcu.ticks()),
        version = "1.0",
        params = {}
    }
    if lbs_list then
        lbs_data.params["$OneNET_LBS"] = { value = lbs_list }
    end
    if wifi_data then
        lbs_data.params["$OneNET_LBS_WIFI"] = { value = wifi_data }
    end
    if mqttc and mqttc:ready() then
        mqttc:publish(onenet_pub_topic, json.encode(lbs_data), 1)
        log.info("LBS", "已上传定位数据触发OneNET位置计算")
    end
end

-- 扫描 WiFi 热点（返回格式化后的 wifi_data 或 nil）
-- 注意：调用前需先调用 core.init_wifi() 完成初始化
local function _scan_wifi()
    if not wlan then return nil end
    log.info("LBS", "尝试扫描WiFi热点")
    -- 等待3秒让WiFi芯片稳定（刚初始化立即扫描总是返回0）
    sys.wait(3000)
    wlan.scan()
    local scan_done = sys.waitUntil("WLAN_SCAN_DONE", config.WIFI.SCAN_TIMEOUT)
    if not scan_done then
        log.info("LBS", "WiFi扫描超时")
        return nil
    end
    sys.wait(500)
    local results = wlan.scanResult()
    log.info("LBS", "WiFi扫描完成, 发现 " .. #results .. " 个热点")
    if not results or #results == 0 then return nil end
    table.sort(results, function(a, b) return a.rssi > b.rssi end)
    local mac_list = {}
    for i = 1, math.min(8, #results) do
        if results[i].bssid then
            local mac = results[i].bssid:toHex()
            mac = string.upper(mac):gsub("(%x%x)", "%1:"):sub(1, 17)
            table.insert(mac_list, mac .. "," .. (results[i].rssi or -90))
        end
    end
    if #mac_list == 0 then return nil end
    return {
        macs = table.concat(mac_list, "|"),
        imsi = mobile.imsi and mobile.imsi() or "",
        serverip = "",
        mmac = mac_list[1] or "",
        smac = "",
        idfa = ""
    }
end

-- 获取基站信息（返回基站列表或 nil）
local function _get_cell_info()
    local infos = nil
    for retry = 1, 2 do
        mobile.reqCellInfo(5)
        local updated = sys.waitUntil("CELL_INFO_UPDATE", 5000)
        if updated then
            infos = mobile.getCellInfo()
            if infos and #infos > 0 then break end
        end
    end
    if not infos or #infos == 0 then
        local scell = mobile.scell()
        if scell and scell.mcc then
            infos = {scell}
        end
    end
    if not infos or #infos == 0 then
        log.error("LBS", "无基站信息")
        return nil
    end
    return core._build_lbs_list(infos)
end

function core.fusion_locate(cell_info, wifi_results)
    log.info("LBS", "使用OneNET LBS定位")

    -- 1. 先获取基站信息（耗时约3-5秒，期间WiFi芯片自然稳定）
    local lbs_list = _get_cell_info()

    -- 2. 再扫描 WiFi（此时芯片已稳定，首次扫描成功率更高）
    local wifi_data = _scan_wifi()

    -- 3. WiFi 和基站数据同时上传，OneNET 会自动融合计算
    _publish_lbs_data(wifi_data, lbs_list)
    sys.wait(1500)  -- 等待 OneNET 完成计算
    local lat, lng, accuracy = _query_onenet_lbs()
    if lat and lng then
        log.info("LBS", string.format("LBS定位成功: %.6f, %.6f", lat, lng))
        return {lat=lat, lon=lng, accuracy=accuracy or 1000, is_fusion=true}, wifi_data
    end

    log.error("LBS", "OneNET LBS定位失败")
    return nil, wifi_data
end

function core.do_fusion_locate(callback)
    sys.taskInit(function()
        log.info("FUSION", "开始执行融合定位(OneNET LBS)")
        core.init_wifi()
        local location, wifi_data = core.fusion_locate(nil, nil)
        if location then
            log.info("FUSION", "融合定位成功 纬度:" .. location.lat .. " 经度:" .. location.lon)
        else
            log.error("FUSION", "融合定位失败")
        end
        if callback then callback(location, wifi_data) end
    end)
end

-- 构建基站列表（供 fusion_locate 和 onenet_upload 共用）
function core._build_lbs_list(infos)
    local lbs_list = {}
    for _, v in ipairs(infos) do
        if type(v) == "table" and v.mcc and v.mnc and (v.lac or v.tac) and (v.cid or v.cellId) then
            table.insert(lbs_list, {
                cid = v.cid or v.cellId,
                lac = v.lac or v.tac,
                mcc = v.mcc,
                mnc = v.mnc,
                networkType = 5,  -- LTE
                ss = v.rsrp or v.rssi,
                signalLength = v.signalLength or 0,
                ta = v.snr,
                flag = v.flag or 0
            })
            -- 物模型 $OneNET_LBS 数组长度限制为 3
            if #lbs_list >= 3 then break end
        end
    end
    return lbs_list
end

-- ============================ OneNET MQTT上传模块 ============================

-- MQTT客户端对象
local mqttc = nil
-- MQTT连接状态
local mqtt_connected = false
-- 最近一次 WiFi 扫描结果（供 onenet_upload 使用）
-- OneNET Topic
local onenet_pub_topic = nil
local onenet_sub_topic = nil

-- 初始化OneNET MQTT连接
function core.init_onenet_mqtt()
    log.info("ONENET", "初始化OneNET MQTT连接")

    -- 使用iotauth获取OneNET认证信息
    local pid = config.ONENET.PRODUCT_ID
    local device = config.ONENET.DEVICE_NAME or mobile.imei()
    local device_secret = config.ONENET.DEVICE_SECRET

    if not pid or pid == "your_product_id" then
        log.error("ONENET", "请先在config.lua中配置OneNET PRODUCT_ID")
        return false
    end

    if not device_secret or device_secret == "your_device_secret" then
        log.error("ONENET", "请先在config.lua中配置OneNET DEVICE_SECRET")
        return false
    end

    -- 通过iotauth生成MQTT认证信息
    local client_id, user_name, password = iotauth.onenet(pid, device, device_secret)
    if not client_id then
        log.error("ONENET", "iotauth.onenet认证失败")
        return false
    end

    log.info("ONENET", string.format("MQTT认证成功, client_id=%s, user=%s", client_id, user_name))

    -- 构建OneNET物模型Topic
    -- 属性上报: $sys/{pid}/{device}/thing/property/post
    -- 属性设置(下行): $sys/{pid}/{device}/thing/property/set
    onenet_pub_topic = string.format("$sys/%s/%s/thing/property/post", pid, device)
    onenet_sub_topic = string.format("$sys/%s/%s/thing/property/set", pid, device)

    log.info("ONENET", "上报Topic: " .. onenet_pub_topic)
    log.info("ONENET", "下发Topic: " .. onenet_sub_topic)

    -- 创建MQTT连接
    if mqttc then
        mqttc:close()
        mqttc = nil
    end

    -- IS_SSL 支持三种配置:
    --   true               — 简单TLS加密, 不验证服务器证书
    --   false              — 不加密
    --   {server_cert=...}  — TLS加密 + 验证服务器证书
    local ssl_conf = config.ONENET.IS_SSL
    if type(ssl_conf) == "table" and ssl_conf.server_cert == nil then
        -- 如果配了table但没填证书, 尝试读取默认证书文件
        local cert_path = "/luadb/onenet_ca.crt"
        if io.exists(cert_path) then
            ssl_conf.server_cert = io.readFile(cert_path)
            log.info("ONENET", "已加载CA证书: " .. cert_path)
        else
            log.warn("ONENET", "CA证书文件不存在, 使用无证书验证: " .. cert_path)
            ssl_conf = true
        end
    end
    mqttc = mqtt.create(nil, config.ONENET.HOST, config.ONENET.PORT, ssl_conf, {ipv6 = false})

    -- 设置认证信息（OneNET 不支持 clean_session=false，用默认的 true）
    mqttc:auth(client_id, user_name, password)

    -- 设置keepalive
    mqttc:keepalive(config.ONENET.KEEPALIVE)

    -- 开启自动重连
    mqttc:autoreconn(true, 5000)

    -- 注册MQTT事件回调
    mqttc:on(function(mqtt_client, event, data, payload)
        if event == "conack" then
            -- MQTT连接成功
            log.info("ONENET", "MQTT连接成功")
            mqtt_connected = true
            sys.publish("ONENET_CONNECTED")

            -- 订阅下行Topic（属性设置）
            mqtt_client:subscribe(onenet_sub_topic, 2)
            log.info("ONENET", "已订阅下行Topic: " .. onenet_sub_topic)
            -- 订阅属性上报回复（查看OneNET是否接受数据）
            local reply_topic = onenet_pub_topic .. "/reply"
            mqtt_client:subscribe(reply_topic, 2)
            log.info("ONENET", "已订阅上报回复Topic: " .. reply_topic)
            -- OneNET Studio 不支持通过 MQTT 查询期望值，只能用属性设置下行

        elseif event == "recv" then
            -- 收到下行数据
            log.info("ONENET", "收到下行数据, topic=" .. (data or "") .. ", payload=" .. (payload or ""))

            -- 解析下行JSON
            if payload and payload ~= "" then
                local ok, jdata = pcall(json.decode, payload)
                if ok and jdata then
                    local msg_id = jdata.id or "0"

                    -- 区分 topic
                    --   $sys/{pid}/{device}/thing/property/set         → 属性设置（来自平台）
                    --   $sys/{pid}/{device}/thing/property/post/reply  → 上报回复（平台处理结果）
                    if data and data:match("/property/set$") then
                        -- 处理属性设置：检查是否有 ReportInterval 或 LocationMode
                        if jdata.params then
                            for key, val in pairs(jdata.params) do
                                if key == "ReportInterval" then
                                    local raw = val
                                    if type(val) == "table" and val.value ~= nil then
                                        raw = val.value
                                    end
                                    local interval_ms = math.floor(tonumber(raw))
                                    if interval_ms and interval_ms >= 60000 then
                                        core.set_sleep_interval(interval_ms)
                                        log.info("ONENET", "远程修改上报间隔为: " .. interval_ms .. "ms")
                                    else
                                        log.warn("ONENET", "无效的上报间隔值: " .. tostring(raw))
                                    end
                                elseif key == "LocationMode" then
                                    local raw = val
                                    if type(val) == "table" and val.value ~= nil then
                                        raw = val.value
                                    end
                                    -- 支持 "default"/"lbs_only" 字符串或 0/1 数字
                                    local mode_str = tostring(raw)
                                    if mode_str == "0" or mode_str == "default" then
                                        core.set_location_mode("default")
                                        log.info("ONENET", "远程切换定位模式为: default")
                                    elseif mode_str == "1" or mode_str == "lbs_only" then
                                        core.set_location_mode("lbs_only")
                                        log.info("ONENET", "远程切换定位模式为: lbs_only")
                                    else
                                        log.warn("ONENET", "无效的LocationMode值: " .. tostring(raw))
                                    end
                                end
                            end
                        end

                        -- 回复属性设置结果（必须在5秒内回复，否则平台超时）
                        if onenet_pub_topic then
                            local reply_topic = onenet_pub_topic:gsub("/post$", "/set_reply")
                            local reply_msg = json.encode({
                                id = msg_id,
                                code = 200,
                                msg = "success"
                            })
                            mqtt_client:publish(reply_topic, reply_msg, 1)
                            log.info("ONENET", "已回复属性设置结果")
                        end
                    else
                        -- 上报回复（包括成功/错误码），仅记录不处理
                        if jdata.code == 200 then
                            log.info("ONENET", "上报成功, code=200, msg=" .. (jdata.msg or "success"))
                        elseif jdata.code and jdata.code ~= 0 then
                            log.warn("ONENET", "上回报错, code=" .. tostring(jdata.code) .. ", msg=" .. (jdata.msg or ""))
                        end
                    end

                    sys.publish("ONENET_DOWNLINK", jdata)
                end
            end

        elseif event == "sent" then
            -- 数据发送成功确认（QoS 1 PUBACK 收到）
            log.info("ONENET", "数据发送确认, pkgid=" .. tostring(data))
            if data then
                sys.publish("ONENET_SENT_" .. tostring(data))
            end

        elseif event == "disconnect" then
            log.warn("ONENET", "MQTT连接断开")
            mqtt_connected = false
        end
    end)

    -- 发起连接
    mqttc:connect()

    return true
end

-- 检查MQTT是否就绪
function core.mqtt_ready()
    return mqttc ~= nil and mqtt_connected and mqttc:ready()
end

-- ==================== 远程配置持久化 (fskv) ====================

-- fskv键名
local FSKV_KEY_INTERVAL = "sleep_interval"

-- 获取上报间隔（优先读取fskv持久化值，不存在则用config默认值）
function core.get_sleep_interval()
    local saved = fskv.get(FSKV_KEY_INTERVAL)
    if saved and tonumber(saved) then
        local val = tonumber(saved)
        log.info("ONENET", "读取持久化上报间隔: " .. val .. "ms")
        return val
    end
    log.info("ONENET", "使用默认上报间隔: " .. config.PSM.WAKEUP_PERIOD .. "ms")
    return config.PSM.WAKEUP_PERIOD
end

-- 设置上报间隔并保存到fskv（持久化，重启不丢失）
function core.set_sleep_interval(interval_ms)
    if not interval_ms or interval_ms < 60000 then
        log.warn("ONENET", "上报间隔不能小于60秒，已忽略")
        return false
    end
    interval_ms = math.floor(interval_ms)
    local ok = fskv.set(FSKV_KEY_INTERVAL, tostring(interval_ms))
    if ok then
        log.info("ONENET", "上报间隔已保存到fskv: " .. interval_ms .. "ms")
    else
        log.error("ONENET", "fskv保存失败")
    end
    return ok
end

-- fskv键名
local FSKV_KEY_LOCATION_MODE = "location_mode"

-- 获取定位模式（优先读取fskv持久化值，不存在则用config默认值）
function core.get_location_mode()
    local saved = fskv.get(FSKV_KEY_LOCATION_MODE)
    if saved then
        log.info("ONENET", "读取持久化定位模式: " .. saved)
        return saved
    end
    log.info("ONENET", "使用默认定位模式: " .. config.LOCATION_MODE)
    return config.LOCATION_MODE
end

-- 设置定位模式并保存到fskv（持久化，重启不丢失）
-- mode: "default" 或 "lbs_only"
function core.set_location_mode(mode)
    if mode ~= "default" and mode ~= "lbs_only" then
        log.warn("ONENET", "无效的定位模式: " .. tostring(mode) .. "，已忽略")
        return false
    end
    local ok = fskv.set(FSKV_KEY_LOCATION_MODE, mode)
    if ok then
        log.info("ONENET", "定位模式已保存到fskv: " .. mode)
    else
        log.error("ONENET", "fskv保存失败")
    end
    return ok
end

-- 通过 OneNET REST API 查询设备属性期望值
-- API: POST https://iot-api.heclouds.com/thingmodel/query-device-desired-property
function core.fetch_desired_config()
    if not socket.adapter(socket.dft()) then
        log.warn("ONENET", "网络未就绪，跳过")
        return
    end

    log.info("ONENET", "查询设备属性期望值")

    local pid = config.ONENET.PRODUCT_ID
    local device = config.ONENET.DEVICE_NAME or mobile.imei()
    local token = _onenet_token()

    local code, resp = httpplus.request({
        url = "https://iot-api.heclouds.com/thingmodel/query-device-desired-property",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["authorization"] = token
        },
        body = json.encode({
            product_id = pid,
            device_name = device,
            params = {"ReportInterval", "LocationMode"}
        }),
        timeout = 10
    })

    if type(code) == "number" and code >= 100 and resp and resp.body then
        local body_str = resp.body:query()
        if body_str and body_str ~= "" then
            log.info("ONENET", "期望值API响应: " .. body_str)
            local ok_j, jdata = pcall(json.decode, body_str)
            if ok_j and jdata then
                log.info("ONENET", "code=" .. tostring(jdata.code))
                if jdata.code == 0 and jdata.data then
                    -- 处理 ReportInterval
                    local iv = jdata.data.ReportInterval
                    if iv and iv.value and tonumber(iv.value) and tonumber(iv.value) >= 60000 then
                        core.set_sleep_interval(math.floor(tonumber(iv.value)))
                        log.info("ONENET", "获取期望值成功, ReportInterval=" .. iv.value .. "ms")
                    end
                    -- 处理 LocationMode
                    local lm = jdata.data.LocationMode
                    if lm and lm.value then
                        local mode_str = tostring(lm.value)
                        if mode_str == "0" or mode_str == "default" then
                            core.set_location_mode("default")
                            log.info("ONENET", "获取期望值成功, LocationMode=default")
                        elseif mode_str == "1" or mode_str == "lbs_only" then
                            core.set_location_mode("lbs_only")
                            log.info("ONENET", "获取期望值成功, LocationMode=lbs_only")
                        end
                    end
                    return
                elseif jdata.code and jdata.code ~= 0 then
                    log.warn("ONENET", "期望值API错误: " .. (jdata.msg or ""))
                end
            end
        end
    end
    log.info("ONENET", "无期望值，使用本地值")
end

-- 构建OneJSON格式的定位数据（使用OneNET标准GeoLocation结构体）
local function build_onenet_location_data(location)
    local data = {}
    -- id 用于 OneNET 去重，mcu.ticks() 在单次启动周期内单调递增
    data["id"] = tostring(mcu.ticks())
    data["version"] = "1.0"
    data["params"] = {}

    -- 使用OneNET标准地理位置结构体 GeoLocation
    if location.lat and location.lon then
        -- 经纬度需按物模型 step 精度四舍五入，否则 OneNET 报 2244
        local geo = {
            Longitude = tonumber(string.format("%.6f", location.lon)),
            Latitude = tonumber(string.format("%.6f", location.lat)),
            CoordinateSystem = 1  -- 1=GCJ02 (火星坐标系)
        }
        if location.altitude then
            geo.Altitude = tonumber(string.format("%.1f", location.altitude))
        end
        data["params"]["GeoLocation"] = { value = geo }
    end

    -- 定位类型: 0=GPS, 1=FUSION(融合定位)
    if location.is_gps then
        data["params"]["LocationType"] = { value = 0 }
    elseif location.is_fusion then
        data["params"]["LocationType"] = { value = 1 }
    end

    -- 速度 (km/h, 从节转换: 1节 = 1.852 km/h)
    -- 注意：需按物模型 step 精度四舍五入，否则 OneNET 报 2244 "double not conform step"
    if location.speed then
        data["params"]["Speed"] = { value = tonumber(string.format("%.1f", location.speed * 1.852)) }
    end

    -- 卫星数量
    if location.satellites then
        data["params"]["Satellites"] = { value = location.satellites }
    end

    return data
end

-- 通过MQTT上报GPS定位数据到OneNET
-- @param wifi_data 可选，融合定位时传入 WiFi 扫描结果
function core.onenet_upload(location, callback, wifi_data)
    if not location or not location.lat or not location.lon then
        log.error("ONENET", "缺少位置信息，无法上报")
        if callback then callback(false) end
        return false
    end

    if not core.mqtt_ready() then
        log.error("ONENET", "MQTT未就绪，无法上报")
        if callback then callback(false) end
        return false
    end

    -- 在新协程中执行，避免阻塞
    sys.taskInit(function()
        log.info("ONENET", "开始上报定位数据到OneNET")

        -- 构建OneJSON格式数据
        local data = build_onenet_location_data(location)

        -- 非 GPS 定位时添加基站/WiFi 信息（GPS 定位无需上传 LBS 数据）
        if not location.is_gps then
            -- 添加基站信息（同步到物模型"基站定位"属性，用于 OneNET 位置服务）
            if mobile and type(mobile.reqCellInfo) == "function" then
                mobile.reqCellInfo(5)
                sys.waitUntil("CELL_INFO_UPDATE", 3000)
                local infos = mobile.getCellInfo()
                if infos and #infos > 0 then
                    data["params"]["$OneNET_LBS"] = { value = core._build_lbs_list(infos) }
                end
            end
            -- 添加 WiFi 热点信息（同步到物模型"WIFI定位"属性）
            if wifi_data then
                data["params"]["$OneNET_LBS_WIFI"] = { value = wifi_data }
                log.info("ONENET", "已添加$OneNET_LBS_WIFI")
            end
        end

        -- 编码为JSON
        local json_data = json.encode(data)
        log.info("ONENET", "待上报数据: " .. json_data)

        -- 发布到OneNET（QoS 1，等待 broker 确认后再回调）
        -- MQTT 连接会保持到飞行模式才断开（enter_psm 中不再主动 close_onenet_mqtt）
        local pkgid = mqttc:publish(onenet_pub_topic, json_data, 1)
        if pkgid then
            log.info("ONENET", "数据已入队列, pkgid=" .. tostring(pkgid) .. "，等待发送确认...")
            -- 等待 MQTT broker 确认（sent 事件 = PUBACK 收到或 TCP 发送完成）
            local sent_ok = sys.waitUntil("ONENET_SENT_" .. tostring(pkgid), 5000)
            if sent_ok then
                log.info("ONENET", "broker已确认发送成功，等待处理结果...")
                -- 等一会接收 OneNET 的回复（含处理结果/错误码）
                sys.wait(1500)
                if callback then callback(true) end
            else
                log.warn("ONENET", "发送确认超时")
                if callback then callback(false) end
            end
        else
            log.error("ONENET", "数据入队列失败")
            if callback then callback(false) end
        end
    end)

    return true
end

-- 关闭MQTT连接
function core.close_onenet_mqtt()
    if mqttc then
        mqttc:close()
        mqttc = nil
    end
    mqtt_connected = false
    log.info("ONENET", "MQTT连接已关闭")
end

-- ============================ PSM低功耗模块 ============================

-- 进入PSM低功耗模式
function core.enter_psm(speed)
    log.info("PSM", "准备进入PSM低功耗模式")

    -- 关闭GSensor（仅在定位时使用，休眠前关闭以省电）
    if gsensor_initialized then
        log.info("PSM", "关闭GSensor")
        gpio.setup(gsensor_int_pin, nil)  -- 移除GPIO中断
        local exvib = require("exvib")
        if exvib then
            exvib.close()
        end
        gsensor_initialized = false
        gsensor_motion_detected = false
    end

    -- 关闭看门狗（PSM期间无需喂狗，避免意外复位）
    if wdt then
        wdt.close()
    end

    -- 读取持久化的上报间隔（可在OneNET平台远程修改）
    local sleep_time = core.get_sleep_interval()

    -- 根据速度调整休眠时间
    if speed and type(speed) == "number" then
        log.info("PSM", "当前速度: " .. string.format("%.2f", speed) .. "节")

        -- 当速度值小于3.24节且不等于0时，增加10分钟
        if speed > 0 and speed < 3.24 then
            log.info("PSM", "速度小于3.24节，增加10分钟休眠时间")
            sleep_time = sleep_time + 10 * 60 * 1000
            log.info("PSM", "调整后休眠时间: " .. sleep_time .. "毫秒")
        else
            log.info("PSM", "使用基础休眠时间: " .. sleep_time .. "毫秒")
        end
    else
        log.info("PSM", "未提供速度参数，使用基础休眠时间: " .. sleep_time .. "毫秒")
    end

    -- 关闭GPS电源
    core.close_gps()

    -- 配置VBUS(WAKEUP1)上升沿中断唤醒
    -- Air780EXX系列模块内部VBUS经分压后接WAKEUP1引脚
    -- USB插入时产生上升沿，可从PSM+模式3唤醒设备（唤醒=重启）
    -- gpio.PULLDOWN + gpio.RISING 实测不增加额外功耗
    log.info("PSM", "配置VBUS(WAKEUP1)上升沿唤醒")
    gpio.setup(gpio.WAKEUP1, nil, gpio.PULLDOWN, gpio.RISING)

    -- 启动深度休眠定时器
    pm.dtimerStart(3, sleep_time)

    -- 启动飞行模式，规避可能会出现的网络问题
    mobile.flymode(0, true)

    -- 进入极致功耗模式
    pm.power(pm.WORK_MODE, config.PSM.WORK_MODE)

    log.info("PSM", "已进入PSM低功耗模式")
    log.info("PSM", "等待定时唤醒...")

    -- 等待15秒，如果未重启则说明进入PSM失败
    sys.wait(15000)
    log.info("PSM", "进入PSM模式失败，尝试重启")
    rtos.reboot()
end

return core
