local MOD_NAME = "TKGBridge"
local MOD_VERSION = "0.3.0"

local bridgeRoot = os.getenv("PAL_BRIDGE_DIR") or "C:\\serverfiles\\TKGBridge"
local logsRoot = os.getenv("PAL_LOG_DIR") or "C:\\serverfiles\\Logs"
local traceEnabled = string.lower(tostring(os.getenv("PAL_BRIDGE_TRACE") or "false")) == "true"
local eventsLog = bridgeRoot .. "\\events.log"
local auditLog = bridgeRoot .. "\\audit.log"
local identityLog = bridgeRoot .. "\\identities.log"
local compatibilityLog = logsRoot .. "\\PalServer-compat.log"
local traceLog = bridgeRoot .. "\\trace.log"

local knownPlayers = {}
local chatHookRegistered = false

local function oneLine(value)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")
    return value
end

local function utcNow()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function compatNow()
    return os.date("!%Y-%m-%d %H:%M:%S")
end

local function ensurePath(path)
    os.execute('if not exist "' .. path .. '" mkdir "' .. path .. '"')
end

local function appendLine(path, line)
    local file = io.open(path, "a")
    if not file then
        return false
    end
    file:write(line .. "\n")
    file:close()
    return true
end

local function jsonEscape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return value
end

local function jsonObject(fields)
    local keys = {}
    for key in pairs(fields) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = '"' .. jsonEscape(key) .. '":"' .. jsonEscape(fields[key]) .. '"'
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function emitAudit(message)
    local line = string.format("[%s] [%s] %s", utcNow(), MOD_NAME, oneLine(message))
    print(line .. "\n")
    appendLine(auditLog, line)
end

local function emitTrace(message)
    if not traceEnabled then
        return
    end
    local line = string.format("[%s] [%s][TRACE] %s", utcNow(), MOD_NAME, oneLine(message))
    print(line .. "\n")
    appendLine(traceLog, line)
end

local function emitEvent(eventType, fields)
    fields = fields or {}
    fields.type = eventType
    fields.timestamp = utcNow()
    fields.mod = MOD_NAME
    fields.version = MOD_VERSION

    local payload = jsonObject(fields)
    appendLine(eventsLog, payload)
    emitAudit("event=" .. eventType .. " payload=" .. payload)
end

local function emitCompatibilityChat(name, message, userId, playerId)
    local line = string.format(
        "[%s][info] [Chat::Global]['%s' (UserId=%s, IP=unknown, UID=%s)][Admin]: %s",
        compatNow(),
        oneLine(name),
        oneLine(userId),
        oneLine(playerId),
        oneLine(message))
    appendLine(compatibilityLog, line)
end

local function emitCompatibilityJoin(name, userId, playerId)
    local line = string.format(
        "[%s][info] %s joined the server. (User id: %s, Player id: %s)",
        compatNow(),
        oneLine(name),
        oneLine(userId),
        oneLine(playerId))
    appendLine(compatibilityLog, line)
end

local function emitCompatibilityLeave(name, userId)
    local line = string.format(
        "[%s][info] %s left the server. (User id: %s)",
        compatNow(),
        oneLine(name),
        oneLine(userId))
    appendLine(compatibilityLog, line)
end

local function recordIdentity(name, userId, playerId, source)
    local line = string.format(
        "%s source=%s name=%s userId=%s playerId=%s",
        utcNow(),
        oneLine(source),
        oneLine(name),
        oneLine(userId),
        oneLine(playerId))
    appendLine(identityLog, line)
end

local function hex32(value)
    local formatted = string.format("%016x", tonumber(value) or 0)
    return formatted:sub(-8)
end

local function guidToString(guid)
    if not guid then
        return ""
    end

    local ok, value = pcall(function()
        return string.lower(
            hex32(guid.A) ..
            hex32(guid.B) ..
            hex32(guid.C) ..
            hex32(guid.D))
    end)

    if ok then
        return value
    end

    return ""
end

local function normalizeId(value)
    return string.lower(oneLine(value):gsub("[{}%-]", ""))
end

local function safeToString(value)
    if value == nil then
        return ""
    end

    local ok, result = pcall(function()
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            return tostring(value)
        end

        if value.ToString then
            return value:ToString()
        end

        if value.get then
            return tostring(value:get())
        end

        return tostring(value)
    end)

    if ok then
        return oneLine(result)
    end

    return ""
end

local function firstNonEmpty(candidates)
    for _, value in ipairs(candidates) do
        local normalized = oneLine(value)
        if normalized ~= "" and normalized ~= "None" and normalized ~= "nil" then
            return normalized
        end
    end
    return ""
end

local function safeProperty(object, propertyName)
    local ok, value = pcall(function()
        return object[propertyName]
    end)
    if not ok then
        return nil
    end
    return value
end

local function dumpPlayerStateProperties(playerState, reason)
    if not traceEnabled then
        return
    end

    local interestingProperties = {
        "PlayerName",
        "NickName",
        "AccountName",
        "OtomoName",
        "PlayerId",
        "PlatformPlayerId",
        "PlatformUserId",
        "UniqueNetId",
        "LoginId",
        "PlayerUId"
    }

    local fields = {
        reason = reason or "trace",
        object = safeToString(playerState.GetFullName and playerState:GetFullName() or tostring(playerState))
    }

    for _, propertyName in ipairs(interestingProperties) do
        local value = safeProperty(playerState, propertyName)
        if propertyName == "PlayerUId" then
            fields[propertyName] = firstNonEmpty({
                guidToString(value),
                safeToString(value)
            })
        else
            fields[propertyName] = safeToString(value)
        end
    end

    emitTrace("player_state=" .. jsonObject(fields))
end

local function playerStateIdentity(playerState)
    local playerId = guidToString(safeProperty(playerState, "PlayerUId"))
    local name = firstNonEmpty({
        safeToString(safeProperty(playerState, "PlayerName")),
        safeToString(safeProperty(playerState, "NickName")),
        safeToString(safeProperty(playerState, "AccountName")),
        safeToString(safeProperty(playerState, "OtomoName"))
    })

    local userId = firstNonEmpty({
        safeToString(safeProperty(playerState, "PlayerId")),
        safeToString(safeProperty(playerState, "PlatformPlayerId")),
        safeToString(safeProperty(playerState, "PlatformUserId")),
        safeToString(safeProperty(playerState, "UniqueNetId")),
        safeToString(safeProperty(playerState, "LoginId"))
    })

    if playerId == "" then
        playerId = normalizeId(safeToString(safeProperty(playerState, "PlayerUId")))
    end

    if name == "" then
        name = "unknown"
    end

    if userId == "" then
        userId = "unknown"
    end

    return {
        name = name,
        userId = userId,
        playerId = playerId
    }
end

local function emitConnectCodeRequest(name, userId, playerId, message)
    emitEvent("connect_code_requested", {
        name = name,
        userId = userId,
        playerId = playerId,
        message = message
    })
end

local function emitChat(name, userId, playerId, message)
    recordIdentity(name, userId, playerId, "chat")
    emitEvent("chat", {
        name = name,
        userId = userId,
        playerId = playerId,
        message = message
    })
    emitCompatibilityChat(name, message, userId, playerId)

    if tostring(message or ""):lower() == "!getconnectcode" then
        emitConnectCodeRequest(name, userId, playerId, message)
    end
end

local function emitJoin(name, userId, playerId)
    recordIdentity(name, userId, playerId, "join")
    emitEvent("player_join", {
        name = name,
        userId = userId,
        playerId = playerId
    })
    emitCompatibilityJoin(name, userId, playerId)
end

local function emitLeave(name, userId, playerId)
    emitEvent("player_leave", {
        name = name,
        userId = userId,
        playerId = playerId
    })
    emitCompatibilityLeave(name, userId)
end

local function stateKey(identity, fallback)
    local candidate = normalizeId(identity.playerId)
    if candidate ~= "" then
        return candidate
    end
    return fallback
end

local function snapshotPlayers()
    local snapshot = {}
    local states = FindAllOf("PalPlayerState")
    if not states then
        return snapshot
    end

    for _, state in ipairs(states) do
        local ok, valid = pcall(function()
            return state:IsValid()
        end)
        if ok and valid then
            local identity = playerStateIdentity(state)
            dumpPlayerStateProperties(state, "snapshot")
            local fallback = safeToString(state.GetFullName and state:GetFullName() or tostring(state))
            snapshot[stateKey(identity, fallback)] = identity
        end
    end

    return snapshot
end

local function diffPlayers()
    local current = snapshotPlayers()

    for key, identity in pairs(current) do
        if knownPlayers[key] == nil then
            emitJoin(identity.name, identity.userId, identity.playerId)
        end
    end

    for key, identity in pairs(knownPlayers) do
        if current[key] == nil then
            emitLeave(identity.name, identity.userId, identity.playerId)
        end
    end

    knownPlayers = current
end

local function registerChatHook()
    if chatHookRegistered then
        return
    end

    local ok, preId, postId = pcall(function()
        return RegisterHook("/Script/Pal.PalPlayerState:EnterChat_Receive", function(context, chatParameter)
            local success, err = pcall(function()
                local message = chatParameter:get()
                local sender = safeToString(message.Sender)
                local text = safeToString(message.Message)
                local playerId = guidToString(message.SenderPlayerUId)
                local userId = "unknown"

                if context and context:IsValid() then
                    local identity = playerStateIdentity(context)
                    dumpPlayerStateProperties(context, "chat")
                    sender = firstNonEmpty({ sender, identity.name, "unknown" })
                    userId = identity.userId
                    if playerId == "" then
                        playerId = identity.playerId
                    end
                end

                emitChat(sender, userId, playerId, text)
            end)

            if not success then
                emitAudit("chat_hook_error=" .. oneLine(err))
            end
        end)
    end)

    if ok then
        chatHookRegistered = true
        emitAudit("registered_chat_hook pre=" .. oneLine(preId) .. " post=" .. oneLine(postId))
    else
        emitAudit("failed_chat_hook_registration=" .. oneLine(preId))
    end
end

local function installHooks()
    emitAudit("bridge directories: " .. bridgeRoot)
    emitAudit("compatibility log: " .. compatibilityLog)

    registerChatHook()

    local okNotify, errNotify = pcall(function()
        NotifyOnNewObject("/Script/Pal.PalPlayerState", function(newObject)
            local ok, err = pcall(function()
                if newObject and newObject:IsValid() then
                    local identity = playerStateIdentity(newObject)
                    dumpPlayerStateProperties(newObject, "new_object")
                    recordIdentity(identity.name, identity.userId, identity.playerId, "new_object")
                    emitAudit("observed_new_player_state=" .. oneLine(identity.name) .. " userId=" .. oneLine(identity.userId) .. " playerId=" .. oneLine(identity.playerId))
                end
            end)

            if not ok then
                emitAudit("notify_player_state_error=" .. oneLine(err))
            end
        end)
    end)

    if okNotify then
        emitAudit("registered NotifyOnNewObject for /Script/Pal.PalPlayerState")
    else
        emitAudit("failed NotifyOnNewObject registration=" .. oneLine(errNotify))
    end

    local okLoop, errLoop = pcall(function()
        LoopAsync(3000, function()
            local ok, err = pcall(diffPlayers)
            if not ok then
                emitAudit("player_diff_error=" .. oneLine(err))
            end
            return false
        end)
    end)

    if okLoop then
        emitAudit("registered player diff loop at 3000ms")
    else
        emitAudit("failed player diff loop registration=" .. oneLine(errLoop))
    end

    diffPlayers()
    emitEvent("bridge_ready", {
        status = "active",
        chatHook = chatHookRegistered and "registered" or "missing",
        joinLeaveStrategy = "player_state_diff"
    })
end

ensurePath(bridgeRoot)
ensurePath(logsRoot)

emitAudit("Loaded " .. MOD_NAME .. " version " .. MOD_VERSION)
emitAudit("Initializing clean-room bridge runtime")
emitAudit("Trace mode: " .. (traceEnabled and "enabled" or "disabled"))
installHooks()

_G.TKGBridge = {
    emitChat = emitChat,
    emitJoin = emitJoin,
    emitLeave = emitLeave,
    emitConnectCodeRequest = emitConnectCodeRequest,
    diffPlayers = diffPlayers
}
