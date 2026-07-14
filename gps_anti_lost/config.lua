--[[
@module  config
@summary 4G GPS/北斗宠物定位器 配置文件
@version 1.0.0
@date    2026.07.13
@author  Jun (AI协助: GitHub Copilot)
@usage
配置4G GPS/北斗宠物定位器的各项参数，包括网络、定位、OneNET平台等配置
]]

-- 设备配置
local config = {
    -- 设备标识
    DEVICE_NAME = "Pet_GPS_Tracker_4G",

    -- 移动网络配置
    NETWORK = {
        SIM_ID = 2,               -- SIM卡ID，优先使用SIM0
        AUTO_SELECT_SIM = true,   -- 自动选卡
        APN = "cmnet",            -- APN，移动卡通常为cmnet
        APN_USER = "",            -- APN用户名
        APN_PWD = "",             -- APN密码
        RETRY_COUNT = 5,          -- 网络连接重试次数
        RETRY_INTERVAL = 3000,    -- 网络连接重试间隔（毫秒）
        TIMEOUT = 30000,          -- 网络连接超时时间（毫秒）
    },

    -- OneNET平台配置 (MQTT接入方式)
    -- 注册地址: https://open.iot.10086.cn/studio/summary
    -- 文档: https://open.iot.10086.cn/doc/v5/develop/detail/iot_platform
    ONENET = {
        HOST = "mqttstls.heclouds.com",   -- OneNET MQTTS服务器地址（TLS加密）
        PORT = 8883,                       -- MQTTS端口
        IS_SSL = true,                     -- 使用TLS加密
        PRODUCT_ID = "your_product_id",    -- OneNET Studio产品ID
        DEVICE_NAME = nil,                 -- 设备名称(nil则自动使用IMEI)
        DEVICE_SECRET = "your_device_secret", -- 设备密钥
        PUBLISH_INTERVAL = 30000,          -- 数据上报间隔（毫秒）
        KEEPALIVE = 120,                   -- MQTT keepalive（秒）
    },

    -- GPS定位配置
    GPS = {
        MODE = 1,                 -- 1:全卫星定位(GPS+北斗)，2:单北斗
        AGPS_ENABLE = true,       -- 是否启用AGPS
        AUTO_OPEN = true,         -- 定位完成后是否自动关闭
        UART = 2,                 -- GPS使用的UART端口 (Air780EGP默认UART2)
        BAUD_RATE = 115200,       -- GPS波特率
        TIMEOUT = 15,             -- 定位超时时间（秒）
        LOCATION_MODE = nil,      -- 定位模式: nil表示在core中使用exgnss.TIMERORSUC
        HDOP_THRESHOLD = 3.5,     -- 定位精度阈值（HDOP）
        SATELLITE_THRESHOLD = 5,  -- 卫星数量阈值
    },

    -- LBS定位配置
    LBS = {
        TIMEOUT = 5000,              -- LBS定位超时时间（毫秒）
        CELL_INFO_REQ_TIME = 15,     -- 基站信息请求时间（秒）
        CELL_INFO_TIMEOUT = 10000,   -- 基站信息获取超时（毫秒）
    },

    -- WiFi配置
    WIFI = {
        SCAN_TIMEOUT = 15000         -- WiFi扫描超时时间（毫秒）
    },

    -- PSM低功耗配置
    PSM = {
        ENABLED = true,                -- true=进入PSM休眠, false=普通等待后重启
        WAKEUP_PERIOD = 30 * 60 * 1000, -- 唤醒周期（毫秒），默认30分钟（可通过OneNET远程修改）
        WORK_MODE = 3,                  -- 工作模式：3-极致功耗模式
        DELAY_BEFORE_SLEEP = 5000,      -- 定位成功后延迟进入休眠（毫秒）
    },

    -- 定位模式（可通过OneNET期望值远程切换）
    --   "default"   — 默认模式：先 GPS，失败后走 LBS
    --   "lbs_only"  — 纯 LBS 模式：跳过 GPS，直接走基站+WiFi 融合定位
    LOCATION_MODE = "default",

    -- 调试配置
    DEBUG = {
        ENABLE = true,
        LOG_LEVEL = "info",
    }
}

return config
