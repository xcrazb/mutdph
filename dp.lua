-- ============================================================
-- AUTO MUTATION v4.9 CLEAN
-- Auto scan + feed mutation + webhook (mutasi + completion)
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
    SCAN_INTERVAL = 1,
    TARGET_AGE = 50,

    SKIP_MUTATIONS = {"Diamond"},
    MIN_MUTATION = "Diamond",

    MUTATION_TIERS = {
        "None", "Bronze", "Silver", "Gold", "Diamond", "Rainbow", "Celestial",
    },

    DELAY_EQUIP = 0.4,
    DELAY_INSERT = 1,
    DELAY_COLLECT = 2,
    MAX_FEED_PER_CYCLE = 1,
    POLL_INTERVAL = 2,
    MUTATION_TIMEOUT = 600,

    AUTO_STOP_IF_EMPTY = true,
    EMPTY_CHECK_DELAY = 0,
    EMPTY_COUNT_THRESHOLD = 3,

    WEBHOOK_ENABLED = false,
    WEBHOOK_URL = "",
    WEBHOOK_USERNAME = "Auto Mutation v4.9",
    WEBHOOK_SEND_COMPLETE = true,
}

--// ============================================================
-- MODULES
--// ============================================================
local playerDataModule = require(ReplicatedStorage.TS.state["player-data"])
local petAgeUtils = require(ReplicatedStorage.TS.utils["pet-age.utils"])
local calculatePetWeight = petAgeUtils.calculatePetWeight
local formatPetWeight = petAgeUtils.formatPetWeight

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
-- REMOTES
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
    equipTool  = getRemo("tools.equipTool"),
    startMut   = getRemo("pets.startMutation"),
    collectMut = getRemo("pets.collectMutation"),
}

--// ============================================================
-- HELPERS
--// ============================================================
local function getPlayerData()
    local ok, data = pcall(playerDataModule.getPlayerDataById, tostring(LocalPlayer.UserId))
    return ok and data or nil
end

local function getPetAge(petData)
    local ok, age = pcall(petAgeUtils.getPetAgeFromData, petData)
    return ok and age or 0
end

local function getPetWeight(petData)
    if not petData then return nil end
    if calculatePetWeight then
        local ok, w = pcall(calculatePetWeight, petData)
        if ok and w ~= nil then return w end
    end
    return petData.weight or petData.w or petData.weightKg
end

local function formatWeight(w)
    if w == nil then return "?" end
    if formatPetWeight then
        local ok, f = pcall(formatPetWeight, w)
        if ok and f ~= nil then return tostring(f) end
    end
    if type(w) == "number" then return string.format("%.2f", w) end
    return tostring(w)
end

local function getMutationTierIndex(mutName)
    if not mutName or mutName == "" then return 1 end
    for i, tier in ipairs(CONFIG.MUTATION_TIERS) do
        if string.lower(tier) == string.lower(tostring(mutName)) then return i end
    end
    return 1
end

local function getHighestMutation(petData)
    if not petData or not petData.mutation then return nil end
    local mut = petData.mutation
    if type(mut) == "string" then return mut end
    if type(mut) == "table" then
        local highest, highestIdx = nil, 0
        for _, m in ipairs(mut) do
            local idx = getMutationTierIndex(m)
            if idx > highestIdx then highestIdx = idx; highest = m end
        end
        return highest
    end
    return nil
end

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
    if isSkippedMutation(petData) then return true end
    if CONFIG.MIN_MUTATION == "None" then return false end
    local highest = getHighestMutation(petData)
    local petTier = getMutationTierIndex(highest)
    local minTier = getMutationTierIndex(CONFIG.MIN_MUTATION)
    return petTier >= minTier and petTier > 1
end

local function formatTime(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 0 then seconds = 0 end
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function parseMutationResult(result)
    if result == nil or result == false then return nil end
    if type(result) == "string" then return result end
    if type(result) == "table" then
        return result.mutation or result.mutationType or result.name or result.type
    end
    return tostring(result)
end

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
-- HTTP
--// ============================================================
local function httpPost(url, body)
    local reqFunc = (request) or (http_request) or (http and http.request)
    if reqFunc then
        local ok, res = pcall(function()
            return reqFunc({
                Url = url, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)
        if ok and res then
            local code = res.StatusCode or res.Status or 0
            if code >= 200 and code < 300 then return true, "OK " .. code end
            return false, "HTTP " .. tostring(code)
        end
    end
    local ok, err = pcall(function()
        HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
    end)
    if ok then return true, "PostAsync OK" end
    return false, tostring(err)
end

--// ============================================================
-- WEBHOOK: MUTASI
--// ============================================================
local function sendMutationWebhook(petName, petWeight, mutationResult)
    if not CONFIG.WEBHOOK_ENABLED or CONFIG.WEBHOOK_URL == "" then return end

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

    local weightText = formatWeight(petWeight)
    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        content = string.format("**%s** — %s", mut, weightText),
        embeds = {{
            title = "🧬 " .. mut,
            color = color,
            description = string.format("**%s** — %s", tostring(petName), weightText),
            footer = { text = "Auto Mutation v4.9 • " .. os.date("%H:%M:%S") },
        }},
    }

    task.spawn(function()
        httpPost(CONFIG.WEBHOOK_URL, HttpService:JSONEncode(payload))
    end)
end

--// ============================================================
-- WEBHOOK: COMPLETION
--// ============================================================
local completionSent = false
local sessionMutationCount = {}
local sessionPetCount = 0

local function sendCompletionWebhook(totalAll, totalProcessed, totalSkipped)
    if not CONFIG.WEBHOOK_ENABLED or not CONFIG.WEBHOOK_SEND_COMPLETE then return end
    if CONFIG.WEBHOOK_URL == "" or completionSent then return end
    completionSent = true

    local mutationLines = {}
    local totalMutated = 0

    local sortedMuts = {}
    for mut, count in pairs(sessionMutationCount) do
        table.insert(sortedMuts, { name = mut, count = count })
    end
    table.sort(sortedMuts, function(a, b)
        return getMutationTierIndex(a.name) > getMutationTierIndex(b.name)
    end)

    for _, entry in ipairs(sortedMuts) do
        local emoji = "🧬"
        if entry.name == "Diamond" then emoji = "💎"
        elseif entry.name == "Gold" then emoji = "🥇"
        elseif entry.name == "Silver" then emoji = "🥈"
        elseif entry.name == "Bronze" then emoji = "🥉"
        elseif entry.name == "Rainbow" then emoji = "🌈"
        elseif entry.name == "Celestial" then emoji = "✨"
        elseif entry.name == "None" then emoji = "⚪"
        end
        table.insert(mutationLines, string.format("%s **%s** × %d", emoji, entry.name, entry.count))
        if entry.name ~= "None" then totalMutated = totalMutated + entry.count end
    end

    local mutationSummary = #mutationLines > 0
        and table.concat(mutationLines, "\n") or "*Tidak ada mutasi*"

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        content = "✅ **SEMUA PET TELAH SELESAI DI MUTASIKAN!**",
        embeds = {{
            title = "🎉 Auto Mutation Selesai",
            description = "Semua pet yang eligible sudah diproses.",
            color = 0x2ECC71,
            fields = {
                { name = "📦 Total Pet",          value = tostring(totalAll),       inline = true },
                { name = "✅ Total Diproses",     value = tostring(totalProcessed), inline = true },
                { name = "⏭️ Total Skipped",      value = tostring(totalSkipped),   inline = true },
                { name = "🎯 Target Age",         value = tostring(CONFIG.TARGET_AGE), inline = true },
                { name = "💎 Min Mutation",       value = tostring(CONFIG.MIN_MUTATION), inline = true },
                { name = "👤 Player",             value = LocalPlayer.Name, inline = true },
                { name = "━━━━━━━━━━━━━━━━━━━━━━━━━━", value = "**📊 HASIL MUTASI SESI INI**", inline = false },
                { name = "🧬 Rincian Mutasi",     value = mutationSummary, inline = false },
                { name = "🏆 Total Bermutasi",    value = tostring(totalMutated) .. " pet", inline = true },
                { name = "📈 Total Pet Diproses", value = tostring(sessionPetCount) .. " pet", inline = true },
            },
            footer = { text = "Auto Mutation v4.9 • " .. os.date("%Y-%m-%d %H:%M:%S") },
        }},
    }

    task.spawn(function()
        httpPost(CONFIG.WEBHOOK_URL, HttpService:JSONEncode(payload))
    end)
end

--// ============================================================
-- INVENTORY STATS
--// ============================================================
local function getInventoryStats()
    if not inventoryStateModule then return 0, 0, 0 end
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return 0, 0, 0 end

    local totalAll, totalEligible, totalSkipped = 0, 0, 0
    local data = getPlayerData()
    local equippedSet = {}
    if data and data.equippedPets then
        for _, id in ipairs(data.equippedPets) do equippedSet[id] = true end
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
    return pcall(function() remote:FireServer(table.unpack(args)) end)
end

local function safeInvoke(remote, ...)
    if not remote then return false, "nil" end
    local args = {...}
    return pcall(function() return remote:InvokeServer(table.unpack(args)) end)
end

--// ============================================================
-- MACHINE STATE
--// ============================================================
local function getMachineState()
    local data = getPlayerData()
    if not data then return "Unknown", 0, 0 end
    local pm = data.petMutation
    if not pm or not pm.timeStarted then return "Idle", 0, 0 end

    local now
    if getSharedTime then
        local ok, t = pcall(getSharedTime)
        now = (ok and t) or tick()
    else
        now = tick()
    end

    local elapsed = now - pm.timeStarted
    local rate = pm.depletionRate or 1
    local totalTime = (PET_MUTATION_TIME or 300) / rate
    local remaining = math.max(0, totalTime - elapsed)
    local progress = math.clamp(elapsed / totalTime, 0, 1)

    if remaining <= 0 then return "Ready", 0, 1 end
    return "InProgress", remaining, progress
end

--// ============================================================
-- SCAN
--// ============================================================
local function findEligiblePets()
    if not inventoryStateModule then return {} end
    local ok, stacked = pcall(function() return inventoryStateModule.inventoryStackedData() end)
    if not ok or not stacked then return {} end

    local data = getPlayerData()
    if not data then return {} end

    local equippedSet = {}
    if data.equippedPets then
        for _, id in ipairs(data.equippedPets) do equippedSet[id] = true end
    end

    local eligible, seen = {}, {}
    for _, item in pairs(stacked) do
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
                        id = petId, data = petData, age = age,
                        displayName = item.displayName or item.itemName or "?",
                    })
                end
            end
        end
    end

    table.sort(eligible, function(a, b) return a.age > b.age end)
    return eligible
end

--// ============================================================
-- FEED
--// ============================================================
local function feedPetToMachine(petEntry)
    local petId = petEntry.id
    local petName = petEntry.displayName

    -- tunggu idle
    local waitIdle = 0
    while waitIdle < 60 do
        if not CONFIG.AUTO_FEED then return false end
        local state = getMachineState()
        if state == "Idle" then break end
        if state == "Ready" then
            safeInvoke(Remotes.collectMut)
            task.wait(3)
        end
        task.wait(2)
        waitIdle = waitIdle + 2
    end

    safeFire(Remotes.equipTool, petId, "pet")
    task.wait(CONFIG.DELAY_EQUIP)

    local ok, result = safeInvoke(Remotes.startMut, petId)
    if not ok or result == false or result == nil then return false end
    task.wait(CONFIG.DELAY_INSERT)

    local waitStart = tick()
    while tick() - waitStart < CONFIG.MUTATION_TIMEOUT do
        if not CONFIG.AUTO_FEED then return false end
        local state = getMachineState()
        if state == "Idle" or state == "Ready" then break end
        task.wait(CONFIG.POLL_INTERVAL)
    end

    task.wait(CONFIG.DELAY_COLLECT)
    local cok, cresult = safeInvoke(Remotes.collectMut)

    local function processCollect(res)
        local mutationResult = parseMutationResult(res)
        task.wait(1)

        local freshData, freshName = getPetDataById(petId)
        local realMutation, petWeight = nil, nil

        if freshData then
            realMutation = getMutationNameFromData(freshData)
            petWeight = getPetWeight(freshData)
            if freshName and freshName ~= "?" then petName = freshName end
        end

        if not realMutation or realMutation == "None" then
            if mutationResult and mutationResult ~= "true" then
                realMutation = mutationResult
            end
        end
        realMutation = realMutation or "None"

        sessionMutationCount[realMutation] = (sessionMutationCount[realMutation] or 0) + 1
        sessionPetCount = sessionPetCount + 1

        sendMutationWebhook(petName, petWeight, realMutation)
    end

    if cok and cresult ~= false and cresult ~= nil then
        processCollect(cresult)
        return true
    else
        for _ = 1, 3 do
            task.wait(3)
            local rok, rresult = safeInvoke(Remotes.collectMut)
            if rok and rresult ~= false and rresult ~= nil then
                processCollect(rresult)
                return true
            end
        end
        return false
    end
end

--// ============================================================
-- MAIN LOOP
--// ============================================================
local isRunning = false
local emptyCount = 0
local totalProcessedSession = 0
local hasProcessedAny = false

local function autoFeedLoop()
    if isRunning then return end
    isRunning = true
    emptyCount = 0
    totalProcessedSession = 0
    hasProcessedAny = false
    completionSent = false

    while CONFIG.AUTO_FEED do
        local eligible = findEligiblePets()
        local totalAll, _, totalSkipped = getInventoryStats()

        if #eligible == 0 then
            if hasProcessedAny then
                emptyCount = emptyCount + 1

                if CONFIG.AUTO_STOP_IF_EMPTY and emptyCount >= CONFIG.EMPTY_COUNT_THRESHOLD then
                    sendCompletionWebhook(totalAll, totalProcessedSession, totalSkipped)

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
            end
            task.wait(CONFIG.EMPTY_CHECK_DELAY)
        else
            emptyCount = 0
            hasProcessedAny = true

            local fed = 0
            for _, petEntry in ipairs(eligible) do
                if fed >= CONFIG.MAX_FEED_PER_CYCLE or not CONFIG.AUTO_FEED then break end
                if feedPetToMachine(petEntry) then
                    fed = fed + 1
                    totalProcessedSession = totalProcessedSession + 1
                end
                task.wait(1)
            end
            task.wait(CONFIG.SCAN_INTERVAL)
        end
    end

    isRunning = false
end

--// ============================================================
-- GUI
--// ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AutoMutation"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 280, 0, 240)
Frame.Position = UDim2.new(0, 20, 0.5, -120)
Frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
Frame.BorderSizePixel = 0
Frame.Active = true
Frame.Draggable = true
Frame.Parent = ScreenGui
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke", Frame)
stroke.Color = Color3.fromRGB(120, 80, 200)
stroke.Thickness = 1.5

-- TITLE
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 26)
Title.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
Title.BorderSizePixel = 0
Title.Text = "🧬 AUTO MUTATION v4.9"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 11
Title.Font = Enum.Font.GothamBold
Title.Parent = Frame
Instance.new("UICorner", Title).CornerRadius = UDim.new(0, 8)

local TitleFill = Instance.new("Frame")
TitleFill.Size = UDim2.new(1, 0, 0, 6)
TitleFill.Position = UDim2.new(0, 0, 1, -6)
TitleFill.BackgroundColor3 = Color3.fromRGB(55, 40, 85)
TitleFill.BorderSizePixel = 0
TitleFill.Parent = Title

-- MINIMIZE
local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 20, 0, 20)
MinBtn.Position = UDim2.new(1, -46, 0, 3)
MinBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 120)
MinBtn.BorderSizePixel = 0
MinBtn.Text = "—"
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.TextSize = 12
MinBtn.Font = Enum.Font.GothamBold
MinBtn.Parent = Title
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 4)

-- CLOSE
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 20, 0, 20)
CloseBtn.Position = UDim2.new(1, -24, 0, 3)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "✕"
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.TextSize = 11
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.Parent = Title
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 4)

-- BODY
local Body = Instance.new("Frame")
Body.Size = UDim2.new(1, 0, 1, -26)
Body.Position = UDim2.new(0, 0, 0, 26)
Body.BackgroundTransparency = 1
Body.Parent = Frame

-- STATUS
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -12, 0, 34)
StatusLabel.Position = UDim2.new(0, 6, 0, 4)
StatusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "OFF | Eligible: -"
StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
StatusLabel.TextSize = 10
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.TextYAlignment = Enum.TextYAlignment.Top
StatusLabel.Parent = Body
Instance.new("UICorner", StatusLabel).CornerRadius = UDim.new(0, 5)
local StatusPadding = Instance.new("UIPadding", StatusLabel)
StatusPadding.PaddingTop = UDim.new(0, 4)
StatusPadding.PaddingLeft = UDim.new(0, 8)

-- MACHINE
local MachineFrame = Instance.new("Frame")
MachineFrame.Size = UDim2.new(1, -12, 0, 50)
MachineFrame.Position = UDim2.new(0, 6, 0, 42)
MachineFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 40)
MachineFrame.BorderSizePixel = 0
MachineFrame.Parent = Body
Instance.new("UICorner", MachineFrame).CornerRadius = UDim.new(0, 5)

local MachineStroke = Instance.new("UIStroke", MachineFrame)
MachineStroke.Color = Color3.fromRGB(100, 70, 150)
MachineStroke.Thickness = 1

local MachineStateLabel = Instance.new("TextLabel")
MachineStateLabel.Size = UDim2.new(0.6, 0, 0, 16)
MachineStateLabel.Position = UDim2.new(0, 6, 0, 4)
MachineStateLabel.BackgroundTransparency = 1
MachineStateLabel.Text = "⏸ IDLE"
MachineStateLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
MachineStateLabel.TextSize = 11
MachineStateLabel.Font = Enum.Font.GothamBold
MachineStateLabel.TextXAlignment = Enum.TextXAlignment.Left
MachineStateLabel.Parent = MachineFrame

local MachineTimerLabel = Instance.new("TextLabel")
MachineTimerLabel.Size = UDim2.new(0.4, -6, 0, 16)
MachineTimerLabel.Position = UDim2.new(0.6, 0, 0, 4)
MachineTimerLabel.BackgroundTransparency = 1
MachineTimerLabel.Text = "00:00"
MachineTimerLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
MachineTimerLabel.TextSize = 11
MachineTimerLabel.Font = Enum.Font.Code
MachineTimerLabel.TextXAlignment = Enum.TextXAlignment.Right
MachineTimerLabel.Parent = MachineFrame

local ProgressBg = Instance.new("Frame")
ProgressBg.Size = UDim2.new(1, -12, 0, 6)
ProgressBg.Position = UDim2.new(0, 6, 0, 26)
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

local InfoLabel = Instance.new("TextLabel")
InfoLabel.Size = UDim2.new(1, -12, 0, 14)
InfoLabel.Position = UDim2.new(0, 6, 0, 34)
InfoLabel.BackgroundTransparency = 1
InfoLabel.Text = string.format("Age %d | Min %s | Stop %dx",
    CONFIG.TARGET_AGE, CONFIG.MIN_MUTATION, CONFIG.EMPTY_COUNT_THRESHOLD)
InfoLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
InfoLabel.TextSize = 9
InfoLabel.Font = Enum.Font.Code
InfoLabel.TextXAlignment = Enum.TextXAlignment.Left
InfoLabel.Parent = MachineFrame

-- WEBHOOK BAR
local WebhookFrame = Instance.new("Frame")
WebhookFrame.Size = UDim2.new(1, -12, 0, 34)
WebhookFrame.Position = UDim2.new(0, 6, 0, 142)
WebhookFrame.BackgroundColor3 = Color3.fromRGB(30, 25, 45)
WebhookFrame.BorderSizePixel = 0
WebhookFrame.Parent = Body
Instance.new("UICorner", WebhookFrame).CornerRadius = UDim.new(0, 5)

local WebhookStroke = Instance.new("UIStroke", WebhookFrame)
WebhookStroke.Color = Color3.fromRGB(140, 100, 220)
WebhookStroke.Thickness = 1

local WebhookToggle = Instance.new("TextButton")
WebhookToggle.Size = UDim2.new(0.22, -4, 1, -8)
WebhookToggle.Position = UDim2.new(0, 4, 0, 4)
WebhookToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
WebhookToggle.BorderSizePixel = 0
WebhookToggle.Text = "🔔 OFF"
WebhookToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookToggle.TextSize = 9
WebhookToggle.Font = Enum.Font.GothamBold
WebhookToggle.Parent = WebhookFrame
Instance.new("UICorner", WebhookToggle).CornerRadius = UDim.new(0, 4)

local WebhookBox = Instance.new("TextBox")
WebhookBox.Size = UDim2.new(0.48, -4, 1, -8)
WebhookBox.Position = UDim2.new(0.22, 2, 0, 4)
WebhookBox.BackgroundColor3 = Color3.fromRGB(40, 35, 55)
WebhookBox.BorderSizePixel = 0
WebhookBox.Text = CONFIG.WEBHOOK_URL
WebhookBox.PlaceholderText = "webhook URL..."
WebhookBox.TextColor3 = Color3.fromRGB(220, 210, 255)
WebhookBox.PlaceholderColor3 = Color3.fromRGB(120, 110, 150)
WebhookBox.TextSize = 9
WebhookBox.Font = Enum.Font.Code
WebhookBox.TextXAlignment = Enum.TextXAlignment.Left
WebhookBox.ClearTextOnFocus = false
WebhookBox.TextTruncate = Enum.TextTruncate.AtEnd
WebhookBox.Parent = WebhookFrame
Instance.new("UICorner", WebhookBox).CornerRadius = UDim.new(0, 4)
local WebhookBoxPadding = Instance.new("UIPadding", WebhookBox)
WebhookBoxPadding.PaddingLeft = UDim.new(0, 5)
WebhookBoxPadding.PaddingRight = UDim.new(0, 5)

local WebhookTest = Instance.new("TextButton")
WebhookTest.Size = UDim2.new(0.3, -4, 1, -8)
WebhookTest.Position = UDim2.new(0.7, 2, 0, 4)
WebhookTest.BackgroundColor3 = Color3.fromRGB(120, 80, 200)
WebhookTest.BorderSizePixel = 0
WebhookTest.Text = "TEST"
WebhookTest.TextColor3 = Color3.fromRGB(255, 255, 255)
WebhookTest.TextSize = 9
WebhookTest.Font = Enum.Font.GothamBold
WebhookTest.Parent = WebhookFrame
Instance.new("UICorner", WebhookTest).CornerRadius = UDim.new(0, 4)

-- START
local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Size = UDim2.new(1, -12, 0, 28)
ToggleBtn.Position = UDim2.new(0, 6, 1, -34)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Text = "▶ START"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 12
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Parent = Body
Instance.new("UICorner", ToggleBtn).CornerRadius = UDim.new(0, 6)

-- MINIMIZE HANDLER
local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    Body.Visible = not minimized
    Frame.Size = minimized and UDim2.new(0, 280, 0, 26) or UDim2.new(0, 280, 0, 240)
    MinBtn.Text = minimized and "▢" or "—"
end)

CloseBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = false
    ScreenGui:Destroy()
end)

-- GLOBAL STOP
function _G.__autoMutStop()
    CONFIG.AUTO_FEED = false
    emptyCount = 0
    ToggleBtn.Text = "▶ START"
    ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
    StatusLabel.Text = "STOPPED | Eligible: 0"
    StatusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
end

-- START / STOP
ToggleBtn.MouseButton1Click:Connect(function()
    CONFIG.AUTO_FEED = not CONFIG.AUTO_FEED

    if CONFIG.AUTO_FEED then
        emptyCount = 0
        totalProcessedSession = 0
        sessionMutationCount = {}
        sessionPetCount = 0
        completionSent = false

        ToggleBtn.Text = "⏹ STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        StatusLabel.Text = "RUNNING | Eligible: -"
        StatusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        task.spawn(autoFeedLoop)
    else
        emptyCount = 0
        ToggleBtn.Text = "▶ START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        StatusLabel.Text = "OFF | Eligible: -"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    end
end)

-- WEBHOOK TOGGLE
WebhookToggle.MouseButton1Click:Connect(function()
    CONFIG.WEBHOOK_ENABLED = not CONFIG.WEBHOOK_ENABLED
    if CONFIG.WEBHOOK_ENABLED then
        if CONFIG.WEBHOOK_URL == "" then
            CONFIG.WEBHOOK_ENABLED = false
            return
        end
        WebhookToggle.Text = "🔔 ON"
        WebhookToggle.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
        WebhookStroke.Color = Color3.fromRGB(180, 140, 255)
    else
        WebhookToggle.Text = "🔔 OFF"
        WebhookToggle.BackgroundColor3 = Color3.fromRGB(60, 180, 60)
        WebhookStroke.Color = Color3.fromRGB(140, 100, 220)
    end
end)

-- WEBHOOK URL
WebhookBox.FocusLost:Connect(function()
    local url = WebhookBox.Text
    if url:match("^https://discord%.com/api/webhooks/") then
        CONFIG.WEBHOOK_URL = url
    else
        WebhookBox.Text = CONFIG.WEBHOOK_URL
    end
end)

-- WEBHOOK TEST
WebhookTest.MouseButton1Click:Connect(function()
    local url = CONFIG.WEBHOOK_URL
    if not url or url == "" then return end
    if not url:match("^https://discord%.com/api/webhooks/") then return end

    WebhookTest.Text = "..."
    WebhookTest.BackgroundColor3 = Color3.fromRGB(180, 140, 60)

    local payload = {
        username = CONFIG.WEBHOOK_USERNAME,
        embeds = {{
            title = "🔔 TEST WEBHOOK BERHASIL",
            description = "Webhook sudah terhubung ✅",
            color = 0x8A50C8,
            fields = {
                { name = "Player", value = LocalPlayer.Name, inline = true },
                { name = "Time", value = os.date("%Y-%m-%d %H:%M:%S"), inline = false },
            },
            footer = { text = "Auto Mutation v4.9 • Test" },
        }},
    }

    task.spawn(function()
        local ok = httpPost(url, HttpService:JSONEncode(payload))
        WebhookTest.Text = ok and "✅ OK" or "❌ FAIL"
        WebhookTest.BackgroundColor3 = ok and Color3.fromRGB(60, 180, 60) or Color3.fromRGB(200, 50, 50)
        task.wait(3)
        if WebhookTest and WebhookTest.Parent then
            WebhookTest.Text = "TEST"
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
            ProgressFill.Size = UDim2.new(0, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(80, 80, 100)
            MachineStroke.Color = Color3.fromRGB(80, 80, 100)
        elseif state == "InProgress" then
            MachineStateLabel.Text = "⚙️ MUTATING"
            MachineStateLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
            MachineTimerLabel.Text = formatTime(remaining)
            ProgressFill.Size = UDim2.new(progress, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
            MachineStroke.Color = Color3.fromRGB(255, 180, 60)
        elseif state == "Ready" then
            MachineStateLabel.Text = "✅ READY!"
            MachineStateLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
            MachineTimerLabel.Text = "00:00"
            ProgressFill.Size = UDim2.new(1, 0, 1, 0)
            ProgressFill.BackgroundColor3 = Color3.fromRGB(120, 255, 120)
            MachineStroke.Color = Color3.fromRGB(120, 255, 120)
        else
            MachineStateLabel.Text = "❓ UNKNOWN"
            MachineTimerLabel.Text = "--:--"
        end
        task.wait(0.5)
    end
end)

-- INFO UPDATE
task.spawn(function()
    while ScreenGui.Parent do
        local _, totalEligible, totalSkipped = getInventoryStats()
        StatusLabel.Text = string.format(
            "%s | Eligible: %d | Skip: %d",
            CONFIG.AUTO_FEED and "RUNNING" or "OFF",
            totalEligible, totalSkipped
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

print("[AutoMut] ✅ v4.9 loaded")
