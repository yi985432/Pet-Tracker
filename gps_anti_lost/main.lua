--[[
@module  main
@summary 4G GPS/北斗宠物定位器 主程序入口
@version 1.0.0
@date    2026.07.13
@author  Jun (AI协助: GitHub Copilot)
@usage
4G GPS/北斗宠物定位器主程序，实现设备开机联网、MQTT连接、GPS/LBS定位、
OneNET平台数据上报和低功耗管理
]]

-- 必须定义PROJECT和VERSION变量
PROJECT = "Pet_GPS_Tracker_4G"
VERSION = "1.0.0"

log.info("main", "项目名称: 4G GPS/北斗宠物定位器, 版本: ", VERSION)

-- 导入必要的库
_G.sys = require("sys")
_G.sysplus = require("sysplus")   -- MQTT库需要sysplus
local config = require("config")
local core = require("core")

-- 如果内核固件支持wdt看门狗功能，此处对看门狗进行初始化和定时喂狗处理
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

-- 退出低功耗模式，进入正常工作模式
log.info("POWER", "退出低功耗模式，进入正常工作模式")
pm.power(pm.WORK_MODE, 0)

-- 开启USB电源，确保调试和数据传输正常
log.info("POWER", "开启USB电源")
pm.power(pm.USB, true)

-- GPS处理中标志，防止回调重入导致内存溢出
local gps_busy = false

-- 完成本轮定位：根据配置决定进PSM或普通等待
local function finish_cycle(speed)
    -- 关闭GNSS，停止多余的日志和回调
    core.close_gps()
    -- GNSS已关闭，复位处理标志
    gps_busy = false

    if config.PSM.ENABLED then
        -- PSM模式：进入深度休眠
        log.info("MAIN", "PSM模式已开启，进入休眠")
        core.enter_psm(speed)
    else
        -- 普通模式：等待间隔后重启
        local interval = core.get_sleep_interval()
        log.info("MAIN", string.format("普通模式，等待 %.1f 分钟后重启", interval / 60000))
        sys.timerStart(function()
            log.info("MAIN", "重启系统，开始新一轮定位...")
            rtos.reboot()
        end, interval)
    end
end

-- 保存上一次上报的位置（用于GSensor静止过滤）
local last_reported_loc = nil

-- 定位结果处理函数
local function handle_location_result(location)
    -- 防止重入：如果正在处理中，跳过本次回调
    if gps_busy then
        return
    end
    gps_busy = true

    if location then
        -- GSensor静止检测：如果设备静止，不上报GPS漂移位置
        -- 但如果 last_reported_loc == nil（首次定位），仍要上报当前位置
        if not core.is_moving() and location.is_gps then
            if last_reported_loc then
                log.info("GSENSOR", "设备静止，使用上次有效位置上报（防漂移）")
                core.onenet_upload(last_reported_loc, function(upload_result)
                    if upload_result then
                        log.info("ONENET", "静止位置上报成功(保持)")
                    else
                        log.error("ONENET", "静止位置上报失败")
                    end
                    finish_cycle()
                end)
                return
            else
                log.info("GSENSOR", "设备静止，但无历史位置，上报当前首次定位数据")
            end
        end

        log.info("LOCATION", "====================")
        log.info("LOCATION", "定位成功")
        log.info("LOCATION", "定位类型: " .. (location.is_gps and "GPS" or "FUSION"))
        log.info("LOCATION", string.format("坐标: lat=%.6f, lon=%.6f", location.lat, location.lon))
        log.info("LOCATION", "====================")

        -- 保存为上次有效位置
        if location.is_gps then
            last_reported_loc = location
        end

        -- 通过MQTT上报到OneNET平台
        core.onenet_upload(location, function(upload_result)
            if upload_result then
                log.info("ONENET", "定位数据上报成功")
            else
                log.error("ONENET", "定位数据上报失败")
            end
            finish_cycle(location.speed)
        end)
    else
        log.error("LOCATION", "GPS定位失败")

        -- GPS定位失败，切换到融合定位
        log.info("LOCATION", "尝试融合定位(LBS+WiFi)")

        core.do_fusion_locate(function(lbs_location, wifi_data)
            if lbs_location then
                log.info("LOCATION", "融合定位成功")

                -- 上传融合定位数据到OneNET
                core.onenet_upload(lbs_location, function(upload_result)
                    if upload_result then
                        log.info("ONENET", "融合定位数据上报成功")
                    else
                        log.error("ONENET", "融合定位数据上报失败")
                    end

                    finish_cycle()
                end, wifi_data)
            else
                log.error("LOCATION", "所有定位方式均失败")
                finish_cycle()
            end
        end)
    end
end

-- 主任务
local function main_task()
    log.info("main", "启动主任务")

    -- 初始化移动网络
    core.init_network()

    -- 初始化fskv（持久化存储，用于保存远程配置）
    if fskv then
        fskv.init()
        log.info("main", "fskv初始化完成")
    end

    -- 初始化GSensor（DA221加速度传感器，消除GPS静态漂移）
    core.init_gsensor()

    -- 等待网络连接
    if not core.check_network() then
        log.error("main", "网络连接失败，无法继续")
        return
    end

    -- 初始化OneNET MQTT连接
    log.info("main", "初始化OneNET MQTT连接")
    if not core.init_onenet_mqtt() then
        log.error("main", "OneNET MQTT初始化失败，无法继续")
        return
    end

    -- 等待MQTT连接成功
    log.info("main", "等待MQTT连接...")
    local connected = sys.waitUntil("ONENET_CONNECTED", 15000)
    if not connected then
        log.error("main", "MQTT连接超时")
        return
    end
    log.info("main", "OneNET MQTT连接成功")

    -- 等待一会下行消息，接收OneNET平台可能发来的远程配置（如修改上报间隔）
    -- 设备在PSM休眠期间，平台下发的配置会缓存在服务器，订阅topic后会立即收到
    -- 通过 HTTP REST API 主动拉取期望配置（离线期间修改的 ReportInterval 等）
    -- 无论设备 PSM 休眠多久，唤醒后都能拿到最新配置
    core.fetch_desired_config()

    -- 打印当前配置
    local interval = core.get_sleep_interval()
    local mode = core.get_location_mode()
    log.info("main", "当前上报间隔: " .. (interval / 1000) .. "秒 (" .. (interval / 60000) .. "分钟)")
    log.info("main", "当前定位模式: " .. mode)

    if mode == "lbs_only" then
        -- LBS 纯定位模式：跳过 GPS，直接走基站+WiFi 融合定位
        log.info("main", "LBS纯定位模式，跳过GPS")
        core.init_wifi()

        core.do_fusion_locate(function(lbs_location, wifi_data)
            if lbs_location then
                log.info("LOCATION", "LBS定位成功")

                -- 保存为上次有效位置
                last_reported_loc = lbs_location

                core.onenet_upload(lbs_location, function(upload_result)
                    if upload_result then
                        log.info("ONENET", "LBS定位数据上报成功")
                    else
                        log.error("ONENET", "LBS定位数据上报失败")
                    end
                    finish_cycle()
                end, wifi_data)
            else
                log.error("LOCATION", "LBS定位失败")
                finish_cycle()
            end
        end)
    else
        -- 默认模式：先 GPS，失败后走 LBS
        core.init_gps()

        -- 启动GPS定位（定位成功或超时后自动回调 handle_location_result，失败时自动走OneNET LBS）
        core.start_gps(handle_location_result)

        log.info("main", "主任务执行完成（等待GPS定位结果）")
    end
end

-- 启动主任务
sys.taskInit(main_task)

-- 运行系统
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
