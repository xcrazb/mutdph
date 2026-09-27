-- ============================================================
-- AUTO SCAN + FEED MUTATION MACHINE (v4.5)
-- + Minimum Mutation Filter (default: Diamond)
-- + Skip Diamond & Gold (existing mutation)
-- + Pond Booster SupremeFoodTray (ON/OFF + Interval Input)
-- + Auto Deteksi Waktu Mesin
-- + Auto Stop Jika Tidak Ada Pet Eligible
-- + Discord Webhook (HANYA hasil mutasi)
-- + ⭐ Webhook Progress (total pet tersisa)
-- + ⭐ Webhook Completion (semua pet selesai)
-- + ⭐ Webhook UI Redesign (rapi & full width)
-- + Test Webhook Button
-- + HTTP Multi-Fallback (request / syn.request / PostAsync)
-- + Webhook ambil mutation dari pet data setelah collect
-- ============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

--// ============================================================
-- CONFIG
--// ============================================================
local CONFIG = {
    AUTO_FEED = false,
    SCAN_INTERVAL = 2,
    DRY_RUN = false,
    TARGET_AGE = 50,
    
    SKIP_MUTATIONS = {"Diamond"},
    MIN_MUTATION = "Diamond",
    
    MUTATION_TIERS = {
        "None", "Bronze", "Silver", "Gold", "Diamond", "Rainbow", "Celestial",
    },
    
    DELAY_EQUIP = 0.8,
    DELAY_INSERT = 1,
    DELAY_COLLECT = 3,
    MAX_FEED_PER_CYCLE = 1,
    POLL_INTERVAL = 2,
    MUTATION_TIMEOUT = 600,
    
    AUTO_STOP_IF_EMPTY = true,
    EMPTY_CHECK_DELAY = 5,
    EMPTY_COUNT_THRESHOLD = 3,
    
    BOOSTER_ENABLED = false,
    PLACE_BUILDING_INTERVAL = 10,
    
    -- ⭐ WEBHOOK (hanya hasil mutasi)
    WEBHOOK_ENABLED = false,
    WEBHOOK_URL = "",
    WEBHOOK_USERNAME = "Auto Mutation v4.5",
    
    -- ⭐ WEBHOOK SUMMARY (progress & completion)
    WEBHOOK_SEND_PROGRESS = true,   -- kirim ringkasan tiap cycle
    WEBHOOK_SEND_COMPLETE = true,   -- kirim notif saat semua pet selesai
}

--// ============================================================
-- LOAD MODULES
--// ============================================================
local playerDataModule = require(ReplicatedStorage.TS.state["player-data"])
local petAgeUtils = require(ReplicatedStorage.TS.utils["pet-age.utils"])

local getSharedTime, PET_MUTATION_TIME
pcall(function()
    getSharedTime = require(game:GetService("StarterPlayer").StarterPlayerScripts.TS.systems.core.sharedTime).getSharedTime
end)
pcall(function()
    PET_MUTATION_TIME = require(ReplicatedStorage.TS.constants).PET_MUTATION_TIME
end)

local inventoryStateModule
pcall(function()
    inventoryStateModule = require(LocalPlayer.PlayerScripts.TS.ui.features.toolbar["inventory.state"])
end)

--// ============================================================
-- GET REMOTES
--// ============================================================
local function getRemo(name)
    local ok, remote = pcall(function()
        return ReplicatedStorage
            :WaitForChild("rbxts_include", 10)
            :WaitForChild("node_modules", 10)
            :WaitForChild("@rbxts", 10)
            :WaitForChild("remo", 10)
            :WaitForChild("src", 10)
            :WaitForChild("container", 10)
            :WaitForChild(name, 10)
    end)
    return ok and remote or nil
end

local Remotes = {
    equipTool     = getRemo("tools.equipTool"),
    startMut      = getRemo("pets.startMutation"),
    collectMut    = getRemo("pets.collectMutation"),
    placeBuilding = getRemo("ponds.placeBuilding"),
}

--// ============================================================
-- UTILS
--// ============================================================
local function getPlayerData()
    local ok, data = pcall(playerDataModule.getPlayerDataById, tostring(LocalPlayer.UserId))
    return ok and data or nil
end

local function getPetAge(petData)
    local ok, age = pcall(petAgeUtils.getPetAgeFromData, petData)
    return ok and age or 0
end

--// ============================================================
-- MUTATION TIER HELPERS
--// ============================================================
local function getMutationTierIndex(mutName)
    if not mutName or mutName == "" then return 1 end
    for i, tier in ipairs(CONFIG.MUTATION_TIERS) do
        if string.lower(tier) == string.lower(tostring(mutName)) then
            return i
        end
    end
    return 1
end

local function getMinTierIndex()
    return getMutationTierIndex(CONFIG.MIN_MUTATION)
end

local function getHighestMutation(petData)
    if not petData or not petData.mutation then return nil end
    local mut = petData.mutation
    if type(mut) == "string" then return mut end
    if type(mut) == "table" then
        local highest, highestIdx = nil, 0
        for _, m in ipairs(mut) do
            local idx = getMutationTierIndex(m)
            if idx > highestIdx then
                highestIdx = idx
                highest = m
            end
        end
        return highest
    end
    return nil
end

-- ⭐ Ambil nama mutation dari pet data (support string/table/array/object)
local function getMutationNameFromData(petData)
    if not petData or not petData.mutation then return "None" end
    local mut = petData.mutation
    if type(mut) == "string" then return mut end
    if type(mut) == "table" then
        if mut.name then return mut.name end
        if mut.type then return mut.type end
        if mut.mutation then return mut.mutation end
        if mut[1] then
            local highest, highIdx = "None", 0
            for _, m in ipairs(mut) do
                local name = type(m) == "string" and m or (m.name or m.type or m.mutation or "None")
                local idx = getMutationTierIndex(name)
                if idx > highIdx then highIdx = idx; highest = name end
            end
            return highest
        end
    end
    return "None"
end

local function isSkippedMutation(petData)
    if not petData.mutation then return false end
    local mut = petData.mutation
    if type(mut) == "string" then
        for _, skip in ipairs(CONFIG.SKIP_MUTATIONS) do
            if mut == skip then return true end
        end
    elseif type(mut) == "table" then
        for _, m in ipairs(mut) do
            for _, skip in ipairs(CONFIG.SKIP_MUTATIONS) do
                if m == skip then return true end
            end
        end
    end
    return false
end

local function isBelowMinMutation(petData)
    if isSkippedMutation(petData) then
        return true, "in skip list"
    end
    if CONFIG.MIN_MUTATION == "None" then
        return false, nil
    end
    local highest = getHighestMutation(petData)
    local petTier = getMutationTierIndex(highest)
    local minTier = getMinTierIndex()
    if petTier >= minTier and petTier > 1 then
        return true, string.format("mutation '%s' >= min '%s'",
            tostring(highest), CONFIG.MIN_MUTATION)
    end
    return false, nil
end

local function shortUUID(uuid)
    if not uuid then return "?" end
    return uuid:sub(1, 8) .. "..."
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 0 then seconds = 0 end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d", mins, secs)
end

local function parseMutationResult(result)
    if result == nil or result == false then return nil end
    if type(result) == "string" then return result end
    if type(result) == "table" then
        return result.mutation or result.mutationType or result.name or result.type
    end
    return tostring(result)
end

-- ⭐ Cari pet data terbaru dari inventory berdasarkan ID
local function getPetDataById(petId)
    if not inventoryStateModule then return nil end
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return nil end
    for _, item in pairs(stacked) do
        local tt = tostring(item.toolType or ""):lower()
        if tt:find("pet") and item.items then
            for _, it in ipairs(item.items) do
                if it.id == petId then
                    return it.data, item.displayName or item.itemName or "?"
                end
            end
        end
    end
    return nil
end

--// ============================================================
-- HTTP HELPER (multi-fallback)
--// ============================================================
local function httpPost(url, body)
    local reqFunc = (request) or (http_request) or (http and http.request)

    if reqFunc then
        local ok, res = pcall(function()
            return reqFunc({
                Url = url,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)

        if ok and res then
            local code = res.StatusCode or res.Status or 0
            if code >= 200 and code < 300 then
                return true, "request OK (" .. code .. ")"
            end
            return false, "request HTTP " .. tostring(code) .. " — " .. tostring(res.Body or res.statusMessage)
        end

        warn("[HTTP] request() error:", tostring(res))
    end

    local ok, err = pcall(function()
        HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
    end)
    if ok then return true, "PostAsync OK" end

    return false, "Semua HTTP gagal — " .. tostring(err)
end

--// ============================================================
-- WEBHOOK (HANYA HASIL MUTASI)
--// ============================================================
local function sendMutationWebhook(petName, petAge, petId, mutationResult)
    if not CONFIG.WEBHOOK_ENABLED then return end
    if not CONFIG.WEBHOOK_URL or CONFIG.WEBHOOK_URL == "" then return end

    local mut = tostring(mutationResult or "Unknown")

    local color = 0x8A50C8
    if mut == "Diamond" then color = 0x00C8FF
    elseif mut == "Gold" then color = 0xFFD700
    elseif mut == "Silver" then color = 0xC0C0C0
    elseif mut == "Bronze" then color = 0xCD7F32
    elseif mut == "Rainbow" then color = 0xFF69B4
    elseif mut == "Celestial" then color = 0x9B59B6
    elseif mut == "None" then color = 0x808080
    end

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        embeds = {{
            title = "🧬 Mutation Result: " .. mut,
            color = color,
            fields = {
                { name = "Pet", value = tostring(petName), inline = true },
                { name = "Age", value = tostring(petAge), inline = true },
                { name = "ID",  value = shortUUID(petId), inline = false },
            },
            footer = { text = "Auto Mutation v4.5 • " .. os.date("%H:%M:%S") },
        }},
    }

    local body = HttpService:JSONEncode(payload)

    task.spawn(function()
        local ok, err = httpPost(CONFIG.WEBHOOK_URL, body)
        if not ok then
            warn("[Webhook] ❌ Gagal kirim:", tostring(err))
        else
            print("[Webhook] ✅ Terkirim:", err)
        end
    end)
end

--// ============================================================
-- ⭐ WEBHOOK: PROGRESS & COMPLETION
--// ============================================================
local function sendProgressWebhook(totalEligible, totalAll, fedCount, skippedCount)
    if not CONFIG.WEBHOOK_ENABLED then return end
    if not CONFIG.WEBHOOK_SEND_PROGRESS then return end
    if not CONFIG.WEBHOOK_URL or CONFIG.WEBHOOK_URL == "" then return end

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        embeds = {{
            title = "📊 Mutation Progress Update",
            color = 0x3498DB,
            fields = {
                { name = "🐾 Eligible (siap mutasi)", value = tostring(totalEligible), inline = true },
                { name = "📦 Total Pet di Inventory", value = tostring(totalAll),      inline = true },
                { name = "✅ Fed Cycle Ini",          value = tostring(fedCount),      inline = true },
                { name = "⏭️ Skipped (Diamond/Gold)", value = tostring(skippedCount),  inline = true },
                { name = "🎯 Target Age",             value = tostring(CONFIG.TARGET_AGE), inline = true },
                { name = "💎 Min Mutation",           value = tostring(CONFIG.MIN_MUTATION), inline = true },
            },
            footer = { text = "Auto Mutation v4.5 • " .. os.date("%H:%M:%S") },
        }},
    }

    local body = HttpService:JSONEncode(payload)
    task.spawn(function()
        local ok, err = httpPost(CONFIG.WEBHOOK_URL, body)
        if not ok then
            warn("[Webhook Progress] ❌ Gagal:", tostring(err))
        end
    end)
end

local function sendCompletionWebhook(totalAll, totalProcessed, totalSkipped)
    if not CONFIG.WEBHOOK_ENABLED then return end
    if not CONFIG.WEBHOOK_SEND_COMPLETE then return end
    if not CONFIG.WEBHOOK_URL or CONFIG.WEBHOOK_URL == "" then return end

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        content = "✅ **SEMUA PET TELAH SELESAI DI MUTASIKAN!**",
        embeds = {{
            title = "🎉 Auto Mutation Selesai",
            description = "Semua pet yang eligible sudah diproses.\nTidak ada lagi pet yang memenuhi syarat mutasi.",
            color = 0x2ECC71,
            fields = {
                { name = "📦 Total Pet",      value = tostring(totalAll),       inline = true },
                { name = "✅ Total Diproses", value = tostring(totalProcessed), inline = true },
                { name = "⏭️ Total Skipped",  value = tostring(totalSkipped),   inline = true },
                { name = "💎 Min Mutation",   value = tostring(CONFIG.MIN_MUTATION), inline = true },
                { name = "🎯 Target Age",     value = tostring(CONFIG.TARGET_AGE),   inline = true },
                { name = "👤 Player",         value = LocalPlayer.Name,        inline = true },
            },
            footer = { text = "Auto Mutation v4.5 • " .. os.date("%Y-%m-%d %H:%M:%S") },
        }},
    }

    local body = HttpService:JSONEncode(payload)
    task.spawn(function()
        local ok, err = httpPost(CONFIG.WEBHOOK_URL, body)
        if not ok then
            warn("[Webhook Complete] ❌ Gagal:", tostring(err))
        else
            print("[Webhook Complete] ✅ Notifikasi selesai terkirim")
        end
    end)
end

-- ⭐ Hitung total pet & skipped di inventory (buat summary)
local function getInventoryStats()
    if not inventoryStateModule then return 0, 0, 0 end

    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return 0, 0, 0 end

    local totalAll = 0
    local totalEligible = 0
    local totalSkipped = 0

    local data = getPlayerData()
    local equippedSet = {}
    if data and data.equippedPets then
        for _, id in ipairs(data.equippedPets) do
            equippedSet[id] = true
        end
    end

    local seen = {}
    for _, item in pairs(stacked) do
        local tt = tostring(item.toolType or ""):lower()
        if tt:find("pet") and item.items then
            for _, it in ipairs(item.items) do
                if it.id and not seen[it.id] and it.data then
                    seen[it.id] = true
                    totalAll = totalAll + 1

                    local age = getPetAge(it.data)
                    local isMaxAge = age >= CONFIG.TARGET_AGE
                    local isSkip = isBelowMinMutation(it.data)
                    local isEquipped = equippedSet[it.id] == true

                    if isMaxAge and isSkip then
                        totalSkipped = totalSkipped + 1
                    elseif isMaxAge and not isSkip and not isEquipped then
                        totalEligible = totalEligible + 1
                    end
                end
            end
        end
    end

    return totalAll, totalEligible, totalSkipped
end

--// ============================================================
-- REMOTE HELPERS
--// ============================================================
local function safeFire(remote, ...)
    if not remote then return false end
    local args = {...}
    local ok = pcall(function() remote:FireServer(table.unpack(args)) end)
    return ok
end

local function safeInvoke(remote, ...)
    if not remote then return false, "remote nil" end
    local args = {...}
    local ok, result = pcall(function() return remote:InvokeServer(table.unpack(args)) end)
    return ok, result
end

--// ============================================================
-- MACHINE STATE
--// ============================================================
local function getMachineState()
    local data = getPlayerData()
    if not data then return "Unknown", 0, 0 end
    
    local pm = data.petMutation
    if not pm then return "Idle", 0, 0 end
    if not pm.timeStarted then return "Idle", 0, 0 end
    
    local now
    if getSharedTime then
        local ok, t = pcall(getSharedTime)
        if ok and t then now = t else now = tick() end
    else
        now = tick()
    end
    
    local elapsed = now - pm.timeStarted
    local depletionRate = pm.depletionRate or 1
    local totalTime = (PET_MUTATION_TIME or 300) / depletionRate
    
    local remaining = math.max(0, totalTime - elapsed)
    local progress = math.clamp(elapsed / totalTime, 0, 1)
    
    if remaining <= 0 then return "Ready", 0, 1 end
    return "InProgress", remaining, progress
end

--// ============================================================
-- SCAN ELIGIBLE
--// ============================================================
local function findEligiblePets()
    if not inventoryStateModule then return {} end
    
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return {} end
    
    local data = getPlayerData()
    if not data then return {} end
    
    local equippedSet = {}
    if data.equippedPets then
        for _, id in ipairs(data.equippedPets) do
            equippedSet[id] = true
        end
    end
    
    local eligible = {}
    local seen = {}
    
    for stackKey, item in pairs(stacked) do
        local tt = tostring(item.toolType):lower()
        if tt:find("pet") and item.items and item.items[1] then
            local petId = item.items[1].id
            local petData = item.items[1].data
            
            if petId and not seen[petId] and petData then
                seen[petId] = true
                
                local age = getPetAge(petData)
                local isMaxAge = age >= CONFIG.TARGET_AGE
                local isSkip = isBelowMinMutation(petData)
                local isEquipped = equippedSet[petId] == true
                
                if isMaxAge and not isSkip and not isEquipped then
                    table.insert(eligible, {
                        id = petId,
                        data = petData,
                        age = age,
                        displayName = item.displayName or item.itemName or "?",
                        mutation = petData.mutation,
                    })
                end
            end
        end
    end
    
    table.sort(eligible, function(a, b) return a.age > b.age end)
    return eligible
end

--// ============================================================
-- FEED FUNCTION
--// ============================================================
local function feedPetToMachine(petEntry)
    local petId = petEntry.id
    local petName = petEntry.displayName
    
    print(string.format("[FEED] Pet: %s | ID: %s | Age: %d", petName, shortUUID(petId), petEntry.age))
    
    if CONFIG.DRY_RUN then
        print("  [DRY RUN] Skip eksekusi")
        return true
    end
    
    print("  ⏳ Cek mesin...")
    local waitIdle = 0
    while waitIdle < 60 do
        if not CONFIG.AUTO_FEED then return false end
        local state = getMachineState()
        if state == "Idle" then break end
        if state == "Ready" then
            print("  ⚠️ Mesin Ready, collect dulu...")
            safeInvoke(Remotes.collectMut)
            task.wait(3)
        end
        task.wait(2)
        waitIdle = waitIdle + 2
    end
    
    print("  🎒 Equip...")
    safeFire(Remotes.equipTool, petId, "pet")
    task.wait(CONFIG.DELAY_EQUIP)
    
    print("  🧬 Insert...")
    local ok, result = safeInvoke(Remotes.startMut, petId)
    if not ok or result == false or result == nil then
        print("  ❌ Insert gagal:", tostring(result))
        return false
    end
    print("  ✅ Insert OK")
    task.wait(CONFIG.DELAY_INSERT)
    
    print("  ⏳ Tunggu mutasi...")
    local waitStart = tick()
    local lastLog = 0
    
    while tick() - waitStart < CONFIG.MUTATION_TIMEOUT do
        if not CONFIG.AUTO_FEED then return false end
        
        local state, remaining, progress = getMachineState()
        if state == "Idle" then
            print("  ✅ Mesin IDLE (selesai)")
            break
        elseif state == "Ready" then
            print("  ✅ READY!")
            break
        end
        
        local now = tick()
        if now - lastLog >= 15 then
            print(string.format("  ⏳ Sisa: %s (%.0f%%)", formatTime(remaining), progress * 100))
            lastLog = now
        end
        
        task.wait(CONFIG.POLL_INTERVAL)
    end
    
    print("  📦 Collect...")
    task.wait(CONFIG.DELAY_COLLECT)
    
    local cok, cresult = safeInvoke(Remotes.collectMut)

    if cok then
        print("  🔎 Raw collect result type:", typeof(cresult))
        if type(cresult) == "table" then
            for k, v in pairs(cresult) do
                print("     ", tostring(k), "=", tostring(v))
            end
        end
    end
    
    if cok and cresult ~= false and cresult ~= nil then
        local mutationResult = parseMutationResult(cresult)
        print("  🎉 Collect OK (raw):", tostring(mutationResult))

        task.wait(1)
        local freshData, freshName = getPetDataById(petId)
        local realMutation = nil

        if freshData then
            realMutation = getMutationNameFromData(freshData)
            if freshName and freshName ~= "?" then petName = freshName end
            print("  🧬 Fresh pet data mutation:", tostring(realMutation))
        else
            print("  ⚠️ Pet data tidak ditemukan di inventory setelah collect")
        end

        if not realMutation or realMutation == "None" then
            if mutationResult and mutationResult ~= "true" then
                realMutation = mutationResult
            end
        end

        realMutation = realMutation or "None"
        print("  ✅ Mutation final:", realMutation)

        sendMutationWebhook(petName, petEntry.age, petId, realMutation)

        if realMutation == "Diamond" then
            print("  💎💎💎 DIAMOND DIDAPAT!")
            pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                    Title = "💎 Diamond Mutation!",
                    Text = petName .. " berhasil dapat Diamond!",
                    Duration = 5,
                })
            end)
        elseif realMutation == "Gold" then
            print("  🥇 GOLD DIDAPAT! Pet ini akan di-skip di scan berikutnya.")
            pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                    Title = "🥇 Gold Mutation!",
                    Text = petName .. " dapat Gold — akan di-skip",
                    Duration = 5,
                })
            end)
        end
        return true
    else
        print("  ⚠️ Collect gagal, retry...")
        for i = 1, 3 do
            task.wait(3)
            local rok, rresult = safeInvoke(Remotes.collectMut)
            if rok and rresult ~= false and rresult ~= nil then
                local mutationResult = parseMutationResult(rresult)
                print("  🎉 Collect OK (retry", i, "raw):", tostring(mutationResult))

                task.wait(1)
                local freshData, freshName = getPetDataById(petId)
                local realMutation = nil

                if freshData then
                    realMutation = getMutationNameFromData(freshData)
                    if freshName and freshName ~= "?" then petName = freshName end
                end

                if not realMutation or realMutation == "None" then
                    if mutationResult and mutationResult ~= "true" then
                        realMutation = mutationResult
                    end
                end

                realMutation = realMutation or "None"
                print("  ✅ Mutation final (retry):", realMutation)

                sendMutationWebhook(petName, petEntry.age, petId, realMutation)

                return true
            end
        end
        print("  ❌ Collect gagal 3x")
        return false
    end
end

--// ============================================================
-- POND BOOSTER (SupremeFoodTray)
--// ============================================================
local function placeBooster()
    if not Remotes.placeBuilding then
        print("[Booster] ❌ Remote ponds.placeBuilding tidak ditemukan!")
        return false
    end
    
    local args = {
        "booster",
        "SupremeFoodTray",
        Vector3.new(9.862998962402344, -0.012000083923339844, 10)
    }
    
    local ok, result = pcall(function()
        return Remotes.placeBuilding:InvokeServer(table.unpack(args))
    end)
    
    if ok then
        print("[Booster] ✅ Place OK:", tostring(result))
        return true
    else
        print("[Booster] ❌ Gagal:", tostring(result))
        return false
    end
end

local boosterRunning = false

local function boosterLoop()
    if boosterRunning then return end
    boosterRunning = true
    
    while CONFIG.BOOSTER_ENABLED do
        print(string.rep("-", 40))
        print(string.format("🍔 [Booster] Place SupremeFoodTray... (interval: %ds)", CONFIG.PLACE_BUILDING_INTERVAL))
        
        local ok = placeBooster()
        
        if ok and log then
            log(string.format("🍔 Booster placed (next %ds)", CONFIG.PLACE_BUILDING_INTERVAL))
        end
        
        local elapsed = 0
        while elapsed < CONFIG.PLACE_BUILDING_INTERVAL do
            if not CONFIG.BOOSTER_ENABLED then break end
            task.wait(1)
            elapsed = elapsed + 1
        end
    end
    
    boosterRunning = false
    print("[Booster] ⏹ Loop berhenti")
end

--// ============================================================
-- MAIN LOOP
--// ============================================================
local isRunning = false
local emptyCount = 0
local totalProcessedSession = 0

local function autoFeedLoop()
    if isRunning then return end
    isRunning = true
    emptyCount = 0
    totalProcessedSession = 0
    
    while CONFIG.AUTO_FEED do
        print(string.rep("=", 50))
        print("🔍 Scan pet eligible...")
        
        local eligible = findEligiblePets()
        local totalAll, totalEligible, totalSkipped = getInventoryStats()
        
        if #eligible == 0 then
            emptyCount = emptyCount + 1
            print(string.format("  ⏸ Tidak ada pet eligible (scan kosong #%d/%d)", 
                emptyCount, CONFIG.EMPTY_COUNT_THRESHOLD))
            
            -- ⭐ Kirim progress webhook
            sendProgressWebhook(totalEligible, totalAll, 0, totalSkipped)
            
            if CONFIG.AUTO_STOP_IF_EMPTY and emptyCount >= CONFIG.EMPTY_COUNT_THRESHOLD then
                print("  🛑 Semua pet sudah diproses / tidak ada yang eligible!")
                print("  🛑 AUTO STOP...")
                
                -- ⭐ Kirim completion webhook
                sendCompletionWebhook(totalAll, totalProcessedSession, totalSkipped)
                
                if log then
                    log("🛑 AUTO STOP: Tidak ada pet eligible")
                    log(string.format("   (scan kosong %dx)", emptyCount))
                    log(string.format("   Total diproses: %d", totalProcessedSession))
                end
                
                pcall(function()
                    game:GetService("StarterGui"):SetCore("SendNotification", {
                        Title = "🛑 Auto Mutation STOP",
                        Text = "Semua pet sudah diproses!",
                        Duration = 5,
                    })
                end)
                
                _G.__autoMutStop()
                break
            end
            
            task.wait(CONFIG.EMPTY_CHECK_DELAY)
        else
            emptyCount = 0
            print(string.format("  ✅ %d pet eligible", #eligible))
            
            local fed = 0
            for _, petEntry in ipairs(eligible) do
                if fed >= CONFIG.MAX_FEED_PER_CYCLE then break end
                if not CONFIG.AUTO_FEED then break end
                
                local success = feedPetToMachine(petEntry)
                if success then
                    fed = fed + 1
                    totalProcessedSession = totalProcessedSession + 1
                    print(string.format("  ✅ Fed %d/%d", fed, CONFIG.MAX_FEED_PER_CYCLE))
                else
                    print("  ❌ Feed gagal, skip pet ini")
                end
                task.wait(1)
            end
            
            -- ⭐ Kirim progress webhook setelah cycle selesai
            sendProgressWebhook(totalEligible, totalAll, fed, totalSkipped)
            
            task.wait(CONFIG.SCAN_INTERVAL)
        end
    end
    
    isRunning = false
end

--// ============================================================
-- GUI
--// ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoMutationSimple"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 380, 0, 570)
Frame.Position = UDim2.new(0, 20, 0.5, -285)
Frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
Frame.BorderSizePixel = 0
Frame.Active = true
Frame.Draggable = true
Frame.Parent = ScreenGui
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", Frame)
stroke.Color = Color3.fromRGB(120, 80, 200)
stroke.Thickness = 2

-- TITLE
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 34)
Title.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
Title.BorderSizePixel = 0
Title.Text = "🧬 AUTO MUTATION (v4.5)"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 13
Title.Font = Enum.Font.GothamBold
Title.Parent = Frame
Instance.new("UICorner", Title).CornerRadius = UDim.new(0, 10)

local TitleFill = Instance.new("Frame")
TitleFill.Size = UDim2.new(1, 0, 0, 8)
TitleFill.Position = UDim2.new(0, 0, 1, -8)
TitleFill.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
TitleFill.BorderSizePixel = 0
TitleFill.Parent = Title

-- CLOSE
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 26, 0, 26)
CloseBtn.Position = UDim2.new(1, -32, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 12
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

CloseBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = false
    CONFIG.BOOSTER_ENABLED = false
    ScreenGui:Destroy()
end)

-- STATUS
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 50)
StatusLabel.Position = UDim2.new(0, 10, 0, 42)
StatusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "Status: OFF | Booster: OFF\nEligible: - pet"
StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
StatusLabel.TextSize = 12
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.TextYAlignment = Enum.TextYAlignment.Top
StatusLabel.Parent = Frame
Instance.new("UICorner", StatusLabel).CornerRadius = UDim.new(0, 6)

local StatusPadding = Instance.new("UIPadding", StatusLabel)
StatusPadding.PaddingTop = UDim.new(0, 6)
StatusPadding.PaddingLeft = UDim.new(0, 10)

-- MACHINE TIMER FRAME
local MachineFrame = Instance.new("Frame")
MachineFrame.Size = UDim2.new(1, -20, 0, 70)
MachineFrame.Position = UDim2.new(0, 10, 0, 98)
MachineFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 40)
MachineFrame.BorderSizePixel = 0
MachineFrame.Parent = Frame
Instance.new("UICorner", MachineFrame).CornerRadius = UDim.new(0, 6)

local MachineStroke = Instance.new("UIStroke", MachineFrame)
MachineStroke.Color = Color3.fromRGB(100, 70, 150)
MachineStroke.Thickness = 1

local MachineTitle = Instance.new("TextLabel")
MachineTitle.Size = UDim2.new(1, -12, 0, 16)
MachineTitle.Position = UDim2.new(0, 6, 0, 4)
MachineTitle.BackgroundTransparency = 1
MachineTitle.Text = "⏱️ MESIN STATUS"
MachineTitle.TextColor3 = Color3.fromRGB(150, 150, 190)
MachineTitle.TextSize = 10
MachineTitle.Font = Enum.Font.GothamBold
MachineTitle.TextXAlignment = Enum.TextXAlignment.Left
MachineTitle.Parent = MachineFrame

local MachineStateLabel = Instance.new("TextLabel")
MachineStateLabel.Size = UDim2.new(0.5, -6, 0, 20)
MachineStateLabel.Position = UDim2.new(0, 6, 0, 22)
MachineStateLabel.BackgroundTransparency = 1
MachineStateLabel.Text = "⏸ IDLE"
MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
MachineStateLabel.TextSize = 14
MachineStateLabel.Font = Enum.Font.GothamBold
MachineStateLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineStateLabel.Parent = MachineFrame

local MachineTimerLabel = Instance.new("TextLabel")
MachineTimerLabel.Size = UDim2.new(0.5, -6, 0, 20)
MachineTimerLabel.Position = UDim2.new(0.5, 0, 0, 22)
MachineTimerLabel.BackgroundTransparency = 1
MachineTimerLabel.Text = "00:00"
MachineTimerLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
MachineTimerLabel.TextSize = 14
MachineTimerLabel.Font = Enum.Font.Code
MachineTimerLabel.TextXAlignment = Enum.TextXAlignment.Right
MachineTimerLabel.Parent = MachineFrame

local ProgressBg = Instance.new("Frame")
ProgressBg.Size = UDim2.new(1, -12, 0, 8)
ProgressBg.Position = UDim2.new(0, 6, 0, 50)
ProgressBg.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
ProgressBg.BorderSizePixel = 0
ProgressBg.Parent = MachineFrame
Instance.new("UICorner", ProgressBg).CornerRadius = UDim.new(1, 0)

local ProgressFill = Instance.new("Frame")
ProgressFill.Size = UDim2.new(0, 0, 1, 0)
ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
ProgressFill.BorderSizePixel = 0
ProgressFill.Parent = ProgressBg
Instance.new("UICorner", ProgressFill).CornerRadius = UDim.new(1, 0)

-- INFO
local InfoLabel = Instance.new("TextLabel")
InfoLabel.Size = UDim2.new(1, -20, 0, 50)
InfoLabel.Position = UDim2.new(0, 10, 0, 174)
InfoLabel.BackgroundColor3 = Color3.fromRGB(25, 25, 38)
InfoLabel.BorderSizePixel = 0
InfoLabel.Text = string.format(
    "Target Age: %d | Min Mutation: %s\nSkip: %s | Auto Stop: x%d empty",
    CONFIG.TARGET_AGE, CONFIG.MIN_MUTATION,
    table.concat(CONFIG.SKIP_MUTATIONS, ", "),
    CONFIG.EMPTY_COUNT_THRESHOLD
)
InfoLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
InfoLabel.TextSize = 10
InfoLabel.Font = Enum.Font.Code
InfoLabel.TextXAlignment = Enum.TextXAlignment.Left
InfoLabel.TextYAlignment = Enum.TextYAlignment.Top
InfoLabel.Parent = Frame
Instance.new("UICorner", InfoLabel).CornerRadius = UDim.new(0, 6)

local InfoPadding = Instance.new("UIPadding", InfoLabel)
InfoPadding.PaddingTop = UDim.new(0, 6)
InfoPadding.PaddingLeft = UDim.new(0, 10)

-- LOG
local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -20, 0, 58)
LogLabel.Position = UDim2.new(0, 10, 0, 230)
LogLabel.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
LogLabel.BorderSizePixel = 0
LogLabel.Text = "[Log akan muncul di sini]"
LogLabel.TextColor3 = Color3.fromRGB(180, 200, 180)
LogLabel.TextSize = 9
LogLabel.Font = Enum.Font.Code
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.Parent = Frame
Instance.new("UICorner", LogLabel).CornerRadius = UDim.new(0, 6)

local LogPadding = Instance.new("UIPadding", LogLabel)
LogPadding.PaddingTop = UDim.new(0, 4)
LogPadding.PaddingLeft = UDim.new(0, 6)

-- BOOSTER SECTION
local BoosterFrame = Instance.new("Frame")
BoosterFrame.Size = UDim2.new(1, -20, 0, 70)
BoosterFrame.Position = UDim2.new(0, 10, 0, 296)
BoosterFrame.BackgroundColor3 = Color3.fromRGB(25, 35, 25)
BoosterFrame.BorderSizePixel = 0
BoosterFrame.Parent = Frame
Instance.new("UICorner", BoosterFrame).CornerRadius = UDim.new(0, 6)

local BoosterStroke = Instance.new("UIStroke", BoosterFrame)
BoosterStroke.Color = Color3.fromRGB(80, 150, 80)
BoosterStroke.Thickness = 1

local BoosterTitle = Instance.new("TextLabel")
BoosterTitle.Size = UDim2.new(1, -12, 0, 16)
BoosterTitle.Position = UDim2.new(0, 6, 0, 4)
BoosterTitle.BackgroundTransparency = 1
BoosterTitle.Text = "🍔 POND BOOSTER (SupremeFoodTray)"
BoosterTitle.TextColor3 = Color3.fromRGB(150, 220, 150)
BoosterTitle.TextSize = 10
BoosterTitle.Font = Enum.Font.GothamBold
BoosterTitle.TextXAlignment = Enum.TextXAlignment.Left
BoosterTitle.Parent = BoosterFrame

local BoosterToggle = Instance.new("TextButton")
BoosterToggle.Size = UDim2.new(0.45, -6, 0, 26)
BoosterToggle.Position = UDim2.new(0, 6, 0, 24)
BoosterToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
BoosterToggle.BorderSizePixel = 0
BoosterToggle.Text = "▶ BOOSTER: OFF"
BoosterToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
BoosterToggle.TextSize = 11
BoosterToggle.Font = Enum.Font.GothamBold
BoosterToggle.Parent = BoosterFrame
Instance.new("UICorner", BoosterToggle).CornerRadius = UDim.new(0, 6)

local IntervalLabel = Instance.new("TextLabel")
IntervalLabel.Size = UDim2.new(0.15, 0, 0, 26)
IntervalLabel.Position = UDim2.new(0.45, 2, 0, 24)
IntervalLabel.BackgroundTransparency = 1
IntervalLabel.Text = "Every:"
IntervalLabel.TextColor3 = Color3.fromRGB(180, 220, 180)
IntervalLabel.TextSize = 10
IntervalLabel.Font = Enum.Font.GothamBold
IntervalLabel.TextXAlignment = Enum.TextXAlignment.Right
IntervalLabel.Parent = BoosterFrame

local IntervalBox = Instance.new("TextBox")
IntervalBox.Size = UDim2.new(0.2, -6, 0, 26)
IntervalBox.Position = UDim2.new(0.6, 2, 0, 24)
IntervalBox.BackgroundColor3 = Color3.fromRGB(40, 50, 40)
IntervalBox.BorderSizePixel = 0
IntervalBox.Text = tostring(CONFIG.PLACE_BUILDING_INTERVAL)
IntervalBox.TextColor3 = Color3.fromRGB(220, 255, 220)
IntervalBox.TextSize = 12
IntervalBox.Font = Enum.Font.Code
IntervalBox.PlaceholderText = "sec"
IntervalBox.Parent = BoosterFrame
Instance.new("UICorner", IntervalBox).CornerRadius = UDim.new(0, 6)

local IntervalUnit = Instance.new("TextLabel")
IntervalUnit.Size = UDim2.new(0.15, 0, 0, 26)
IntervalUnit.Position = UDim2.new(0.8, 0, 0, 24)
IntervalUnit.BackgroundTransparency = 1
IntervalUnit.Text = "sec"
IntervalUnit.TextColor3 = Color3.fromRGB(150, 180, 150)
IntervalUnit.TextSize = 10
IntervalUnit.Font = Enum.Font.Gotham
IntervalUnit.Parent = BoosterFrame

-- ⭐ WEBHOOK SECTION (REDESIGN)
local WebhookFrame = Instance.new("Frame")
WebhookFrame.Size = UDim2.new(1, -20, 0, 96)
WebhookFrame.Position = UDim2.new(0, 10, 0, 372)
WebhookFrame.BackgroundColor3 = Color3.fromRGB(30, 25, 45)
WebhookFrame.BorderSizePixel = 0
WebhookFrame.Parent = Frame
Instance.new("UICorner", WebhookFrame).CornerRadius = UDim.new(0, 6)

local WebhookStroke = Instance.new("UIStroke", WebhookFrame)
WebhookStroke.Color = Color3.fromRGB(140, 100, 220)
WebhookStroke.Thickness = 1

local WebhookTitle = Instance.new("TextLabel")
WebhookTitle.Size = UDim2.new(1, -12, 0, 16)
WebhookTitle.Position = UDim2.new(0, 6, 0, 4)
WebhookTitle.BackgroundTransparency = 1
WebhookTitle.Text = "🔔 DISCORD WEBHOOK"
WebhookTitle.TextColor3 = Color3.fromRGB(200, 170, 255)
WebhookTitle.TextSize = 10
WebhookTitle.Font = Enum.Font.GothamBold
WebhookTitle.TextXAlignment = Enum.TextXAlignment.Left
WebhookTitle.Parent = WebhookFrame

-- BARIS 1: Toggle ON/OFF (kiri) + Status (tengah) + Tombol TEST (kanan)
local WebhookToggle = Instance.new("TextButton")
WebhookToggle.Size = UDim2.new(0.28, -4, 0, 24)
WebhookToggle.Position = UDim2.new(0, 6, 0, 22)
WebhookToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
WebhookToggle.BorderSizePixel = 0
WebhookToggle.Text = "OFF"
WebhookToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookToggle.TextSize = 11
WebhookToggle.Font = Enum.Font.GothamBold
WebhookToggle.Parent = WebhookFrame
Instance.new("UICorner", WebhookToggle).CornerRadius = UDim.new(0, 6)

local WebhookTest = Instance.new("TextButton")
WebhookTest.Size = UDim2.new(0.28, -4, 0, 24)
WebhookTest.Position = UDim2.new(0.72, 0, 0, 22)
WebhookTest.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
WebhookTest.BorderSizePixel = 0
WebhookTest.Text = "🔔 TEST"
WebhookTest.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookTest.TextSize = 11
WebhookTest.Font = Enum.Font.GothamBold
WebhookTest.Parent = WebhookFrame
Instance.new("UICorner", WebhookTest).CornerRadius = UDim.new(0, 6)

-- Status kecil di tengah baris 1
local WebhookStatus = Instance.new("TextLabel")
WebhookStatus.Size = UDim2.new(0.44, 0, 0, 24)
WebhookStatus.Position = UDim2.new(0.28, 0, 0, 22)
WebhookStatus.BackgroundTransparency = 1
WebhookStatus.Text = "Mutation • Progress • Complete"
WebhookStatus.TextColor3 = Color3.fromRGB(150, 150, 180)
WebhookStatus.TextSize = 9
WebhookStatus.Font = Enum.Font.Gotham
WebhookStatus.Parent = WebhookFrame

-- BARIS 2: URL TextBox full width
local WebhookBox = Instance.new("TextBox")
WebhookBox.Size = UDim2.new(1, -12, 0, 26)
WebhookBox.Position = UDim2.new(0, 6, 0, 52)
WebhookBox.BackgroundColor3 = Color3.fromRGB(40, 35, 55)
WebhookBox.BorderSizePixel = 0
WebhookBox.Text = CONFIG.WEBHOOK_URL
WebhookBox.PlaceholderText = "https://discord.com/api/webhooks/..."
WebhookBox.TextColor3 = Color3.fromRGB(220, 210, 255)
WebhookBox.PlaceholderColor3 = Color3.fromRGB(120, 110, 150)
WebhookBox.TextSize = 11
WebhookBox.Font = Enum.Font.Code
WebhookBox.TextXAlignment = Enum.TextXAlignment.Left
WebhookBox.ClearTextOnFocus = false
WebhookBox.TextTruncate = Enum.TextTruncate.AtEnd
WebhookBox.Parent = WebhookFrame
Instance.new("UICorner", WebhookBox).CornerRadius = UDim.new(0, 6)

local WebhookBoxPadding = Instance.new("UIPadding", WebhookBox)
WebhookBoxPadding.PaddingLeft = UDim.new(0, 8)
WebhookBoxPadding.PaddingRight = UDim.new(0, 8)

-- Label kecil di bawah box
local WebhookHint = Instance.new("TextLabel")
WebhookHint.Size = UDim2.new(1, -12, 0, 14)
WebhookHint.Position = UDim2.new(0, 6, 0, 80)
WebhookHint.BackgroundTransparency = 1
WebhookHint.Text = "Klik TEST untuk cek koneksi • Enter untuk simpan URL"
WebhookHint.TextColor3 = Color3.fromRGB(130, 130, 160)
WebhookHint.TextSize = 9
WebhookHint.Font = Enum.Font.Gotham
WebhookHint.TextXAlignment = Enum.TextXAlignment.Left
WebhookHint.Parent = WebhookFrame

-- TOGGLE BUTTON (Auto Mutation)
local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, -20, 0, 36)
ToggleBtn.Position = UDim2.new(0, 10, 1, -46)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶ START"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 14
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = Frame
Instance.new("UICorner", ToggleBtn).CornerRadius = UDim.new(0, 8)

-- LOG FUNCTION
local function log(msg)
    local time = os.date("%H:%M:%S")
    local newText = LogLabel.Text .. "\n[" .. time .. "] " .. msg
    local lines = {}
    for line in newText:gmatch("[^\n]+") do table.insert(lines, line) end
    while #lines > 4 do table.remove(lines, 1) end
    LogLabel.Text = table.concat(lines, "\n")
    print("[AutoMut] " .. msg)
end

-- GLOBAL STOP
function _G.__autoMutStop()
    CONFIG.AUTO_FEED = false
    emptyCount = 0
    
    if ToggleBtn then
        ToggleBtn.Text = "▶ START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
    end
    if StatusLabel then
        StatusLabel.Text = "Status: STOPPED (auto) | Booster: " ..
            (CONFIG.BOOSTER_ENABLED and "ON" or "OFF") .. "\nEligible: 0 pet"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
    end
    
    print("[AutoMut] 🛑 Auto stop dipicu")
end

-- TOGGLE HANDLER (Auto Mutation)
ToggleBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = not CONFIG.AUTO_FEED
    
    if CONFIG.AUTO_FEED then
        emptyCount = 0
        totalProcessedSession = 0
        ToggleBtn.Text = "⏹ STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        StatusLabel.Text = "Status: RUNNING | Booster: " ..
            (CONFIG.BOOSTER_ENABLED and "ON" or "OFF") .. "\nEligible: - pet"
        StatusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        log("🚀 START")
        task.spawn(autoFeedLoop)
    else
        emptyCount = 0
        ToggleBtn.Text = "▶ START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        StatusLabel.Text = "Status: OFF | Booster: " ..
            (CONFIG.BOOSTER_ENABLED and "ON" or "OFF") .. "\nEligible: - pet"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        log("⏹ STOP (manual)")
    end
end)

-- BOOSTER TOGGLE HANDLER
BoosterToggle.MouseButton1Click:Connect(function()
    CONFIG.BOOSTER_ENABLED = not CONFIG.BOOSTER_ENABLED
    
    if CONFIG.BOOSTER_ENABLED then
        BoosterToggle.Text = "⏹ BOOSTER: ON"
        BoosterToggle.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        BoosterStroke.Color = Color3.fromRGB(120, 255, 120)
        log("🍔 Booster ON")
        task.spawn(boosterLoop)
    else
        BoosterToggle.Text = "▶ BOOSTER: OFF"
        BoosterToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        BoosterStroke.Color = Color3.fromRGB(80, 150, 80)
        log("🍔 Booster OFF")
    end
end)

-- INTERVAL INPUT HANDLER
IntervalBox.FocusLost:Connect(function(enterPressed)
    local val = tonumber(IntervalBox.Text)
    if val and val >= 1 and val <= 3600 then
        CONFIG.PLACE_BUILDING_INTERVAL = math.floor(val)
        IntervalBox.Text = tostring(CONFIG.PLACE_BUILDING_INTERVAL)
        log(string.format("⏱️ Interval booster: %ds", CONFIG.PLACE_BUILDING_INTERVAL))
    else
        IntervalBox.Text = tostring(CONFIG.PLACE_BUILDING_INTERVAL)
        log("⚠️ Interval invalid (1-3600 sec)")
    end
end)

-- ⭐ WEBHOOK TOGGLE HANDLER
WebhookToggle.MouseButton1Click:Connect(function()
    CONFIG.WEBHOOK_ENABLED = not CONFIG.WEBHOOK_ENABLED
    if CONFIG.WEBHOOK_ENABLED then
        if CONFIG.WEBHOOK_URL == "" then
            CONFIG.WEBHOOK_ENABLED = false
            log("⚠️ Isi URL webhook dulu!")
            return
        end
        WebhookToggle.Text = "ON"
        WebhookToggle.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        WebhookStroke.Color = Color3.fromRGB(180, 140, 255)
        log("🔔 Webhook ON (mutation + progress + complete)")
    else
        WebhookToggle.Text = "OFF"
        WebhookToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        WebhookStroke.Color = Color3.fromRGB(140, 100, 220)
        log("🔔 Webhook OFF")
    end
end)

-- ⭐ WEBHOOK URL INPUT HANDLER
WebhookBox.FocusLost:Connect(function()
    local url = WebhookBox.Text
    if url:match("^https://discord%.com/api/webhooks/") then
        CONFIG.WEBHOOK_URL = url
        log("🔔 URL webhook disimpan")
    else
        WebhookBox.Text = CONFIG.WEBHOOK_URL
        log("⚠️ URL webhook invalid")
    end
end)

-- ⭐ TEST WEBHOOK HANDLER
WebhookTest.MouseButton1Click:Connect(function()
    local url = CONFIG.WEBHOOK_URL

    if not url or url == "" then
        log("⚠️ URL webhook kosong!")
        return
    end
    if not url:match("^https://discord%.com/api/webhooks/") then
        log("⚠️ URL webhook invalid!")
        return
    end

    WebhookTest.Text = "..."
    WebhookTest.BackgroundColor3 = Color3.fromRGB(180, 140, 60)
    log("🔔 Test webhook dikirim...")

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        embeds = {{
            title = "🔔 TEST WEBHOOK BERHASIL",
            description = "Kalau kamu lihat pesan ini, webhook sudah **terhubung dengan benar** ✅\n\nFitur webhook:\n• 🧬 Hasil mutasi per pet\n• 📊 Progress tiap cycle\n• 🎉 Notifikasi selesai",
            color = 0x8A50C8,
            fields = {
                { name = "Player",  value = LocalPlayer.Name,             inline = true },
                { name = "User ID", value = tostring(LocalPlayer.UserId), inline = true },
                { name = "Time",    value = os.date("%Y-%m-%d %H:%M:%S"), inline = false },
            },
            footer = { text = "Auto Mutation v4.5 • Test" },
        }},
    }

    local body = HttpService:JSONEncode(payload)

    task.spawn(function()
        local ok, err = httpPost(url, body)

        if ok then
            WebhookTest.Text = "✅ OK"
            WebhookTest.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
            log("✅ Test webhook BERHASIL — cek Discord!")
        else
            WebhookTest.Text = "❌ FAIL"
            WebhookTest.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
            log("❌ Test webhook GAGAL: " .. tostring(err))
            warn("[Webhook] Test gagal:", tostring(err))
        end

        task.wait(3)
        if WebhookTest and WebhookTest.Parent then
            WebhookTest.Text = "🔔 TEST"
            WebhookTest.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
        end
    end)
end)

-- TIMER UPDATE
task.spawn(function()
    while ScreenGui.Parent do
        local state, remaining, progress = getMachineState()
        
        if state == "Idle" then
            MachineStateLabel.Text = "⏸ IDLE"
            MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
            MachineTimerLabel.Text = "00:00"
            MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 120, 140)
            ProgressFill.Size = UDim2.new(0, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
            MachineStroke.Color = Color3.fromRGB(80, 80, 100)
        elseif state == "InProgress" then
            MachineStateLabel.Text = "⚙️ MUTATING"
            MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
            MachineTimerLabel.Text = formatTime(remaining)
            MachineTimerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
            ProgressFill.Size = UDim2.new(progress, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
            MachineStroke.Color = Color3.fromRGB(255, 180, 60)
        elseif state == "Ready" then
            MachineStateLabel.Text = "✅ READY!"
            MachineStateLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
            MachineTimerLabel.Text = "00:00"
            MachineTimerLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
            ProgressFill.Size = UDim2.new(1, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 255, 120)
            MachineStroke.Color = Color3.fromRGB(120, 255, 120)
        else
            MachineStateLabel.Text = "❓ UNKNOWN"
            MachineStateLabel.TextColor3 = Color3.fromRGB(200, 100, 100)
            MachineTimerLabel.Text = "--:--"
        end
        
        task.wait(0.5)
    end
end)

-- INFO UPDATE
task.spawn(function()
    while ScreenGui.Parent do
        local eligible = findEligiblePets()
        local totalAll, totalEligible, totalSkipped = getInventoryStats()
        StatusLabel.Text = string.format(
            "Status: %s | Booster: %s\nEligible: %d | Total: %d | Skip: %d",
            CONFIG.AUTO_FEED and "RUNNING" or "OFF",
            CONFIG.BOOSTER_ENABLED and "ON" or "OFF",
            totalEligible, totalAll, totalSkipped
        )
        task.wait(3)
    end
end)

-- TOGGLE KEY
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        ScreenGui.Enabled = not ScreenGui.Enabled
    end
end)

-- PRINT
log("✅ GUI loaded (v4.5)")
log("🎯 Min Mutation: " .. CONFIG.MIN_MUTATION)
log("🛑 Skip: " .. table.concat(CONFIG.SKIP_MUTATIONS, ", "))
log("🔔 Webhook: mutation + progress + complete")
log("🌐 HTTP: request/http_request/PostAsync fallback")
print("[AutoMut] ✅ Loaded v4.5! RightShift toggle GUI.")
