--=============================================================================
-- AE2 -> MineColonies request exporter v11 (job-aware paxels + live export)
-- Advanced Peripherals Colony Integrator + ME Bridge + Ender Chest
--
-- Target build:
--   All The Mods 10 5.3.1
--   Advanced Peripherals 0.7.57b
--   CC: Tweaked 1.116.2
--   Applied Energistics 2 19.2.17
--
-- Save as "startup" for automatic launch. LIVE MODE is enabled by default.
--
-- Confirmed/preferred ME Bridge methods from the working monitor:
--   getItems, isOnline, isConnected
-- The exporter additionally requires:
--   exportItem
-- Optional autocrafting methods:
--   isCraftable, craftItem, getCraftingTasks
--
-- Colony Integrator methods used:
--   getRequests
-- Optional:
--   isInColony
--=============================================================================

local CONFIG = {
    dryRun             = false,  -- LIVE MODE: items may be exported and crafts submitted
    pollInterval       = 30,     -- older implementation warns against aggressive scans
    exportDirection    = "right",-- side of ME Bridge touching the source barrel
    maxPerExport       = 64,
    maxPerCycle        = 256,

    -- AE2 autocrafting
    enableCrafting      = true,
    craftRetrySeconds   = 300,
    maxCraftPerCycle    = 256,

    -- Output/backpressure protection. For exact inventory fullness detection,
    -- attach a wired modem to the source barrel and put its peripheral name here.
    outputInventoryName = nil,   -- example: "minecraft:barrel_3"
    outputPauseSeconds  = 120,

    -- Optional Advanced Monitor dashboard. A 5x3 wall at scale 0.5 is supported;
    -- larger walls automatically show more request rows.
    monitorTextScale    = 0.5,
    monitorRefresh      = 0.5,

    -- Exact fingerprints are preferred. Name fallback is conservative.
    allowNameFallback  = true,
    skipComponentItems = true,   -- skip component-sensitive items unless fingerprint matches

    -- MineColonies tools/armor: choose the highest material tier allowed by
    -- the request description, then fall back downward only if unavailable
    -- and not craftable.
    preferHighestAllowedGear = true,

    -- Relevant workers: prefer one Mekanism Tools paxel over separate
    -- pickaxe/axe/shovel requests. Paxels do NOT replace hoes, swords, or armor.
    preferPaxelsForRelevantJobs = true,

    -- Matched case-insensitively against request target, name, and description.
    paxelJobPatterns = {
        "mine",
        "miner",
        "builder",
        "builder's hut",
        "construction",
        "quarry",
        "lumberjack",
        "forester",
        "woodworker",
        "stonemason",
        "stone mason",
        "crusher",
        "sifter",
        "composter",
    },

    -- Jobs where paxels should never replace requested tools, even if another
    -- word happens to match. Extend this list if a future job is misclassified.
    paxelJobBlacklistPatterns = {
        "farmer",
        "plantation",
        "guard",
        "knight",
        "archer",
        "restaurant",
        "cook",
    },

    -- Colony-managed requests which should not be supplied from AE2.
    -- These are matched case-insensitively against request.name and request.desc.
    colonyManagedRequestPatterns = {
        "smeltable ore",
    },

    -- Architect's Cutter / Domum Ornamentum behavior:
    -- export an exact stored fingerprint when available; otherwise report it as MANUAL.
    reportArchitectCutter = true,

    stateFile          = "colony_export_state.txt",
    logFile            = "colony_export.log",
    missingFile        = "missing_items.txt",
    snapshotFile       = "colony_export_snapshot.txt",
    writeSnapshot      = true,
    snapshotItemLimit  = 250,    -- prevents CC computer disk exhaustion
    staleAfterSeconds  = 3600,
    debug              = true,

    blacklistNames = {
        ["minecraft:air"] = true,
    },

    -- Disabled by default. Add tags only after viewing snapshot data.
    blacklistTags = {
        -- ["c:foods"] = true,
    },
}

--============================== dashboard state ==============================

local monitor = peripheral.find("monitor")
local dashboard = {
    status = "STARTING",
    message = "Waiting for first scan",
    requestCount = 0,
    moved = 0,
    crafted = 0,
    unresolved = {},
    lastUpdate = 0,
    cycleRunning = false,
}

local DASH_COLORS = {
    bg = colors.black,
    titleBg = colors.blue,
    title = colors.white,
    label = colors.lightGray,
    value = colors.white,
    good = colors.lime,
    warn = colors.orange,
    bad = colors.red,
    info = colors.cyan,
    craft = colors.yellow,
    manual = colors.magenta,
    colony = colors.lightBlue,
    panel = colors.gray,
}

local function publishDashboard(status, message, unresolved, requestCount, moved, crafted)
    dashboard.status = status or dashboard.status
    dashboard.message = message or dashboard.message
    dashboard.unresolved = unresolved or dashboard.unresolved
    dashboard.requestCount = requestCount or dashboard.requestCount
    dashboard.moved = moved or 0
    dashboard.crafted = crafted or 0
    dashboard.lastUpdate = math.floor(os.epoch("utc") / 1000)
end

--============================== helpers ======================================

local function unixNow()
    return math.floor(os.epoch("utc") / 1000)
end

local function normalizeCount(value)
    value = tonumber(value) or 0
    return math.max(0, math.floor(value))
end

local function log(message)
    local stamp = textutils.formatTime(os.time(), true)
    local line = ("[%s] %s"):format(stamp, tostring(message))
    print(line)

    local file = fs.open(CONFIG.logFile, "a")
    if file then
        file.writeLine(line)
        file.close()
    end
end

local function safeCall(label, fn, ...)
    local packed = table.pack(pcall(fn, ...))
    if not packed[1] then
        return nil, ("%s failed: %s"):format(label, tostring(packed[2]))
    end
    return packed[2], packed[3]
end

local function hasMethod(object, method)
    return object and type(object[method]) == "function"
end

local function findPeripheral(types)
    for _, peripheralType in ipairs(types) do
        local found = peripheral.find(peripheralType)
        if found then return found, peripheralType end
    end
    return nil
end

local function deepSerializable(value, seen)
    local valueType = type(value)

    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end
    if valueType ~= "table" then return nil end

    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true

    local out = {}
    for key, child in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            local clean = deepSerializable(child, seen)
            if clean ~= nil then out[key] = clean end
        end
    end

    seen[value] = nil
    return out
end

local function compactItem(item)
    if type(item) ~= "table" then return nil end
    return {
        name = item.name,
        displayName = item.displayName,
        count = item.count or item.amount,
        fingerprint = item.fingerprint,
        maxStackSize = item.maxStackSize,
        tags = deepSerializable(item.tags),
        components = deepSerializable(item.components),
    }
end

local function compactRequest(request)
    if type(request) ~= "table" then return nil end

    local alternatives = {}
    if type(request.items) == "table" then
        for i, item in ipairs(request.items) do
            alternatives[i] = compactItem(item)
        end
    end

    return {
        id = request.id,
        name = request.name,
        desc = request.desc,
        target = request.target,
        state = request.state,
        count = request.count,
        minCount = request.minCount,
        items = alternatives,
    }
end

local function writeSnapshot(requests, items)
    if not CONFIG.writeSnapshot then return end

    local compactRequests = {}
    for i, request in ipairs(requests or {}) do
        compactRequests[i] = compactRequest(request)
    end

    local compactItems = {}
    local limit = math.min(#(items or {}), CONFIG.snapshotItemLimit)
    for i = 1, limit do
        compactItems[i] = compactItem(items[i])
    end

    local payload = {
        note = "Compact diagnostic snapshot; ME items may be truncated.",
        totalRequestCount = #(requests or {}),
        totalMEItemCount = #(items or {}),
        savedMEItemCount = limit,
        requests = compactRequests,
        items = compactItems,
    }

    local serialized = "return " .. textutils.serialize(payload)

    -- Remove the old file first so a prior oversized file cannot consume space.
    if fs.exists(CONFIG.snapshotFile) then fs.delete(CONFIG.snapshotFile) end

    local free = fs.getFreeSpace("/")
    if type(free) == "number" and #serialized + 1024 > free then
        log(("WARNING: snapshot skipped; need %d bytes but only %d free")
            :format(#serialized + 1024, free))
        return
    end

    local file = fs.open(CONFIG.snapshotFile, "w")
    if not file then
        log("WARNING: unable to open snapshot file")
        return
    end

    file.write(serialized)
    file.close()
end

local function loadState()
    if not fs.exists(CONFIG.stateFile) then return { requests = {} } end

    local file = fs.open(CONFIG.stateFile, "r")
    if not file then return { requests = {} } end
    local raw = file.readAll()
    file.close()

    local state = textutils.unserialize(raw)
    if type(state) ~= "table" then state = {} end
    if type(state.requests) ~= "table" then state.requests = {} end
    return state
end

local function saveState(state)
    if CONFIG.dryRun then return end

    local file = fs.open(CONFIG.stateFile, "w")
    if not file then
        log("WARNING: could not write state file")
        return
    end

    file.write(textutils.serialize(state))
    file.close()
end

local function requestAmount(request)
    local amount = normalizeCount(request.count)
    if amount > 0 then return amount end
    return normalizeCount(request.minCount)
end

local function itemAmount(item)
    return normalizeCount(item and (item.count or item.amount))
end

local function hasComponents(item)
    return type(item and item.components) == "table" and next(item.components) ~= nil
end

local function hasBlockedTag(item)
    if type(item and item.tags) ~= "table" then return false end

    for _, tag in pairs(item.tags) do
        if type(tag) == "string" and CONFIG.blacklistTags[tag] then return true end
    end
    return false
end

--============================== peripheral setup =============================

local bridge, bridgeType = findPeripheral({ "me_bridge", "meBridge" })
if not bridge then
    error("No ME Bridge found on the wired peripheral network.", 0)
end

local colony, colonyType = findPeripheral({ "colony_integrator", "colonyIntegrator" })
if not colony then
    error("No Colony Integrator found on the wired peripheral network.", 0)
end

for _, required in ipairs({ "getItems", "exportItem" }) do
    if not hasMethod(bridge, required) then
        error("ME Bridge missing required method: " .. required, 0)
    end
end

if not hasMethod(colony, "getRequests") then
    error("Colony Integrator missing required method: getRequests", 0)
end

if hasMethod(colony, "isInColony") then
    local inColony, err = safeCall("isInColony", colony.isInColony)
    if inColony == false then error("Colony Integrator is not inside a colony.", 0) end
    if inColony == nil and err then log("WARNING: " .. err) end
end

log(("Found %s and %s"):format(bridgeType, colonyType))
log(("Mode: %s | export side: %s")
    :format(CONFIG.dryRun and "DRY RUN" or "LIVE", CONFIG.exportDirection))

if monitor then
    monitor.setTextScale(CONFIG.monitorTextScale)
    monitor.setBackgroundColor(DASH_COLORS.bg)
    monitor.setTextColor(DASH_COLORS.value)
    monitor.clear()
    log(("Found monitor %s (%dx%d)")
        :format(peripheral.getName(monitor), monitor.getSize()))
else
    log("No monitor found; terminal and files only")
end

local outputInventory = nil
if CONFIG.outputInventoryName then
    outputInventory = peripheral.wrap(CONFIG.outputInventoryName)
    if not outputInventory then
        log("WARNING: output inventory peripheral not found: " .. CONFIG.outputInventoryName)
    end
end

local freeSpace = fs.getFreeSpace("/")
if type(freeSpace) == "number" then
    log(("Computer free space: %d bytes"):format(freeSpace))
end

--============================== request policy ===============================

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function requestIsColonyManaged(request)
    local haystack = lower(request and request.name) .. "\n" .. lower(request and request.desc)

    for _, pattern in ipairs(CONFIG.colonyManagedRequestPatterns or {}) do
        if haystack:find(lower(pattern), 1, true) then
            return true, pattern
        end
    end

    return false
end

local function isArchitectCutterItem(item)
    return type(item) == "table"
       and type(item.name) == "string"
       and item.name:find("domum_ornamentum:", 1, true) == 1
end

local function flattenStrings(value, out)
    out = out or {}

    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        out[#out + 1] = tostring(value)
    elseif type(value) == "table" then
        for _, child in pairs(value) do
            flattenStrings(child, out)
        end
    end

    return out
end

local function architectRecipeDescription(candidate)
    local parts = {}
    local components = type(candidate) == "table" and candidate.components or nil

    if type(components) == "table" then
        local textureData = components["domum_ornamentum:texture_data"]
        local blockState  = components["minecraft:block_state"]

        for _, value in ipairs(flattenStrings(textureData)) do
            parts[#parts + 1] = value
        end
        for _, value in ipairs(flattenStrings(blockState)) do
            parts[#parts + 1] = value
        end
    end

    if #parts == 0 then
        return candidate and (candidate.displayName or candidate.name) or "unknown variant"
    end

    return table.concat(parts, " + ")
end

local function reportArchitectRequest(request)
    if not CONFIG.reportArchitectCutter or type(request.items) ~= "table" then
        return false
    end

    local found = false
    for _, candidate in ipairs(request.items) do
        if isArchitectCutterItem(candidate) then
            found = true
            log(("[MANUAL] Architect's Cutter: %s x%d | %s | fingerprint=%s")
                :format(
                    tostring(request.name or candidate.displayName or candidate.name),
                    requestAmount(request),
                    architectRecipeDescription(candidate),
                    tostring(candidate.fingerprint or "none")
                ))
        end
    end

    return found
end

--============================== MineColonies gear tiers =======================

local GEAR_TIERS = {
    { key = "wood",      toolPrefix = "minecraft:wooden_",  rank = 1 },
    { key = "leather",   armorPrefix = "minecraft:leather_", rank = 1 },
    { key = "stone",     toolPrefix = "minecraft:stone_",   rank = 2 },
    { key = "chain",     armorPrefix = "minecraft:chainmail_", rank = 2 },
    { key = "gold",      toolPrefix = "minecraft:golden_",  armorPrefix = "minecraft:golden_", rank = 3 },
    { key = "iron",      toolPrefix = "minecraft:iron_",    armorPrefix = "minecraft:iron_", rank = 4 },
    { key = "diamond",   toolPrefix = "minecraft:diamond_", armorPrefix = "minecraft:diamond_", rank = 5 },
    { key = "netherite", toolPrefix = "minecraft:netherite_", armorPrefix = "minecraft:netherite_", rank = 6 },
}

local TOOL_SUFFIXES = {
    hoe = "hoe",
    pickaxe = "pickaxe",
    shovel = "shovel",
    axe = "axe",
    sword = "sword",
}

local ARMOR_SUFFIXES = {
    helmet = "helmet",
    chestplate = "chestplate",
    leggings = "leggings",
    boots = "boots",
}

local function detectRequestedGearType(request)
    local haystack = lower(request and request.name) .. "\n" .. lower(request and request.desc)

    -- Check longer/specific words first.
    for word, suffix in pairs(ARMOR_SUFFIXES) do
        if haystack:find(word, 1, true) then
            return "armor", suffix
        end
    end

    if haystack:find("pickaxe", 1, true) then return "tool", "pickaxe" end
    if haystack:find("shovel", 1, true) then return "tool", "shovel" end
    if haystack:find("sword", 1, true) then return "tool", "sword" end
    if haystack:find("hoe", 1, true) then return "tool", "hoe" end

    -- Avoid treating "pickaxe" as a generic axe.
    if haystack:find("axe", 1, true) then return "tool", "axe" end

    return nil
end

local function detectMaxGearRank(request, gearKind)
    local desc = lower(request and request.desc)
    local name = lower(request and request.name)
    local haystack = desc .. "\n" .. name

    -- MineColonies commonly uses wording such as "Maximal level: Diamond".
    local explicit = desc:match("maximal%s+level:%s*([%a_]+)")
        or desc:match("maximum%s+level:%s*([%a_]+)")
        or desc:match("max%s+level:%s*([%a_]+)")

    local function rankForWord(word)
        word = lower(word)
        if word == "wooden" then word = "wood" end
        if word == "golden" then word = "gold" end
        if word == "chainmail" then word = "chain" end

        for _, tier in ipairs(GEAR_TIERS) do
            if tier.key == word then
                if gearKind == "tool" and tier.toolPrefix then return tier.rank end
                if gearKind == "armor" and tier.armorPrefix then return tier.rank end
            end
        end
        return nil
    end

    if explicit then
        local rank = rankForWord(explicit)
        if rank then return rank end
    end

    -- Fallback: use the highest material word present anywhere in the request.
    local best = nil
    for _, tier in ipairs(GEAR_TIERS) do
        local supported = (gearKind == "tool" and tier.toolPrefix)
            or (gearKind == "armor" and tier.armorPrefix)
        if supported and haystack:find(tier.key, 1, true) then
            best = math.max(best or 0, tier.rank)
        end
    end

    return best
end

local function buildGearCandidates(request)
    if not CONFIG.preferHighestAllowedGear then return nil end

    local gearKind, suffix = detectRequestedGearType(request)
    if not gearKind then return nil end

    local maxRank = detectMaxGearRank(request, gearKind)
    if not maxRank then return nil end

    local candidates = {}
    for i = #GEAR_TIERS, 1, -1 do
        local tier = GEAR_TIERS[i]
        local prefix = gearKind == "tool" and tier.toolPrefix or tier.armorPrefix

        if prefix and tier.rank <= maxRank then
            candidates[#candidates + 1] = {
                name = prefix .. suffix,
                displayName = tier.key:gsub("^%l", string.upper) .. " " ..
                    suffix:gsub("^%l", string.upper),
                maxStackSize = 1,
                components = {},
                generatedGearCandidate = true,
                gearRank = tier.rank,
                gearTier = tier.key,
            }
        end
    end

    return #candidates > 0 and candidates or nil
end

local function effectiveRequestItems(request)
    local gearCandidates = buildGearCandidates(request)
    if gearCandidates then return gearCandidates, true end
    return type(request.items) == "table" and request.items or {}, false
end

local PAXEL_BY_TIER = {
    wood      = "mekanismtools:wood_paxel",
    stone     = "mekanismtools:stone_paxel",
    gold      = "mekanismtools:gold_paxel",
    iron      = "mekanismtools:iron_paxel",
    diamond   = "mekanismtools:diamond_paxel",
    netherite = "mekanismtools:netherite_paxel",
}

local function requestIsForPaxelJob(request)
    if not CONFIG.preferPaxelsForRelevantJobs then return false end

    local target = lower(request and request.target)
    local name = lower(request and request.name)
    local desc = lower(request and request.desc)
    local haystack = target .. "\n" .. name .. "\n" .. desc

    for _, pattern in ipairs(CONFIG.paxelJobBlacklistPatterns or {}) do
        if haystack:find(lower(pattern), 1, true) then
            return false
        end
    end

    for _, pattern in ipairs(CONFIG.paxelJobPatterns or {}) do
        if haystack:find(lower(pattern), 1, true) then
            return true
        end
    end

    return false
end

local function requestCanUsePaxel(request)
    if not requestIsForPaxelJob(request) then return false end

    local gearKind, suffix = detectRequestedGearType(request)
    return gearKind == "tool"
       and (suffix == "pickaxe" or suffix == "axe" or suffix == "shovel")
end

local function buildPaxelCandidates(request)
    if not requestCanUsePaxel(request) then return nil end

    local maxRank = detectMaxGearRank(request, "tool")
    if not maxRank then return nil end

    local candidates = {}
    for i = #GEAR_TIERS, 1, -1 do
        local tier = GEAR_TIERS[i]
        local paxelName = PAXEL_BY_TIER[tier.key]

        if paxelName and tier.rank <= maxRank then
            candidates[#candidates + 1] = {
                name = paxelName,
                displayName = tier.key:gsub("^%l", string.upper) .. " Paxel",
                maxStackSize = 1,
                components = {},
                generatedGearCandidate = true,
                generatedPaxelCandidate = true,
                gearRank = tier.rank,
                gearTier = tier.key,
            }
        end
    end

    return #candidates > 0 and candidates or nil
end

--============================== ME item snapshot =============================

local function getAllItems()
    -- This follows the known-working monitor behavior: try an empty filter,
    -- then no arguments. Do not depend on deprecated listItems/getItem calls.
    local items, firstErr = safeCall("getItems({})", bridge.getItems, {})
    if type(items) == "table" then return items end

    items, firstErr = safeCall("getItems()", bridge.getItems)
    if type(items) == "table" then return items end

    return nil, firstErr or "getItems returned no table"
end

local function buildItemIndexes(items)
    local byFingerprint = {}
    local byName = {}

    for _, item in ipairs(items) do
        if type(item) == "table" then
            if item.fingerprint then
                byFingerprint[tostring(item.fingerprint)] = item
            end

            if type(item.name) == "string" then
                local list = byName[item.name]
                if not list then
                    list = {}
                    byName[item.name] = list
                end
                list[#list + 1] = item
            end
        end
    end

    return byFingerprint, byName
end

local function chooseLargest(list)
    local best
    for _, item in ipairs(list or {}) do
        if not best or itemAmount(item) > itemAmount(best) then best = item end
    end
    return best
end

local function candidateAllowed(candidate, exactFingerprint)
    if type(candidate) ~= "table" or type(candidate.name) ~= "string" then
        return false, "invalid candidate"
    end

    if CONFIG.blacklistNames[candidate.name] then
        return false, "name blacklisted"
    end

    if hasBlockedTag(candidate) then
        return false, "tag blacklisted"
    end

    if CONFIG.skipComponentItems and hasComponents(candidate) and not exactFingerprint then
        return false, "component-sensitive item has no exact fingerprint match"
    end

    return true
end

local function selectStoredItem(request, byFingerprint, byName)
    local requestItems, generatedGear = effectiveRequestItems(request)
    if #requestItems == 0 then
        return nil, nil, "request has no item alternatives"
    end

    local reasons = {}

    -- Pass 1: exact fingerprint. This is safest for ordinary request variants.
    -- Generated gear candidates intentionally use clean name/components matching.
    for _, candidate in ipairs(requestItems) do
        local fingerprint = candidate and candidate.fingerprint
        local stored = fingerprint and byFingerprint[tostring(fingerprint)] or nil

        if stored and itemAmount(stored) > 0 then
            local allowed, reason = candidateAllowed(candidate, true)
            if allowed then return stored, candidate, "fingerprint" end
            reasons[#reasons + 1] = reason
        end
    end

    if not CONFIG.allowNameFallback then
        return nil, nil, "no stored fingerprint match"
    end

    -- Pass 2: name fallback only when safe.
    for _, candidate in ipairs(requestItems) do
        local allowed, reason = candidateAllowed(candidate, false)
        if allowed then
            local stored = chooseLargest(byName[candidate.name])
            if stored and itemAmount(stored) > 0 then
                return stored, candidate, "name"
            end
            reasons[#reasons + 1] = candidate.name .. " not stored"
        else
            reasons[#reasons + 1] =
                (candidate.name or "?") .. ": " .. tostring(reason)
        end
    end

    return nil, nil, table.concat(reasons, "; ")
end

--============================== export =======================================

local function makeExportFilter(stored, candidate, amount, matchType)
    if matchType == "fingerprint" and stored.fingerprint then
        return {
            fingerprint = stored.fingerprint,
            count = amount,
            -- Components are explicitly included for compatibility with the
            -- older implementation and current AP item objects.
            components = stored.components or candidate.components or {},
        }
    end

    return {
        name = stored.name or candidate.name,
        count = amount,
        components = stored.components or candidate.components or {},
    }
end

local function exportStoredItem(stored, candidate, amount, matchType)
    local filter = makeExportFilter(stored, candidate, amount, matchType)

    if CONFIG.dryRun then
        return amount, "dry-run"
    end

    local moved, err = safeCall(
        "exportItem",
        bridge.exportItem,
        filter,
        CONFIG.exportDirection
    )

    -- AP builds may return a number, boolean, or nil. A numeric return is best.
    if type(moved) == "number" then
        return normalizeCount(moved), err
    end
    if moved == true then
        -- We cannot prove the actual count on boolean-only builds.
        return amount, "boolean success"
    end
    return 0, err or "export returned false/nil"
end

--============================== status files / output =========================

local function writeMissingFile(records)
    local file = fs.open(CONFIG.missingFile, "w")
    if not file then
        log("WARNING: could not write " .. CONFIG.missingFile)
        return
    end

    file.writeLine("AE2 Colony Exporter - current unresolved requests")
    file.writeLine("Updated: " .. os.date("%Y-%m-%d %H:%M:%S", os.epoch("local") / 1000))
    file.writeLine("")

    if #records == 0 then
        file.writeLine("No unresolved requests.")
    else
        for _, record in ipairs(records) do
            file.writeLine(("[%s] x%d %s | target=%s | %s")
                :format(
                    tostring(record.kind or "MISSING"),
                    normalizeCount(record.count),
                    tostring(record.name or "?"),
                    tostring(record.target or "?"),
                    tostring(record.detail or "")
                ))
        end
    end
    file.close()
end

local function outputInventoryFull()
    if not outputInventory
       or not hasMethod(outputInventory, "size")
       or not hasMethod(outputInventory, "list") then
        return nil
    end

    local size, sizeErr = safeCall("output.size", outputInventory.size)
    local contents, listErr = safeCall("output.list", outputInventory.list)
    if type(size) ~= "number" or type(contents) ~= "table" then
        log("WARNING: output inventory check failed: " .. tostring(sizeErr or listErr))
        return nil
    end

    local occupied = 0
    for _ in pairs(contents) do occupied = occupied + 1 end
    return occupied >= size, occupied, size
end

--============================== crafting =====================================

local function activeCraftingIndex()
    local active = {}

    if not hasMethod(bridge, "getCraftingTasks") then return active end
    local tasks = safeCall("getCraftingTasks", bridge.getCraftingTasks)
    if type(tasks) ~= "table" then return active end

    for _, task in ipairs(tasks) do
        local resource = type(task.resource) == "table" and task.resource or {}
        if resource.name then active["name:" .. tostring(resource.name)] = true end
        if resource.fingerprint then
            active["fingerprint:" .. tostring(resource.fingerprint)] = true
        end
    end
    return active
end

local function craftKey(candidate)
    if candidate and candidate.fingerprint then
        return "fingerprint:" .. tostring(candidate.fingerprint)
    end
    return "name:" .. tostring(candidate and candidate.name or "?")
end

local function makeCraftPayload(candidate, amount)
    -- isCraftable by name/components was more reliable than fingerprint on the
    -- older AP implementation. Keep exact components when the request supplies them.
    return {
        name = candidate.name,
        count = amount,
        components = candidate.components or {},
    }
end

local function tryStartCraft(candidate, amount, activeCrafts)
    if not CONFIG.enableCrafting then return false, "crafting disabled" end
    if not hasMethod(bridge, "isCraftable") or not hasMethod(bridge, "craftItem") then
        return false, "bridge crafting methods unavailable"
    end
    if isArchitectCutterItem(candidate) then
        return false, "Architect's Cutter item"
    end

    local key = craftKey(candidate)
    if activeCrafts[key] or activeCrafts["name:" .. tostring(candidate.name)] then
        return true, "already crafting"
    end

    local payload = makeCraftPayload(candidate, amount)
    local craftable, craftableErr = safeCall("isCraftable", bridge.isCraftable, payload)
    if craftable ~= true then
        return false, craftableErr or "no AE2 crafting pattern"
    end

    if CONFIG.dryRun then return true, "dry-run craft plan" end

    local job, craftErr = safeCall("craftItem", bridge.craftItem, payload)
    if job == nil or job == false then
        return false, craftErr or "craftItem returned nil/false"
    end

    activeCrafts[key] = true
    activeCrafts["name:" .. tostring(candidate.name)] = true
    return true, "craft submitted"
end

local function chooseCraftCandidate(request, bridgeByName)
    local requestItems = effectiveRequestItems(request)
    if #requestItems == 0 then return nil end

    -- Candidates are ordered highest-to-lowest for generated tools/armor.
    -- Return the first craftable candidate; do not silently choose a lower tier
    -- merely because it is already stored unless the higher tier cannot be crafted.
    for _, candidate in ipairs(requestItems) do
        if type(candidate) == "table"
           and type(candidate.name) == "string"
           and not CONFIG.blacklistNames[candidate.name]
           and not hasBlockedTag(candidate)
           and not isArchitectCutterItem(candidate) then

            if hasMethod(bridge, "isCraftable") then
                local payload = makeCraftPayload(candidate, 1)
                local craftable = safeCall("isCraftable", bridge.isCraftable, payload)
                if craftable == true then return candidate end
            end
        end
    end

    return nil
end

local function resolveHighestAllowedGear(request, byName)
    local candidates
    local usingPaxel = false

    if requestCanUsePaxel(request) then
        candidates = buildPaxelCandidates(request)
        usingPaxel = candidates ~= nil
    end

    if not candidates then
        candidates = buildGearCandidates(request)
    end
    if not candidates then return nil end

    -- Strict priority: highest allowed tier first. For eligible workers, paxels are tried
    -- before separate pickaxe/axe/shovel tools.
    for _, candidate in ipairs(candidates) do
        local stored = chooseLargest(byName[candidate.name])
        if stored and itemAmount(stored) > 0 then
            return {
                action = "stored",
                stored = stored,
                candidate = candidate,
                matchType = "name",
                tier = candidate.gearTier,
                paxel = usingPaxel,
            }
        end

        if CONFIG.enableCrafting and hasMethod(bridge, "isCraftable") then
            local payload = makeCraftPayload(candidate, 1)
            local craftable = safeCall("isCraftable", bridge.isCraftable, payload)
            if craftable == true then
                return {
                    action = "craft",
                    candidate = candidate,
                    tier = candidate.gearTier,
                    paxel = usingPaxel,
                }
            end
        end
    end

    -- If no allowed paxel exists, fall back to the normal requested tool.
    if usingPaxel then
        local toolCandidates = buildGearCandidates(request)
        for _, candidate in ipairs(toolCandidates or {}) do
            local stored = chooseLargest(byName[candidate.name])
            if stored and itemAmount(stored) > 0 then
                return {
                    action = "stored",
                    stored = stored,
                    candidate = candidate,
                    matchType = "name",
                    tier = candidate.gearTier,
                    paxel = false,
                }
            end

            if CONFIG.enableCrafting and hasMethod(bridge, "isCraftable") then
                local payload = makeCraftPayload(candidate, 1)
                local craftable = safeCall("isCraftable", bridge.isCraftable, payload)
                if craftable == true then
                    return {
                        action = "craft",
                        candidate = candidate,
                        tier = candidate.gearTier,
                        paxel = false,
                    }
                end
            end
        end
    end

    return {
        action = "missing",
        detail = usingPaxel
            and "no allowed paxel or fallback tool is stored or craftable"
            or "no allowed tool/armor tier is stored or craftable",
    }
end

--============================== export error classification ==================

local function classifyExportFailure(note)
    local text = string.upper(tostring(note or ""))

    if text:find("INVENTORY_NOT_FOUND", 1, true)
       or text:find("NO INVENTORY", 1, true) then
        return "CONFIG_ERROR",
            "No inventory exists on ME Bridge side '" .. CONFIG.exportDirection
            .. "'. Set exportDirection to the side touching the barrel."
    end

    if text:find("INVENTORY_FULL", 1, true)
       or text:find("FULL", 1, true) then
        return "OUTPUT_FULL",
            "The source barrel or downstream delivery path is full."
    end

    return "OUTPUT_BLOCKED",
        "Export moved 0; check the barrel, pipe, Ender Chest, racks, and export side."
end

--============================== duplicate protection =========================

local state = loadState()

local function ledgerFor(requestId, observedCount)
    local entry = state.requests[requestId]
    if type(entry) ~= "table" then
        entry = {
            observed = observedCount,
            sentAtObservedCount = 0,
            craftRequestedAt = 0,
            craftRequestedCount = 0,
            firstSeen = unixNow(),
            lastSeen = unixNow(),
        }
        state.requests[requestId] = entry
    end

    -- MineColonies normally exposes an outstanding count. When that count
    -- changes, treat it as a new request state and reset this scan's sent tally.
    if normalizeCount(entry.observed) ~= observedCount then
        entry.observed = observedCount
        entry.sentAtObservedCount = 0
        entry.craftRequestedAt = 0
        entry.craftRequestedCount = 0
    end

    entry.lastSeen = unixNow()
    return entry
end

local function cleanupLedger(seen)
    local cutoff = unixNow() - CONFIG.staleAfterSeconds
    for id, entry in pairs(state.requests) do
        if not seen[id] and normalizeCount(entry.lastSeen) < cutoff then
            state.requests[id] = nil
        end
    end
end

--============================== monitor ======================================

local function fit(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end

local function clearRow(mon, y, width, bg)
    mon.setBackgroundColor(bg or DASH_COLORS.bg)
    mon.setCursorPos(1, y)
    mon.write(string.rep(" ", width))
end

local function writeAt(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.setTextColor(fg or DASH_COLORS.value)
    mon.setBackgroundColor(bg or DASH_COLORS.bg)
    mon.write(text)
end

local function kindColor(kind)
    if kind == "MISSING" or kind == "ERROR" or kind == "CONFIG_ERROR"
       or kind == "OUTPUT_FULL" or kind == "OUTPUT_BLOCKED" then
        return DASH_COLORS.bad
    end
    if kind == "CRAFTING" then return DASH_COLORS.craft end
    if kind == "MANUAL" then return DASH_COLORS.manual end
    if kind == "COLONY" then return DASH_COLORS.colony end
    return DASH_COLORS.info
end

local function renderMonitor()
    if not monitor then return end

    local w, h = monitor.getSize()
    monitor.setBackgroundColor(DASH_COLORS.bg)
    monitor.setTextColor(DASH_COLORS.value)
    monitor.clear()

    clearRow(monitor, 1, w, DASH_COLORS.titleBg)
    local title = "AE2 COLONY EXPORTER"
    local mode = CONFIG.dryRun and "DRY RUN" or "LIVE"
    writeAt(monitor, 2, 1, fit(title, math.max(1, w - #mode - 4)),
        DASH_COLORS.title, DASH_COLORS.titleBg)
    writeAt(monitor, math.max(2, w - #mode), 1, mode,
        CONFIG.dryRun and DASH_COLORS.warn or DASH_COLORS.good,
        DASH_COLORS.titleBg)

    local statusColor = dashboard.status == "ONLINE" and DASH_COLORS.good
        or (dashboard.status == "SCANNING" and DASH_COLORS.info or DASH_COLORS.bad)

    writeAt(monitor, 2, 3, "STATUS", DASH_COLORS.label)
    writeAt(monitor, 10, 3, fit(dashboard.status, math.max(1, w - 11)), statusColor)

    writeAt(monitor, 2, 4,
        fit(dashboard.message, math.max(1, w - 2)), DASH_COLORS.value)

    local summary = ("Requests %d | %s %d | Craft %d | Unresolved %d")
        :format(
            dashboard.requestCount,
            CONFIG.dryRun and "Plan" or "Sent",
            dashboard.moved,
            dashboard.crafted,
            #dashboard.unresolved
        )
    writeAt(monitor, 2, 6, fit(summary, math.max(1, w - 2)), DASH_COLORS.info)

    local counts = {}
    for _, entry in ipairs(dashboard.unresolved) do
        local kind = tostring(entry.kind or "MISSING")
        counts[kind] = (counts[kind] or 0) + 1
    end

    local categories = {
        {"MISSING", counts.MISSING or 0},
        {"CRAFTING", counts.CRAFTING or 0},
        {"MANUAL", counts.MANUAL or 0},
        {"COLONY", counts.COLONY or 0},
        {"BLOCKED", (counts.OUTPUT_BLOCKED or 0)
            + (counts.OUTPUT_FULL or 0)
            + (counts.CONFIG_ERROR or 0)},
    }

    local x = 2
    for _, pair in ipairs(categories) do
        local text = pair[1] .. ":" .. pair[2]
        if x + #text <= w then
            writeAt(monitor, x, 8, text, kindColor(pair[1]))
            x = x + #text + 2
        end
    end

    local listStart = 10
    local footerRows = 2
    local availableRows = math.max(0, h - listStart - footerRows + 1)

    if availableRows > 0 then
        writeAt(monitor, 2, listStart - 1, "CURRENT REQUESTS / ACTIONS", DASH_COLORS.label)
    end

    for i = 1, math.min(#dashboard.unresolved, availableRows) do
        local entry = dashboard.unresolved[i]
        local kind = tostring(entry.kind or "MISSING")
        local prefix = ("[%s] x%d "):format(kind, normalizeCount(entry.count))
        local text = prefix .. tostring(entry.name or "?")
        writeAt(monitor, 2, listStart + i - 1,
            fit(text, math.max(1, w - 2)), kindColor(kind))
    end

    if #dashboard.unresolved == 0 and availableRows > 0 then
        writeAt(monitor, 2, listStart, "No unresolved colony requests.",
            DASH_COLORS.good)
    elseif #dashboard.unresolved > availableRows and availableRows > 0 then
        local more = #dashboard.unresolved - availableRows
        writeAt(monitor, math.max(2, w - #("+" .. more .. " more")),
            h - 2, "+" .. more .. " more", DASH_COLORS.label)
    end

    clearRow(monitor, h - 1, w, DASH_COLORS.panel)
    clearRow(monitor, h, w, DASH_COLORS.panel)
    writeAt(monitor, 2, h - 1,
        "Missing list: " .. CONFIG.missingFile, DASH_COLORS.value, DASH_COLORS.panel)

    local age = dashboard.lastUpdate > 0
        and math.max(0, math.floor(os.epoch("utc") / 1000) - dashboard.lastUpdate)
        or 0
    local footer = ("Next scan <= %ds | updated %ds ago")
        :format(CONFIG.pollInterval, age)
    writeAt(monitor, 2, h, fit(footer, math.max(1, w - 2)),
        DASH_COLORS.value, DASH_COLORS.panel)
end

local function monitorLoop()
    if not monitor then
        while true do sleep(3600) end
    end

    while true do
        local ok, err = pcall(renderMonitor)
        if not ok then
            log("Monitor render error: " .. tostring(err))
        end
        sleep(CONFIG.monitorRefresh)
    end
end

--============================== cycle ========================================

local function bridgeReady()
    if hasMethod(bridge, "isConnected") then
        local connected, err = safeCall("isConnected", bridge.isConnected)
        if connected == false then return false, "ME grid disconnected" end
        if connected == nil and err then log("WARNING: " .. err) end
    end

    if hasMethod(bridge, "isOnline") then
        local online, err = safeCall("isOnline", bridge.isOnline)
        if online == false then return false, "ME grid offline" end
        if online == nil and err then log("WARNING: " .. err) end
    end

    return true
end

local function processCycle()
    dashboard.cycleRunning = true
    publishDashboard("SCANNING", "Reading colony requests and ME inventory",
        dashboard.unresolved, dashboard.requestCount, 0, 0)

    local ready, reason = bridgeReady()
    local unresolved = {}

    if not ready then
        unresolved[#unresolved + 1] = {
            kind = "ERROR", count = 0, name = "ME network", target = "-",
            detail = reason,
        }
        writeMissingFile(unresolved)
        publishDashboard("OFFLINE", reason, unresolved, 0, 0, 0)
        dashboard.cycleRunning = false
        log("Waiting: " .. reason)
        return
    end

    if state.outputBlockedUntil and unixNow() < state.outputBlockedUntil then
        local remainingPause = state.outputBlockedUntil - unixNow()
        unresolved[#unresolved + 1] = {
            kind = "OUTPUT_BLOCKED", count = 0, name = "Delivery pipeline",
            target = "warehouse racks",
            detail = "paused for " .. remainingPause .. " more seconds",
        }
        writeMissingFile(unresolved)
        publishDashboard("BLOCKED", "Output pipeline paused", unresolved, 0, 0, 0)
        dashboard.cycleRunning = false
        log("Output pipeline paused for " .. remainingPause .. " more seconds")
        return
    end

    local knownFull, occupied, slots = outputInventoryFull()
    if knownFull == true then
        state.outputBlockedUntil = unixNow() + CONFIG.outputPauseSeconds
        unresolved[#unresolved + 1] = {
            kind = "OUTPUT_FULL", count = 0, name = "Source output inventory",
            target = "warehouse racks",
            detail = ("%d/%d slots occupied"):format(occupied, slots),
        }
        saveState(state)
        writeMissingFile(unresolved)
        publishDashboard("BLOCKED", "Source output inventory is full",
            unresolved, 0, 0, 0)
        dashboard.cycleRunning = false
        log(("[OUTPUT FULL] Source inventory is full (%d/%d slots)")
            :format(occupied, slots))
        return
    end

    local requests, requestErr = safeCall("getRequests", colony.getRequests)
    if type(requests) ~= "table" then
        unresolved[#unresolved + 1] = {
            kind = "ERROR", count = 0, name = "Colony requests", target = "-",
            detail = tostring(requestErr),
        }
        writeMissingFile(unresolved)
        publishDashboard("ERROR", "Colony request read failed",
            unresolved, 0, 0, 0)
        dashboard.cycleRunning = false
        log("Colony request read failed: " .. tostring(requestErr))
        return
    end

    local items, itemErr = getAllItems()
    if type(items) ~= "table" then
        unresolved[#unresolved + 1] = {
            kind = "ERROR", count = 0, name = "ME item list", target = "-",
            detail = tostring(itemErr),
        }
        writeMissingFile(unresolved)
        publishDashboard("ERROR", "ME item read failed",
            unresolved, 0, 0, 0)
        dashboard.cycleRunning = false
        log("ME item read failed: " .. tostring(itemErr))
        return
    end

    writeSnapshot(requests, items)

    local byFingerprint, byName = buildItemIndexes(items)
    local activeCrafts = activeCraftingIndex()
    local seen = {}
    local movedThisCycle = 0
    local craftedThisCycle = 0
    local requestCount = 0
    local outputBlocked = false

    for index, request in ipairs(requests) do
        if outputBlocked then break end

        local wanted = requestAmount(request)
        local id = tostring(request.id or ("index:" .. index))
        local label = tostring(request.name or request.target or id)
        local target = tostring(request.target or request.name or "?")

        if wanted > 0 then
            requestCount = requestCount + 1
            seen[id] = true

            local colonyManaged, managedPattern = requestIsColonyManaged(request)
            if colonyManaged then
                unresolved[#unresolved + 1] = {
                    kind = "COLONY", count = wanted, name = label, target = target,
                    detail = "left to colony production: " .. tostring(managedPattern),
                }
                log(("[COLONY] %s x%d left to colony production (%s)")
                    :format(label, wanted, tostring(managedPattern)))
            else
                local ledger = ledgerFor(id, wanted)
                local alreadySent = normalizeCount(ledger.sentAtObservedCount)
                local remaining = math.max(0, wanted - alreadySent)

                if remaining > 0 then
                    local gearResolution = resolveHighestAllowedGear(request, byName)
                    local stored, candidate, matchOrReason

                    if gearResolution and gearResolution.action == "stored" then
                        stored = gearResolution.stored
                        candidate = gearResolution.candidate
                        matchOrReason = gearResolution.paxel
                            and ("highest allowed " .. tostring(gearResolution.tier) .. " paxel")
                            or ("highest allowed " .. tostring(gearResolution.tier))
                    elseif not gearResolution then
                        stored, candidate, matchOrReason =
                            selectStoredItem(request, byFingerprint, byName)
                    end

                    local exported = 0
                    if stored and movedThisCycle < CONFIG.maxPerCycle then
                        local batch = math.min(
                            remaining,
                            itemAmount(stored),
                            CONFIG.maxPerExport,
                            CONFIG.maxPerCycle - movedThisCycle
                        )

                        if batch > 0 then
                            local moved, exportNote =
                                exportStoredItem(stored, candidate, batch, matchOrReason)

                            if moved > 0 then
                                exported = moved
                                if not CONFIG.dryRun then
                                    ledger.sentAtObservedCount = alreadySent + moved
                                    ledger.lastExport = unixNow()
                                end
                                movedThisCycle = movedThisCycle + moved

                                log(("[%s] %s x%d %s -> %s (%s match)")
                                    :format(
                                        CONFIG.dryRun and "PLAN" or "SENT",
                                        label,
                                        moved,
                                        stored.displayName or stored.name or "?",
                                        CONFIG.exportDirection,
                                        matchOrReason
                                    ))
                            else
                                local failureKind, failureDetail =
                                    classifyExportFailure(exportNote)

                                outputBlocked = true

                                -- A missing adjacent inventory is a configuration error,
                                -- not evidence that the warehouse racks are full.
                                if failureKind ~= "CONFIG_ERROR" then
                                    state.outputBlockedUntil =
                                        unixNow() + CONFIG.outputPauseSeconds
                                else
                                    state.outputBlockedUntil = nil
                                end

                                unresolved[#unresolved + 1] = {
                                    kind = failureKind,
                                    count = remaining,
                                    name = label,
                                    target = target,
                                    detail = failureDetail .. " API: "
                                        .. tostring(exportNote),
                                }

                                log(("[%s] %s: export moved 0 (%s)")
                                    :format(failureKind, label, tostring(exportNote)))
                            end
                        end
                    end

                    if not outputBlocked then
                        local stillNeeded = math.max(0, remaining - exported)

                        if stillNeeded > 0 then
                            if reportArchitectRequest(request) then
                                unresolved[#unresolved + 1] = {
                                    kind = "MANUAL", count = stillNeeded,
                                    name = label, target = target,
                                    detail = "Architect's Cutter block is not available in AE2",
                                }
                            else
                                local craftCandidate
                                if gearResolution and gearResolution.action == "craft" then
                                    craftCandidate = gearResolution.candidate
                                elseif not gearResolution then
                                    craftCandidate = chooseCraftCandidate(request, byName)
                                end

                                local canRetry = unixNow() - normalizeCount(ledger.craftRequestedAt)
                                    >= CONFIG.craftRetrySeconds
                                local craftAmount = math.min(
                                    stillNeeded,
                                    CONFIG.maxCraftPerCycle - craftedThisCycle
                                )

                                if craftCandidate and craftAmount > 0 and canRetry then
                                    local started, craftNote =
                                        tryStartCraft(craftCandidate, craftAmount, activeCrafts)

                                    if started then
                                        craftedThisCycle = craftedThisCycle + craftAmount
                                        if not CONFIG.dryRun and craftNote ~= "already crafting" then
                                            ledger.craftRequestedAt = unixNow()
                                            ledger.craftRequestedCount = craftAmount
                                        end

                                        unresolved[#unresolved + 1] = {
                                            kind = "CRAFTING", count = stillNeeded,
                                            name = label, target = target,
                                            detail = tostring(craftNote)
                                                .. "; will export after it appears in ME storage",
                                        }
                                        log(("[%s] %s x%d %s")
                                            :format(
                                                CONFIG.dryRun and "CRAFT PLAN" or "CRAFT",
                                                label,
                                                craftAmount,
                                                tostring(craftNote)
                                            ))
                                    else
                                        unresolved[#unresolved + 1] = {
                                            kind = "MISSING", count = stillNeeded,
                                            name = label, target = target,
                                            detail = tostring(craftNote
                                                or (gearResolution and gearResolution.detail)
                                                or matchOrReason),
                                        }
                                        log(("[MISSING] %s x%d: %s")
                                            :format(label, stillNeeded,
                                                tostring(craftNote or matchOrReason)))
                                    end
                                elseif craftCandidate and not canRetry then
                                    unresolved[#unresolved + 1] = {
                                        kind = "CRAFTING", count = stillNeeded,
                                        name = label, target = target,
                                        detail = "craft request recently submitted; waiting for ME",
                                    }
                                else
                                    unresolved[#unresolved + 1] = {
                                        kind = "MISSING", count = stillNeeded,
                                        name = label, target = target,
                                        detail = tostring(matchOrReason or "no acceptable item"),
                                    }
                                    log(("[MISSING] %s x%d: %s")
                                        :format(label, stillNeeded,
                                            tostring(matchOrReason or "no acceptable item")))
                                end
                            end
                        end
                    end
                elseif CONFIG.debug then
                    log(("[WAIT] %s already exported for current count %d")
                        :format(label, wanted))
                end
            end
        end
    end

    cleanupLedger(seen)
    saveState(state)
    writeMissingFile(unresolved)
    publishDashboard(
        outputBlocked and "BLOCKED" or "ONLINE",
        outputBlocked and "Delivery pipeline cannot accept more items"
            or "Scan complete; waiting for next cycle",
        unresolved,
        requestCount,
        movedThisCycle,
        craftedThisCycle
    )
    dashboard.cycleRunning = false

    log(("Cycle: %d requests, %d %s, %d craft items queued, %d unresolved entries")
        :format(
            requestCount,
            movedThisCycle,
            CONFIG.dryRun and "items planned" or "items exported",
            craftedThisCycle,
            #unresolved
        ))
end

log("AE2 Colony exporter started")
if CONFIG.dryRun then
    log("DRY RUN ENABLED: no items will move. Review colony_export_snapshot.txt.")
else
    log("LIVE MODE ENABLED: exports and AE2 crafting requests are active.")
end

local function cycleLoop()
    while true do
        local ok, err = pcall(processCycle)
        if not ok then
            local unresolved = {
                {
                    kind = "ERROR",
                    count = 0,
                    name = "Cycle error",
                    target = "-",
                    detail = tostring(err),
                }
            }
            writeMissingFile(unresolved)
            publishDashboard("ERROR", tostring(err), unresolved, 0, 0, 0)
            dashboard.cycleRunning = false
            log("Cycle error: " .. tostring(err))
        end
        sleep(CONFIG.pollInterval)
    end
end

parallel.waitForAll(cycleLoop, monitorLoop)
