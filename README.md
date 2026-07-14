# 🐾 Pet Tracker — 4G GPS/北斗宠物定位器

基于 **Air780EGP** 模组的 4G 宠物定位器，支持 GPS + LBS + WiFi 多模定位，配合 **OneNET Studio** 云平台和 **微信小程序**，实现实时追踪、历史轨迹、远程控制。

---

## 项目结构

```
gps_anti_lost/
├── gps_anti_lost/              # LuatOS 固件 (Lua)
│   ├── config.lua              # 配置文件（OneNET 参数、GPS、PSM 等）
│   ├── core.lua                # 核心逻辑（定位、上传、省电）
│   ├── main.lua                # 主任务流程
│   └── iotauth.lua             # HMAC-SHA1 鉴权
│
└── gps_anti_lost_weapp/        # 微信小程序
    ├── pages/
    │   ├── index/              # 设备列表
    │   ├── device/             # 设备详情 + 地图
    │   ├── history/            # 历史数据 + 轨迹
    │   ├── config/             # 设备管理
    │   └── about/              # 关于
    ├── custom-tab-bar/         # 自定义毛玻璃标签栏
    ├── utils/
    │   └── api.js              # OneNET REST API 封装
    ├── app.js                  # 全局状态
    ├── app.json                # 小程序配置
    └── app.wxss                # 全局样式
```

---

## 固件 (LuatOS)

### 硬件需求

| 组件 | 说明 |
|------|------|
| 模组 | Air780EGP (Air780EHM_Air780EHV_Air780EGH 系列) |
| GPS 天线 | 有源 GPS/北斗天线 |
| 4G 天线 | LTE 天线 |
| SIM 卡 | 4G IoT 卡（推荐合宙 IoT 卡） |
| 电池 | 3.7V 锂电池 + 充电管理 |

### 定位模式

| 模式 | 说明 |
|------|------|
| `GPS` | GPS/北斗卫星定位（精度最高，室内无效） |
| `LBS` | 基站定位（精度较低，全覆盖） |
| `GPS_LBS` | GPS 优先，卫星信号弱时自动回退基站 |
| `ALL` | GPS + LBS + WiFi 融合定位 |

### 功能特性

- **多模定位**：GPS/北斗 + 基站 + WiFi 热点扫描
- **OneNET 上传**：MQTT+TLS 接入，JSON 数据上报
- **低功耗**：PSM 省电模式（可配置上报间隔）
- **远程配置**：通过 OneNET 期望属性切换定位模式、上报间隔
- **坐标纠偏**：内置 GCJ-02/WGS-84 坐标互转

### 配置

编辑 `config.lua`：

```lua
-- OneNET 配置
PRODUCT_ID = "your_product_id"
DEVICE_NAME = "your_device_name"
DEVICE_SECRET = "your_device_secret"

-- 定位模式（默认）
LOCATION_MODE = "GPS_LBS"

-- 上报间隔（默认 120 秒）
REPORT_INTERVAL = 120

-- PSM 省电（默认开启）
PSM_ENABLE = true
```

### 刷机

1. 安装 [LuaTools](https://luatools.openluat.com/)
2. 将 `gps_anti_lost/` 目录下的 4 个 Lua 文件打包为脚本
3. 通过 LuaTools 刷入 Air780EGP 模组
4. 确保 config.lua 中的 OneNET 参数与云端一致

---

## 微信小程序

### 功能

| 页面 | 功能 |
|------|------|
| 🏠 **设备列表** | 多设备卡片、在线状态、位置预览、下拉刷新 |
| 🗺️ **设备详情** | 地图显示位置、卫星/普通地图切换、复制坐标、外部导航 |
| 📊 **历史数据** | 折线图（属性选择/时间范围）、轨迹回放、统计 |
| ⚙️ **设备管理** | 添加/编辑/删除设备、HMAC-SHA1 Token 自动生成 |
| ℹ️ **关于** | 技术栈、版本信息 |

### 远程控制

通过 OneNET 期望属性下发：

| 属性 | 说明 |
|------|------|
| `LocationMode` | 切换定位模式（GPS/LBS/GPS_LBS/ALL）|
| `ReportInterval` | 修改上报间隔（60-3600 秒）|

### 使用

1. 打开微信小程序 → **配置页**
2. 添加设备：填入产品 ID、设备名称、设备密钥
3. 返回首页查看设备状态和位置
4. 在设备详情页可远程切换定位模式、修改上报间隔

> 设备密钥在 OneNET 控制台 → 设备列表 → 点击设备 → 设备密钥获取

---

## 技术栈

### 固件

| 技术 | 用途 |
|------|------|
| **LuatOS** | 嵌入式 Lua 操作系统 |
| **Air780EGP** | 4G Cat.1 + GPS/北斗模组 |
| **OneNET Studio** | 物联网云平台 |
| **MQTT+TLS** | 数据上传与指令下发 |
| **HMAC-SHA1** | 设备接入鉴权 |
| **exgnss** | GPS/北斗卫星定位 |
| **wlan** | WiFi 热点扫描 |

### 小程序

| 技术 | 用途 |
|------|------|
| **微信小程序** | 跨平台移动端 |
| **Canvas 2D** | 历史数据图表 |
| **map 组件** | 实时位置与轨迹 |
| **毛玻璃 (Glassmorphism)** | UI 设计风格 |
| **OneNET REST API** | 设备属性、历史数据查询 |

---

## 许可

MIT License

---

## 致谢

- [LuatOS](https://gitee.com/openLuat/LuatOS) — 嵌入式 Lua 框架
- [合宙通信](https://www.openluat.com/) — Air780E 系列模组
- [OneNET](https://open.iot.10086.cn/) — 物联网云平台
