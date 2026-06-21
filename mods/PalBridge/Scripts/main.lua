local MOD_NAME = "PalBridge"
local MOD_VERSION = "0.2.0"
local queueRoot = os.getenv("PAL_BRIDGE_QUEUE") or "C:\\serverfiles\\PalBridge\\queue"
local logsRoot = os.getenv("PAL_LOGS_DIR") or "C:\\serverfiles\\Logs"
local inDir = queueRoot .. "\\in"
local workDir = queueRoot .. "\\work"
local outDir = queueRoot .. "\\out"
local identityLog = logsRoot .. "\\PalBridge-chat-identities.log"
local processing = false

local function oneLine(value)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")
    return value
end

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, oneLine(message)))
end

local function ensureDirectories()
    os.execute('if not exist "' .. inDir .. '" mkdir "' .. inDir .. '"')
    os.execute('if not exist "' .. workDir .. '" mkdir "' .. workDir .. '"')
    os.execute('if not exist "' .. outDir .. '" mkdir "' .. outDir .. '"')
    os.execute('if not exist "' .. logsRoot .. '" mkdir "' .. logsRoot .. '"')
end

local function readKeyValues(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "cannot open request"
    end

    local values = {}
    for line in file:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            values[key] = value
        end
    end
    file:close()
    return values
end

local function writeAtomic(path, content)
    local temporary = path .. ".tmp"
    local file = io.open(temporary, "w")
    if not file then
        return false
    end
    file:write(content)
    file:close()
    os.remove(path)
    return os.rename(temporary, path)
end

local function appendIdentityLog(characterId, sender, message)
    local file = io.open(identityLog, "a")
    if not file then
        return
    end
    file:write(string.format(
        "%s [PALBRIDGE_CHAT] character=%s name=%s message=%s\n",
        os.date("!%Y-%m-%d %H:%M:%SZ"),
        oneLine(characterId),
        oneLine(sender),
        oneLine(message)))
    file:close()
end

local function hex32(value)
    local formatted = string.format("%016x", tonumber(value) or 0)
    return formatted:sub(-8)
end

local function guidToString(guid)
    if not guid then
        return ""
    end
    return string.lower(
        hex32(guid.A) ..
        hex32(guid.B) ..
        hex32(guid.C) ..
        hex32(guid.D))
end

local function normalizeId(value)
    return string.lower(oneLine(value):gsub("[{}%-]", ""))
end

local function playerStateCharacterIds(playerState)
    local uid = playerState.PlayerUId
    local full = guidToString(uid)
    local legacy = full:sub(1, 8) .. "000000000000000000000000"
    return full, legacy
end

local function findPlayerState(characterId)
    local target = normalizeId(characterId)
    local states = FindAllOf("PalPlayerState")
    if not states then
        return nil
    end

    for _, state in ipairs(states) do
        if state:IsValid() then
            local ok, full, legacy = pcall(function()
                local first, second = playerStateCharacterIds(state)
                return first, second
            end)
            if ok and (target == normalizeId(full) or target == normalizeId(legacy)) then
                return state
            end
        end
    end
    return nil
end

local function enumNumber(value)
    if type(value) == "number" then
        return value
    end
    local ok, inner = pcall(function()
        return value:get()
    end)
    if ok then
        return tonumber(inner)
    end
    return tonumber(value)
end

local function operationCode(code)
    if code == 15 then
        return "invalid_item"
    end
    if code == 16 or code == 4 or code == 5 or code == 6 then
        return "inventory_full"
    end
    return "item_operation_" .. tostring(code)
end

local function responseText(request, status, code, message)
    return
        "version=1\r\n" ..
        "delivery=" .. oneLine(request.delivery) .. "\r\n" ..
        "character=" .. oneLine(request.character) .. "\r\n" ..
        "player=" .. oneLine(request.player) .. "\r\n" ..
        "item=" .. oneLine(request.item) .. "\r\n" ..
        "count=" .. oneLine(request.count) .. "\r\n" ..
        "status=" .. oneLine(status) .. "\r\n" ..
        "code=" .. oneLine(code) .. "\r\n" ..
        "message=" .. oneLine(message) .. "\r\n"
end

local function finishRequest(request, workPath, responsePath, status, code, message)
    writeAtomic(responsePath, responseText(request, status, code, message))
    os.remove(workPath)
    processing = false
    log(string.format(
        "Delivery %s finished status=%s code=%s",
        oneLine(request.delivery),
        status,
        code))
end

local function executeRequest(request, workPath, responsePath)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local playerState = findPlayerState(request.character)
            if not playerState then
                finishRequest(request, workPath, responsePath, "failed", "character_offline", "Character is not online")
                return
            end

            local inventory = playerState:GetInventoryData()
            if not inventory or not inventory:IsValid() then
                finishRequest(request, workPath, responsePath, "failed", "inventory_unavailable", "Player inventory is unavailable")
                return
            end

            local result = inventory:AddItem_ServerInternal(
                FName(request.item),
                tonumber(request.count),
                false,
                0.0)
            local code = enumNumber(result)
            if code == 0 or code == 1 then
                finishRequest(request, workPath, responsePath, "delivered", "success", "Item added to inventory")
            elseif code == nil then
                finishRequest(
                    request,
                    workPath,
                    responsePath,
                    "uncertain",
                    "unknown_result",
                    "The item function returned an unreadable result; do not retry automatically")
            else
                finishRequest(
                    request,
                    workPath,
                    responsePath,
                    "failed",
                    operationCode(code),
                    "Palworld rejected the item operation with result " .. tostring(code))
            end
        end)

        if not ok then
            finishRequest(
                request,
                workPath,
                responsePath,
                "failed",
                "mod_exception",
                tostring(err))
        end
    end)
end

local function firstRequestName()
    local pipe = io.popen('dir /b /a-d "' .. inDir .. '\\*.request" 2>nul')
    if not pipe then
        return nil
    end
    local name = pipe:read("*l")
    pipe:close()
    return name
end

local function pollQueue()
    if processing then
        return
    end

    local name = firstRequestName()
    if not name or name == "" then
        return
    end

    local requestPath = inDir .. "\\" .. name
    local workPath = workDir .. "\\" .. name
    if not os.rename(requestPath, workPath) then
        return
    end

    processing = true
    local request, readError = readKeyValues(workPath)
    local responsePath = outDir .. "\\" .. name:gsub("%.request$", ".response")
    if not request then
        request = {
            delivery = "unknown",
            character = "unknown",
            player = "unknown",
            item = "unknown",
            count = "0"
        }
        finishRequest(request, workPath, responsePath, "failed", "invalid_request", readError)
        return
    end

    if request.version ~= "1" or
        not request.delivery or
        not request.character or
        not request.player or
        not request.item or
        not tonumber(request.count) or
        tonumber(request.count) < 1 then
        finishRequest(request, workPath, responsePath, "failed", "invalid_request", "Required request fields are missing")
        return
    end

    executeRequest(request, workPath, responsePath)
end

ensureDirectories()

RegisterHook("/Script/Pal.PalPlayerState:EnterChat_Receive", function(context, chatParameter)
    local ok, err = pcall(function()
        local message = chatParameter:get()
        local sender = message.Sender:ToString()
        local text = message.Message:ToString()
        local characterId = guidToString(message.SenderPlayerUId)

        -- This is the native-style line GSA's Palworld log ingestion must see.
        print(string.format("[CHAT] <%s> %s\n", oneLine(sender), oneLine(text)))
        appendIdentityLog(characterId, sender, text)
    end)
    if not ok then
        log("Chat hook failed: " .. tostring(err))
    end
end)

LoopAsync(250, function()
    local ok, err = pcall(pollQueue)
    if not ok then
        processing = false
        log("Queue poll failed: " .. tostring(err))
    end
    return false
end)

log("v" .. MOD_VERSION .. " loaded; chat logging and delivery queue are active")
