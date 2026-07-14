--[[
@module  iotauth
@summary MQTT平台认证工具（纯Lua实现，无需C组件）
@version 2.0.0
@date    2026.07.13
@author  GitHub Copilot
@usage
生成OneNET Studio平台的MQTT认证三元组
本文件为纯Lua实现，算法与C模块iotauth完全一致
]]

local iotauth = {}

-- hex字符串转原始字节
local function hex_to_bytes(hex)
    if not hex or #hex == 0 then return nil end
    local bytes = {}
    for i = 1, #hex, 2 do
        local byte_str = hex:sub(i, i + 1)
        local byte_num = tonumber(byte_str, 16)
        if byte_num then
            bytes[#bytes + 1] = string.char(byte_num)
        end
    end
    return table.concat(bytes)
end

-- URL编码表：与C版iotauth的url_encoding_for_token完全一致
local URL_ENCODE_MAP = {
    ["+"] = "%2B",
    [" "] = "%20",
    ["/"] = "%2F",
    ["?"] = "%3F",
    ["%"] = "%25",
    ["#"] = "%23",
    ["&"] = "%26",
    ["="] = "%3D",
}

--- 对指定字符做URL编码（仅编码特殊字符，与C版实现一致）
local function url_encode_token(str)
    if not str then return "" end
    local result = {}
    for i = 1, #str do
        local ch = str:sub(i, i)
        if URL_ENCODE_MAP[ch] then
            table.insert(result, URL_ENCODE_MAP[ch])
        else
            table.insert(result, ch)
        end
    end
    return table.concat(result)
end

--- OneNET Studio平台认证
-- 算法与C模块 iotauth.onenet() 完全一致：
--   1. Base64解码device_secret → key
--   2. 构建签名字符串: "{et}\n{method}\n{res}\n{version}"
--   3. HMAC-MD5签名 → sign_bytes
--   4. Base64编码sign_bytes → sign_b64
--   5. 分别URL编码res和sign_b64
--   6. 组装最终密码: "version={v}&res={res}&et={et}&method={m}&sign={sign}"
-- @param product_id 产品ID（OneNET Studio英文数字混合）
-- @param device_name 设备名称
-- @param device_secret 设备密钥（Base64编码字符串）
-- @return client_id, user_name, password MQTT三元组
function iotauth.onenet(product_id, device_name, device_secret)
    if not product_id or not device_name or not device_secret then
        log.error("iotauth", "OneNET参数不完整")
        return nil, nil, nil
    end

    -- 算法: sign = base64(hmac_sha1(base64decode(key), utf-8(StringForSignature)))
    -- StringForSignature = "{et}\n{method}\n{res}\n{version}"
    -- version 仅支持 "2018-10-31"（官方文档规定）
    local method = "sha1"
    local version = "2018-10-31"
    local et = "32472115200"  -- 远未来时间戳，永不过期（与C版iotauth一致）
    local res = string.format("products/%s/devices/%s", product_id, device_name)

    -- 1. Base64解码device_secret
    local key_bytes = crypto.base64_decode(device_secret)
    if not key_bytes or #key_bytes == 0 then
        log.error("iotauth", "Base64解码设备密钥失败")
        return nil, nil, nil
    end

    -- 2. 构建签名字符串: "{et}\n{method}\n{res}\n{version}"
    local sign_str = string.format("%s\n%s\n%s\n%s", et, method, res, version)
    log.info("iotauth", "待签名字符串: " .. sign_str)

    -- 3. HMAC-SHA1签名（返回hex字符串，40字符）
    local hmac_hex = crypto.hmac_sha1(sign_str, key_bytes)
    if not hmac_hex or #hmac_hex == 0 then
        log.error("iotauth", "HMAC-SHA1签名失败")
        return nil, nil, nil
    end

    -- 4. hex字符串 → 原始20字节 → Base64编码
    local hmac_raw = hex_to_bytes(hmac_hex)
    local sign_b64 = crypto.base64_encode(hmac_raw)

    -- 5. 分别URL编码res和sign
    local res_encoded = url_encode_token(res)
    local sign_encoded = url_encode_token(sign_b64)

    -- 6. 组装最终token
    -- 格式: version={version}&res={res}&et={et}&method={method}&sign={sign}
    local password = string.format("version=%s&res=%s&et=%s&method=%s&sign=%s",
        version, res_encoded, et, method, sign_encoded)

    -- client_id = device_name, user_name = product_id
    local client_id = device_name
    local user_name = product_id

    log.info("iotauth", "生成的password: " .. password)
    log.info("iotauth", "OneNET认证成功")
    return client_id, user_name, password
end

return iotauth
