-- ================================================================
--  features/bloxburg.lua  [FIXED — keypress E via fireproximityprompt]
--
--  Changes from previous version:
--   1. _grabBox     — uses fireproximityprompt (E keypress) on conveyor box
--   2. _deliverPizza — uses fireproximityprompt (E keypress) on customer
--   3. Removed all FireServer remote payload logic for grab/deliver
--   4. Removed broken FireServer hook (was causing missing argument errors)
--   5. snapPos args removed from loop call sites
--   5. Framework upvalue index is 4 (confirmed)
-- ================================================================

return function(State, Tabs, Services, Library)

local TweenService = Services.TweenService
local Players      = Services.Players
local LocalPlayer  = Services.LocalPlayer
local _HttpSvc     = Services.HttpService
local _RepStore    = Services.ReplicatedStorage
local _CollSvc     = Services.CollectionService
local VIM = game:GetService("VirtualInputManager")

local _bxFW, _bxNet
local _bxReady = false

local _fnDelivery, _fnSaveHouse, _fnLoadHouse, _fnTeleportPlot, _fnHairdresser

local function _notReady() Library:Notify('Still loading Bloxburg framework…') end

local function dbg(tag, msg)
    print(string.format('[DBG][%s] %s', tag, tostring(msg)))
end

-- ================================================================
--  UI
-- ================================================================
local BX_PizzaGrp       = Tabs.BXBRG:AddLeftGroupbox('Pizza Delivery')
local BX_BuildGrp       = Tabs.BXBRG:AddRightGroupbox('Auto Build')
local BX_MiscGrp        = Tabs.BXBRG:AddLeftGroupbox('Misc')
local BX_HairdresserGrp = Tabs.BXBRG:AddLeftGroupbox('Stylez Hairdresser')
local BX_JobSettingsGrp = Tabs.BXBRG:AddLeftGroupbox('Job Settings')
local BX_AutoMoodGrp    = Tabs.BXBRG:AddLeftGroupbox('Auto Mood')
local BX_StatViewerGrp  = Tabs.BXBRG:AddRightGroupbox('Stat Viewer')
local BX_VehicleGrp     = Tabs.BXBRG:AddRightGroupbox('Vehicle Mods')

BX_PizzaGrp:AddDropdown('BX_MoveMode', {
    Text    = 'Movement Mode',
    Default = 1,
    Values  = { 'Tween (Safe)', 'Teleport', 'Desync TP' },
})
BX_PizzaGrp:AddLabel('Safe=tween+noclip | TP=instant | Desync=server blind')

BX_PizzaGrp:AddSlider('BX_YOffset', {
    Text     = 'Vertical Offset (Y)',
    Default  = 3,
    Min      = -50,
    Max      = 50,
    Rounding = 0,
})

BX_PizzaGrp:AddSlider('BX_TweenSpeed', {
    Text     = 'Tween Speed (studs/s)',
    Default  = 55,
    Min      = 15,
    Max      = 120,
    Rounding = 0,
})

BX_PizzaGrp:AddDivider()

BX_PizzaGrp:AddToggle('BX_PizzaDelivery', {
    Text     = 'Pizza Delivery',
    Default  = false,
    Callback = function(v)
        dbg('TOGGLE', 'BX_PizzaDelivery = ' .. tostring(v))
        if _fnDelivery then
            task.spawn(_fnDelivery, v)
        else
            Library:Notify('Still loading…')
        end
    end,
})

-- ── Hairdresser ───────────────────────────────────────────────
BX_HairdresserGrp:AddLabel('Skys a Nigger')
BX_HairdresserGrp:AddToggle('BX_HairdresserFarm', {
    Text     = 'Hairdresser Autofarm',
    Default  = false,
    Callback = function(v)
        dbg('TOGGLE', 'BX_HairdresserFarm = ' .. tostring(v))
        if _fnHairdresser then
            task.spawn(_fnHairdresser, v)
        else
            Library:Notify('Still loading…')
        end
    end,
})

-- ── Auto Build ────────────────────────────────────────────────
local function _bxRefreshHouseList()
    if not isfolder('Yazu') then makefolder('Yazu') end
    if not isfolder('Yazu/Bloxburg Houses') then makefolder('Yazu/Bloxburg Houses') end
    local ok, files = pcall(listfiles, 'Yazu/Bloxburg Houses')
    if not ok then files = {} end
    local names = {}
    for _, f in next, files do
        local n = f:match('Yazu[/\\]Bloxburg Houses[/\\](.+)') or f:match('([^/\\]+)$')
        if n and n ~= '' then table.insert(names, n) end
    end
    if #names == 0 then names = {''} end
    if Options.BX_LoadHouseFile then Options.BX_LoadHouseFile:SetValues(names) end
    return names
end

BX_BuildGrp:AddLabel('Copy House')
BX_BuildGrp:AddDropdown('BX_CopyHousePlayer', {
    Text    = 'Select Player',
    Default = 1,
    Values  = (function()
        local names = {}
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer then table.insert(names, p.Name) end
        end
        return #names > 0 and names or {''}
    end)(),
})
BX_BuildGrp:AddButton({ Text = 'Copy House', Func = function()
    if not _bxReady then _notReady(); return end
    local name = Options.BX_CopyHousePlayer and Options.BX_CopyHousePlayer.Value or ''
    if name == '' then Library:Notify('No player selected!'); return end
    local target = Players:FindFirstChild(name)
    if not target then Library:Notify('Player not found!'); return end
    if _fnSaveHouse then task.spawn(_fnSaveHouse, target) end
end })

BX_BuildGrp:AddDivider()
BX_BuildGrp:AddLabel('Load Saved House')
BX_BuildGrp:AddDropdown('BX_LoadHouseFile', {
    Text    = 'Select House File',
    Default = 1,
    Values  = _bxRefreshHouseList(),
})
BX_BuildGrp:AddButton({ Text = 'Refresh File List', Func = _bxRefreshHouseList })
BX_BuildGrp:AddButton({ Text = 'Load House', Func = function()
    if not _bxReady then _notReady(); return end
    local file = Options.BX_LoadHouseFile and Options.BX_LoadHouseFile.Value or ''
    if file == '' then Library:Notify('No file selected!'); return end
    local ok, data = pcall(readfile, 'Yazu/Bloxburg Houses/' .. file)
    if not ok then Library:Notify('Error reading file!'); return end
    local houseData = _HttpSvc:JSONDecode(data)
    local bsVal    = houseData.bsValue    or 0
    local totalVal = (houseData.totalValue or 0) - (bsVal * 20)
    Library:Notify(string.format('Loading… Cost: $%s | %s BloxBux', totalVal, bsVal))
    if _fnLoadHouse then task.spawn(_fnLoadHouse, houseData) end
end })

-- ── Misc ──────────────────────────────────────────────────────
BX_MiscGrp:AddLabel('Teleport to Player Plot')
BX_MiscGrp:AddDropdown('BX_TpPlotPlayer', {
    Text    = 'Select Player',
    Default = 1,
    Values  = (function()
        local names = {}
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer then table.insert(names, p.Name) end
        end
        return #names > 0 and names or {''}
    end)(),
})
BX_MiscGrp:AddButton({ Text = 'Teleport to Plot', Func = function()
    if not _bxReady then _notReady(); return end
    local name = Options.BX_TpPlotPlayer and Options.BX_TpPlotPlayer.Value or ''
    if name == '' then Library:Notify('No player selected!'); return end
    if _fnTeleportPlot then _fnTeleportPlot(name) end
end })

local function _bxUpdatePlayerDropdowns()
    local vals = {}
    for _, p in next, Players:GetPlayers() do
        if p ~= LocalPlayer then table.insert(vals, p.Name) end
    end
    if #vals == 0 then vals = {''} end
    if Options.BX_CopyHousePlayer then Options.BX_CopyHousePlayer:SetValues(vals) end
    if Options.BX_TpPlotPlayer     then Options.BX_TpPlotPlayer:SetValues(vals)     end
end
Players.PlayerAdded:Connect(_bxUpdatePlayerDropdowns)
Players.PlayerRemoving:Connect(function() task.defer(_bxUpdatePlayerDropdowns) end)

-- ================================================================
--  HELPERS
-- ================================================================
local function _isDelivering()
    return Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value
end

local function _killVelocity()
    local char = LocalPlayer.Character; if not char then return end
    for _, part in next, char:GetDescendants() do
        if part:IsA('BasePart') then
            part.AssemblyLinearVelocity  = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

local function _setCharNoclip(state)
    local char = LocalPlayer.Character; if not char then return end
    for _, part in next, char:GetDescendants() do
        if part:IsA('BasePart') and not part:FindFirstAncestorWhichIsA('Tool') then
            if not part:FindFirstAncestor('Vehicle_Delivery Moped') then
                part.CanCollide = not state
            end
        end
    end
end

-- ================================================================
--  MOPED MANAGEMENT
-- ================================================================
local function _setMopedAnchored(state)
    local char = LocalPlayer.Character; if not char then return end
    local moped = char:FindFirstChild('Vehicle_Delivery Moped')
    if not moped then return end
    for _, part in next, moped:GetDescendants() do
        if part:IsA('BasePart') then
            part.Anchored = state
            if state then
                part.AssemblyLinearVelocity  = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end
end

local function _hasMoped()
    local char = LocalPlayer.Character
    if not char then return false end
    local moped = char:FindFirstChild('Vehicle_Delivery Moped')
    return moped ~= nil and moped:IsDescendantOf(workspace)
end

-- Spawn moped via fw.net:FireServer({ Type = 'UsePizzaMoped' })
local function _spawnMoped(timeout)
    timeout = timeout or 6
    if _hasMoped() then return true end
    if not _bxNet then
        dbg('MOPED', 'Cannot spawn — _bxNet is nil')
        return false
    end

    dbg('MOPED', 'Firing UsePizzaMoped…')
    local ok, err = pcall(function()
        _bxNet:FireServer({ Type = 'UsePizzaMoped' })
    end)
    if not ok then
        dbg('MOPED', 'UsePizzaMoped error: ' .. tostring(err))
        return false
    end

    local elapsed = 0
    while elapsed < timeout do
        task.wait(0.25); elapsed = elapsed + 0.25
        if _hasMoped() then
            dbg('MOPED', 'Moped attached!')
            Library:Notify('[Pizza] Moped ready!')
            return true
        end
    end
    dbg('MOPED', 'Moped timeout after ' .. timeout .. 's')
    Library:Notify('[Pizza] Moped did not appear within ' .. timeout .. 's')
    return false
end

-- ================================================================
--  MOVEMENT
-- ================================================================
local function _moveToPos(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if not root then return end

    local mode  = Options.BX_MoveMode  and Options.BX_MoveMode.Value  or 'Tween (Safe)'
    local speed = Options.BX_TweenSpeed and Options.BX_TweenSpeed.Value or 55
    local yOff  = Options.BX_YOffset    and Options.BX_YOffset.Value    or 3
    local dest  = Vector3.new(targetPos.X, targetPos.Y + yOff, targetPos.Z)

    dbg('MOVE', mode .. ' → ' .. tostring(dest))
    _setMopedAnchored(true)

    if mode == 'Teleport' then
        char:SetPrimaryPartCFrame(CFrame.new(dest))
        task.wait(0.05); _killVelocity(); task.wait(0.08)

    elseif mode == 'Desync TP' then
        char:SetPrimaryPartCFrame(CFrame.new(dest))
        task.wait(0.05); _killVelocity()

    else -- Tween (Safe)
        local dist = (root.Position - dest).Magnitude
        if dist < 2 then _setMopedAnchored(false); return end
        _setCharNoclip(true)
        local cfVal = Instance.new('CFrameValue')
        cfVal.Value = root.CFrame
        local conn = cfVal:GetPropertyChangedSignal('Value'):Connect(function()
            if LocalPlayer.Character then
                LocalPlayer.Character:SetPrimaryPartCFrame(cfVal.Value)
            end
        end)
        local tw = TweenService:Create(
            cfVal,
            TweenInfo.new(dist / speed, Enum.EasingStyle.Linear),
            { Value = CFrame.new(dest) }
        )
        tw:Play()
        local done = false
        tw.Completed:Connect(function() done = true end)
        repeat task.wait(0.05) until done or not _isDelivering()
        tw:Cancel(); conn:Disconnect(); cfVal:Destroy()
        _setCharNoclip(false)
        _killVelocity()
    end

    _setMopedAnchored(false)
end

-- ================================================================
--  CONVEYOR BOX
-- ================================================================
local function _getConveyorBox()
    local ok, box = pcall(function()
        return workspace.Environment.Locations.City.PizzaPlanet.Interior.Conveyor.MovingBoxes
            :FindFirstChildWhichIsA('UnionOperation')
    end)
    if ok and box then
        dbg('BOX', 'Found: ' .. box:GetFullName())
    else
        dbg('BOX', 'No box on conveyor')
    end
    return ok and box or nil
end

-- ================================================================
--  CUSTOMER — lives at workspace._game.SpawnedCharacters.PizzaPlanetDeliveryCustomer
-- ================================================================
local function _getCustomer()
    local spawns = workspace:FindFirstChild('_game')
    spawns = spawns and spawns:FindFirstChild('SpawnedCharacters')
    if not spawns then
        dbg('CUSTOMER', 'SpawnedCharacters not found!')
        return nil
    end

    local customer = spawns:FindFirstChild('PizzaPlanetDeliveryCustomer')
    if not customer then
        for _, v in next, spawns:GetChildren() do
            if v.Name:find('PizzaPlanetDeliveryCustomer') then
                customer = v; break
            end
        end
    end

    if customer then
        dbg('CUSTOMER', 'Found: ' .. customer:GetFullName())
    else
        dbg('CUSTOMER', 'No PizzaPlanetDeliveryCustomer in SpawnedCharacters')
    end
    return customer
end

-- ================================================================
--  GRAB BOX — E keypress via fireproximityprompt
--  Moves next to the box, then fires the ProximityPrompt (same as pressing E)
-- ================================================================
-- ================================================================
--  GRAB BOX — VIM 'E' Keypress
-- ================================================================
local function _grabBox(box)
    local char = LocalPlayer.Character
    if not char then return false end

    -- Snap close to the box
    local snapPos = Vector3.new(box.Position.X, box.Position.Y + 3, box.Position.Z)
    char:SetPrimaryPartCFrame(CFrame.new(snapPos))
    _killVelocity()
    
    -- Wait a moment for Bloxburg's local script to register you are near the box
    task.wait(0.2)

    -- Simulate pressing and releasing 'E'
    dbg('GRAB', 'Simulating E keypress via VIM')
    VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    task.wait(0.1)
    VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)

    -- Wait for server to put box in inventory
    task.wait(0.5)

    char = LocalPlayer.Character
    local gotBox = char and char:FindFirstChild('Pizza Box') ~= nil
    dbg('GRAB', 'Pizza Box in inventory: ' .. tostring(gotBox))

    return gotBox
end

-- ================================================================
--  DELIVER PIZZA — VIM 'E' Keypress
-- ================================================================
local function _deliverPizza(customer, customerHRP)
    local char = LocalPlayer.Character
    if not char then return false end

    -- Snap close to the customer
    local snapPos = Vector3.new(
        customerHRP.Position.X,
        customerHRP.Position.Y + 3,
        customerHRP.Position.Z
    )
    char:SetPrimaryPartCFrame(CFrame.new(snapPos))
    _killVelocity()
    
    -- Wait a moment for Bloxburg's prompt to pop up
    task.wait(0.2)

    -- Simulate pressing and releasing 'E'
    dbg('DELIVER', 'Simulating E keypress via VIM')
    VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    task.wait(0.1)
    VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)

    return true
end

-- ================================================================
--  MAIN DELIVERY LOOP
-- ================================================================
_fnDelivery = function(toggle)
    if not toggle then return end
    if not _bxNet then
        Library:Notify('[Pizza] Framework not ready yet!')
        if Toggles.BX_PizzaDelivery then Toggles.BX_PizzaDelivery:SetValue(false) end
        return
    end

    Library:Notify('[Pizza] Spawning moped…')
    _spawnMoped(8)
    task.wait(1)

    Library:Notify('[Pizza Delivery] Loop running!')
    dbg('LOOP', '=== START ===')
    local iter = 0

    while _isDelivering() do
        task.wait(0.1)
        iter = iter + 1
        dbg('LOOP', '--- #' .. iter .. ' ---')

        local char = LocalPlayer.Character
        if not char then task.wait(1); continue end

        local mode = Options.BX_MoveMode and Options.BX_MoveMode.Value or 'Tween (Safe)'

        -- 0. Ensure moped
        if not _hasMoped() then
            dbg('LOOP', 'Moped missing — recovering…')
            Library:Notify('[Pizza] Recovering moped…')
            if not _spawnMoped(8) then task.wait(2); continue end
            char = LocalPlayer.Character
            if not char then task.wait(1); continue end
        end

        -- 1. Find box
        local box = _getConveyorBox()
        if not box then task.wait(0.4); continue end

        local root = char:FindFirstChild('HumanoidRootPart')
        if not root then task.wait(0.5); continue end

        -- Desync anchor
        local desyncHome = nil
        if mode == 'Desync TP' then
            desyncHome = root.Position
            root.Anchored = true
            _setMopedAnchored(true)
            task.wait(0.05)
        end

        -- 2. Move to box
        dbg('LOOP', 'Moving to box at ' .. tostring(box.Position))
        _moveToPos(box.Position)

        char = LocalPlayer.Character
        if not char then
            if mode == 'Desync TP' and root then root.Anchored = false; _setMopedAnchored(false) end
            continue
        end
        if not _isDelivering() then
            if mode == 'Desync TP' and root then root.Anchored = false; _setMopedAnchored(false) end
            break
        end

        -- 3. Grab box via E keypress (fireproximityprompt)
        local gotBox = _grabBox(box)

        if not gotBox then
            Library:Notify('[Pizza] Box grab failed — retrying…')
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHome then char:SetPrimaryPartCFrame(CFrame.new(desyncHome)); task.wait(0.05) end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(0.5); continue
        end

        Library:Notify('[Pizza] Box grabbed! Finding customer…')

        -- 4. Find customer
        local customer = nil
        for attempt = 1, 30 do
            task.wait(0.3)
            customer = _getCustomer()
            dbg('LOOP', 'Customer attempt ' .. attempt .. ': ' .. tostring(customer and customer.Name or 'nil'))
            if customer then break end
        end

        if not customer then
            Library:Notify('[Pizza] No customer found — retrying…')
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHome then char:SetPrimaryPartCFrame(CFrame.new(desyncHome)); task.wait(0.05) end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(1); continue
        end

        local customerHRP = customer:FindFirstChild('HumanoidRootPart') or customer.PrimaryPart
        if not customerHRP then
            dbg('LOOP', 'Customer HRP missing')
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHome then char:SetPrimaryPartCFrame(CFrame.new(desyncHome)); task.wait(0.05) end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(0.5); continue
        end

        -- 5. Move to customer
        dbg('LOOP', 'Moving to customer at ' .. tostring(customerHRP.Position))
        Library:Notify('[Pizza] Moving to customer…')
        _moveToPos(customerHRP.Position)

        if not _isDelivering() then
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHome then char:SetPrimaryPartCFrame(CFrame.new(desyncHome)); task.wait(0.05) end
                root.Anchored = false; _setMopedAnchored(false)
            end
            break
        end

        -- 6. Deliver via E keypress (fireproximityprompt)
        local delivered = _deliverPizza(customer, customerHRP)
        if delivered then
            Library:Notify('[Pizza] Delivered!')
            dbg('LOOP', 'Delivery sent.')
        else
            Library:Notify('[Pizza] Delivery failed — continuing…')
        end

        -- 7. Desync cleanup
        if mode == 'Desync TP' then
            task.wait(0.15)
            char = LocalPlayer.Character
            if char and desyncHome then
                char:SetPrimaryPartCFrame(CFrame.new(desyncHome)); task.wait(0.05)
            end
            if root then root.Anchored = false end
            _setMopedAnchored(false)
            _killVelocity()
        end

        -- 8. Wait for box to clear inventory
        local timeout = 0
        repeat
            task.wait(0.2); timeout = timeout + 0.2
            char = LocalPlayer.Character
        until not (char and char:FindFirstChild('Pizza Box')) or timeout >= 10
        dbg('LOOP', 'Box cleared at t=' .. timeout)

        -- 9. Confirm moped
        task.wait(0.3)
        if _isDelivering() and not _hasMoped() then
            Library:Notify('[Pizza] Moped lost — re-spawning…')
            _spawnMoped(6)
        end

        task.wait(0.2)
    end

    -- Cleanup
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if root then root.Anchored = false end
    _setMopedAnchored(false)
    _setCharNoclip(false)
    Library:Notify('[Pizza Delivery] Stopped.')
    dbg('LOOP', '=== STOPPED ===')
end

-- ================================================================
--  JOB SETTINGS UI
-- ================================================================
local _stopAfterEnabled = false
local _stopAfterAmount  = 0

BX_JobSettingsGrp:AddLabel('Automatically stop farming when earnings reach goal')
BX_JobSettingsGrp:AddToggle('BX_StopAfterEnabled', {
    Text     = 'Stop After Amount',
    Default  = false,
    Callback = function(v)
        _stopAfterEnabled = v
        dbg('TOGGLE', 'StopAfterEnabled = ' .. tostring(v))
    end,
})
BX_JobSettingsGrp:AddSlider('BX_StopAfterAmount', {
    Text     = 'Target Earnings ($)',
    Default  = 500,
    Min      = 0,
    Max      = 50000,
    Rounding = 0,
    Callback = function(v)
        _stopAfterAmount = v
    end,
})

-- ================================================================
--  AUTO MOOD UI
-- ================================================================
local _autoMoodEnabled   = false
local _moodThreshold     = 40
local _autoMoodFood      = 'Garden Salad'
local _autoMoodHunger    = true
local _autoMoodFun       = true
local _autoMoodEnergy    = true
local _autoMoodHygiene   = true
local _autoMoodRunning   = false
local _fnAutoMood        = nil

BX_AutoMoodGrp:AddLabel('Monitors mood stats and refills them automatically')
BX_AutoMoodGrp:AddToggle('BX_AutoMood', {
    Text     = 'Auto Mood',
    Default  = false,
    Callback = function(v)
        _autoMoodEnabled = v
        dbg('TOGGLE', 'AutoMood = ' .. tostring(v))
        if v and _fnAutoMood then
            task.spawn(_fnAutoMood)
        end
    end,
})
BX_AutoMoodGrp:AddSlider('BX_MoodThreshold', {
    Text     = 'Refill When Below (%)',
    Default  = 40,
    Min      = 1,
    Max      = 99,
    Rounding = 0,
    Callback = function(v) _moodThreshold = v end,
})
BX_AutoMoodGrp:AddDivider()
BX_AutoMoodGrp:AddLabel('Which moods to monitor:')
BX_AutoMoodGrp:AddToggle('BX_MoodHunger',  { Text = 'Hunger',  Default = true,  Callback = function(v) _autoMoodHunger  = v end })
BX_AutoMoodGrp:AddToggle('BX_MoodFun',     { Text = 'Fun',     Default = true,  Callback = function(v) _autoMoodFun     = v end })
BX_AutoMoodGrp:AddToggle('BX_MoodEnergy',  { Text = 'Energy',  Default = true,  Callback = function(v) _autoMoodEnergy  = v end })
BX_AutoMoodGrp:AddToggle('BX_MoodHygiene', { Text = 'Hygiene', Default = true,  Callback = function(v) _autoMoodHygiene = v end })
BX_AutoMoodGrp:AddDivider()
BX_AutoMoodGrp:AddLabel('Auto Cook (for Hunger):')
BX_AutoMoodGrp:AddDropdown('BX_AutoMoodFood', {
    Text    = 'Food to Cook',
    Default = 1,
    Values  = { 'Garden Salad', 'Grilled Cheese', 'Salad', 'Ramen', 'Steak' },
    Callback = function(v) _autoMoodFood = v end,
})

-- ================================================================
--  STAT VIEWER UI
-- ================================================================
local _statTargetPlayer = ''
local _statLabels       = {}

BX_StatViewerGrp:AddLabel('View stats of yourself or another player')
BX_StatViewerGrp:AddDropdown('BX_StatPlayer', {
    Text    = 'Select Player',
    Default = 1,
    Values  = (function()
        local names = { LocalPlayer.Name }
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer then table.insert(names, p.Name) end
        end
        return names
    end)(),
    Callback = function(v)
        _statTargetPlayer = v
        -- Update stat labels immediately when player changes
        local ok, stats = pcall(function()
            return _RepStore.Stats[v]
        end)
        if ok and stats then
            local function getStat(name)
                local ok2, val = pcall(function()
                    return stats:FindFirstChild(name, true).Value
                end)
                return ok2 and tostring(math.floor(tonumber(val) or 0)) or 'N/A'
            end
            if _statLabels.money   then _statLabels.money:SetText('Money: $'      .. getStat('Money'))   end
            if _statLabels.bux     then _statLabels.bux:SetText('Blockbux: '      .. getStat('Blockbux'))end
            if _statLabels.level   then _statLabels.level:SetText('Job Level: '   .. getStat('Level'))   end
            if _statLabels.visits  then _statLabels.visits:SetText('Plot Visits: '.. getStat('Visits'))  end
        end
    end,
})
_statLabels.money  = BX_StatViewerGrp:AddLabel('Money: —')
_statLabels.bux    = BX_StatViewerGrp:AddLabel('Blockbux: —')
_statLabels.level  = BX_StatViewerGrp:AddLabel('Job Level: —')
_statLabels.visits = BX_StatViewerGrp:AddLabel('Plot Visits: —')
BX_StatViewerGrp:AddButton('Refresh Stats', function()
    local target = _statTargetPlayer ~= '' and _statTargetPlayer or LocalPlayer.Name
    local ok, stats = pcall(function() return _RepStore.Stats[target] end)
    if ok and stats then
        local function getStat(name)
            local ok2, val = pcall(function()
                return stats:FindFirstChild(name, true).Value
            end)
            return ok2 and tostring(math.floor(tonumber(val) or 0)) or 'N/A'
        end
        _statLabels.money:SetText('Money: $'       .. getStat('Money'))
        _statLabels.bux:SetText('Blockbux: '       .. getStat('Blockbux'))
        _statLabels.level:SetText('Job Level: '    .. getStat('Level'))
        _statLabels.visits:SetText('Plot Visits: ' .. getStat('Visits'))
        Library:Notify('Stats refreshed for ' .. target)
    else
        Library:Notify('Could not read stats for ' .. target)
    end
end)

-- ================================================================
--  VEHICLE MODS UI
-- ================================================================
BX_VehicleGrp:AddLabel('Re-enter your vehicle after changing values')
BX_VehicleGrp:AddSlider('BX_VehForward', {
    Text     = 'Forward Speed',
    Default  = 50,
    Min      = 0,
    Max      = 200,
    Rounding = 0,
    Callback = function(v)
        if not _bxReady then return end
        pcall(function()
            local VehicleData = require(_RepStore.Modules.VehicleHandler.VehicleData)
            for _, vd in next, VehicleData do vd.ForwardSpeed = v end
        end)
    end,
})
BX_VehicleGrp:AddSlider('BX_VehReverse', {
    Text     = 'Reverse Speed',
    Default  = 25,
    Min      = 0,
    Max      = 100,
    Rounding = 0,
    Callback = function(v)
        if not _bxReady then return end
        pcall(function()
            local VehicleData = require(_RepStore.Modules.VehicleHandler.VehicleData)
            for _, vd in next, VehicleData do vd.ReverseSpeed = v end
        end)
    end,
})
BX_VehicleGrp:AddSlider('BX_VehTurn', {
    Text     = 'Turn Speed',
    Default  = 30,
    Min      = 0,
    Max      = 100,
    Rounding = 0,
    Callback = function(v)
        if not _bxReady then return end
        pcall(function()
            local VehicleData = require(_RepStore.Modules.VehicleHandler.VehicleData)
            for _, vd in next, VehicleData do vd.TurnSpeed = v end
        end)
    end,
})
BX_VehicleGrp:AddSlider('BX_VehSpring', {
    Text     = 'Spring Length',
    Default  = 10,
    Min      = 0,
    Max      = 50,
    Rounding = 0,
    Callback = function(v)
        if not _bxReady then return end
        pcall(function()
            local VehicleData = require(_RepStore.Modules.VehicleHandler.VehicleData)
            for _, vd in next, VehicleData do vd.SpringLength = v end
        end)
    end,
})

-- ================================================================
--  HAIRDRESSER AUTOFARM
-- ================================================================
local function _isHairdressing()
    return Toggles.BX_HairdresserFarm and Toggles.BX_HairdresserFarm.Value
end

_fnHairdresser = function(toggle)
    if not toggle then return end

    local doActionFuncs = {}
    for _, v in next, getgc() do
        if type(v) == 'function'
            and getinfo(v).name == 'doAction'
            and getfenv(v).script
            and getfenv(v).script.Name == 'StylezHairdresser' then
            doActionFuncs[#doActionFuncs + 1] = v
        end
    end

    if #doActionFuncs == 0 then
        Library:Notify('[Hair] Not found! Clock in first.')
        if Toggles.BX_HairdresserFarm then Toggles.BX_HairdresserFarm:SetValue(false) end
        return
    end

    local styles = getupvalue(doActionFuncs[1], 6)
    local colors = getupvalue(doActionFuncs[1], 8)

    local function getStyle(name)
        for i, v in next, styles do if v.Name == name then return i end end
        return 1
    end
    local function getColor(name)
        for i, v in next, colors do if v.Name == name then return i end end
        return 1
    end

    local function doOrder()
        for _, v in next, doActionFuncs do
            local workstation = getupvalue(v, 2)
            local npc = workstation.Occupied.Value
            if workstation.InUse.Value == LocalPlayer and npc then
                local head = npc:WaitForChild('Head')
                head:WaitForChild('ChatBubble')
                task.wait(0.1)
                if npc and npc:FindFirstChild('Order') and npc.Order.Style.Value ~= nil then
                    setupvalue(v, 7, { getStyle(npc.Order.Style.Value), getColor(npc.Order.Color.Value) })
                    task.wait(0.1)
                    v('Done')
                end
            end
        end
    end

    Library:Notify('[Hair] Autofarm running!')
    repeat
        doOrder()
        task.wait(0.1)
    until not _isHairdressing()
    Library:Notify('[Hair] Autofarm stopped.')
end

-- ================================================================
--  FRAMEWORK BOOTSTRAP  (upvalue 4 confirmed)
-- ================================================================
task.spawn(function()
    dbg('BOOT', 'Requiring Framework…')
    local ok, m = pcall(function()
        return require(_RepStore:WaitForChild('Framework', 10))
    end)
    if not ok or not m then
        Library:Notify('[BXBRG] Framework not found!')
        dbg('BOOT', 'FAILED: ' .. tostring(m))
        return
    end

    local ok2, fw = pcall(getupvalue, m, 4)
    if not ok2 or type(fw) ~= 'table' then
        Library:Notify('[BXBRG] Could not get fw from upvalue 4!')
        dbg('BOOT', 'getupvalue(m,4) failed: ' .. tostring(fw))
        return
    end
    _bxFW = fw
    dbg('BOOT', 'fw obtained from upvalue 4.')

    local waited = 0
    repeat
        task.wait(0.1); waited = waited + 0.1
        _bxNet = _bxFW.net
    until _bxNet or waited > 30

    if not _bxNet then
        Library:Notify('[BXBRG] fw.net never appeared!')
        dbg('BOOT', 'fw.net timeout')
        return
    end
    dbg('BOOT', 'fw.net ready.')

    if not isfolder('Yazu/Bloxburg Houses') then makefolder('Yazu/Bloxburg Houses') end

    -- NOTE: FireServer hook removed — was causing missing argument errors
    -- in unrelated game systems (VehicleService, Analytics, CharacterHandler).
    -- Grab and Deliver now use fireproximityprompt (E keypress) instead.

    -- ── Save House ────────────────────────────────────────────
    _fnSaveHouse = function(player)
        local plot   = workspace.Plots[string.format('Plot_%s', player.Name)]
        local ground = plot.Ground
        local save   = {
            Walls={}, Paths={}, Floors={}, Roofs={}, Pools={},
            Fences={}, Ground={ Counters={}, Objects={} }, Basements={}
        }
        local function getRot(obj)
            return tostring(plot.PrimaryPart.CFrame:ToObjectSpace(obj))
        end
        local function getFloor(pos)
            local cf, cd = nil, math.huge
            for _, v in next, plot.House.Floor:GetChildren() do
                local d = (v.Part.Position - pos).Magnitude
                if d <= cd then cf, cd = v, d end
            end
            return cf
        end
        local function getPolePos(pole)
            pole = pole.Value
            return pole.Parent:IsA('BasePart') and pole.Parent.Position or pole.Parent.Value
        end
        local objs, cnts = {}, {}
        for _, obj in next, plot.House.Objects:GetChildren() do
            local floor = getFloor(obj.Position) or plot
            local od = {
                Name           = obj.Name,
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(obj),
                Rot            = getRot(obj.CFrame),
                Position       = tostring(ground.CFrame:PointToObjectSpace(obj.Position)),
            }
            if not objs[floor] then objs[floor] = {} end
            if obj:FindFirstChild('ItemHolder') then
                for _, item in next, obj.ItemHolder:GetChildren() do
                    if item:FindFirstChild('RailingSegment') then
                        od.Fences = od.Fences or {}
                        local _, from = _bxFW.Shared.FenceService:GetEdgePositions(item)
                        table.insert(od.Fences, {
                            Name           = item.Name,
                            From           = tostring(ground.CFrame:PointToObjectSpace(from)),
                            AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                            Segment        = item.RailingSegment.Value.Name,
                        })
                    else
                        od.Items = od.Items or {}
                        table.insert(od.Items, {
                            Name           = item.Name,
                            AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                            Rot            = getRot(item.CFrame),
                            Position       = tostring(ground.CFrame:PointToObjectSpace(item.Position)),
                        })
                    end
                end
            end
            table.insert(objs[floor], od)
        end
        for _, cnt in next, plot.House.Counters:GetChildren() do
            local floor = getFloor(cnt.Position) or plot
            local cd = {
                Name           = cnt.Name,
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(cnt),
                Rot            = getRot(cnt.CFrame),
                Position       = tostring(ground.CFrame:PointToObjectSpace(cnt.Position)),
            }
            if not cnts[floor] then cnts[floor] = {} end
            if cnt:FindFirstChild('ItemHolder') then
                for _, item in next, cnt.ItemHolder:GetChildren() do
                    cd.Items = cd.Items or {}
                    table.insert(cd.Items, {
                        Name           = item.Name,
                        AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                        Rot            = getRot(item.CFrame),
                        Position       = tostring(ground.CFrame:PointToObjectSpace(item.Position)),
                    })
                end
            end
            table.insert(cnts[floor], cd)
        end
        for _, wall in next, plot.House.Walls:GetChildren() do
            if wall.Name == 'Poles' then continue end
            local from = ground.CFrame:PointToObjectSpace(getPolePos(wall.BPole))
            local to   = ground.CFrame:PointToObjectSpace(getPolePos(wall.FPole))
            local wd   = {
                From           = tostring(from),
                To             = tostring(to),
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(wall),
                Items          = {},
            }
            if wall:FindFirstChild('ItemHolder') then
                for _, item in next, wall.ItemHolder:GetChildren() do
                    local id = {
                        Name           = item.Name,
                        Position       = tostring(ground.CFrame:PointToObjectSpace(item.Position)),
                        Side           = item:FindFirstChild('SideValue') and item.SideValue.Value == -1 or nil,
                        AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                    }
                    local cfg = _bxFW.Items:GetItem(item.Name)
                    if cfg.Type ~= 'Windows' and cfg.Type ~= 'Doors' then
                        id.Rot = getRot(item.CFrame)
                    end
                    if item:FindFirstChild('ItemHolder') then
                        id.Items = {}
                        for _, i2 in next, item.ItemHolder:GetChildren() do
                            table.insert(id.Items, {
                                Name           = i2.Name,
                                Rot            = getRot(i2.CFrame),
                                Position       = tostring(ground.CFrame:PointToObjectSpace(i2.Position)),
                                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(i2),
                            })
                        end
                    end
                    table.insert(wd.Items, id)
                end
            end
            table.insert(save.Walls, wd)
        end
        for _, floor in next, plot.House.Floor:GetChildren() do
            local fd = {
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(floor),
                Points         = {},
                Objects        = objs[floor] or {},
                Counters       = cnts[floor] or {},
            }
            for _, v in next, floor.PointData:GetChildren() do
                table.insert(fd.Points, tostring(v.Value))
            end
            table.insert(save.Floors, fd)
        end
        for _, roof in next, plot.House.Roof:GetChildren() do
            local rd = {
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(roof),
                Name           = roof.Name,
                Points         = {},
                Items          = {},
            }
            for _, v in next, roof.PointData:GetChildren() do
                table.insert(rd.Points, tostring(v.Value))
            end
            if roof:FindFirstChild('ItemHolder') then
                for _, item in next, roof.ItemHolder:GetChildren() do
                    table.insert(rd.Items, {
                        Name           = item.Name,
                        Position       = tostring(ground.CFrame:PointToObjectSpace(item.Position)),
                        Rot            = getRot(item.CFrame),
                        AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                    })
                end
            end
            table.insert(save.Roofs, rd)
        end
        for _, path in next, plot.House.Paths:GetChildren() do
            if path.Name == 'Poles' then continue end
            local f2 = ground.CFrame:PointToObjectSpace(getPolePos(path.BPole))
            local t2 = ground.CFrame:PointToObjectSpace(getPolePos(path.FPole))
            table.insert(save.Paths, {
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(path),
                From           = tostring(f2),
                To             = tostring(t2),
            })
        end
        for _, pool in next, plot.House.Pools:GetChildren() do
            table.insert(save.Pools, {
                Position = tostring(ground.CFrame:ToObjectSpace(pool.HitBox.CFrame)),
                Size     = tostring(Vector2.new(pool.HitBox.Size.X, pool.HitBox.Size.Z)),
                Type     = pool.Name,
            })
        end
        for _, bsmt in next, plot.House.Basements:GetChildren() do
            table.insert(save.Basements, {
                Position = tostring(ground.CFrame:ToObjectSpace(bsmt.HitBox.CFrame)),
                Size     = tostring(Vector2.new(bsmt.HitBox.Size.X, bsmt.HitBox.Size.Z)),
                Type     = bsmt.Name,
            })
        end
        for _, fence in next, plot.House.Fences:GetChildren() do
            if fence.Name == 'Poles' then continue end
            local ft, ff = _bxFW.Shared.FenceService:GetEdgePositions(fence)
            local fd2 = {
                To             = tostring(ground.CFrame:PointToObjectSpace(ft)),
                From           = tostring(ground.CFrame:PointToObjectSpace(ff)),
                AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(fence),
                Name           = fence.Name,
                Items          = {},
            }
            if fence:FindFirstChild('ItemHolder') then
                for _, item in next, fence.ItemHolder:GetChildren() do
                    table.insert(fd2.Items, {
                        AppearanceData = _bxFW.Shared.ObjectService:GetAppearanceData(item),
                        Name           = item.Name,
                        Rot            = getRot(item.CFrame),
                        Position       = tostring(ground.CFrame:PointToObjectSpace(item.Position)),
                    })
                end
            end
            table.insert(save.Fences, fd2)
        end
        if objs[plot] then save.Ground.Objects  = objs[plot] end
        if cnts[plot] then save.Ground.Counters = cnts[plot] end
        local houses = _RepStore.Stats[player.Name].Houses
        local house
        for _, v in next, houses:GetChildren() do
            if v.Value == houses.Value then house = v end
        end
        save.totalValue = house and house.TotalValue.Value or 'Unknown'
        save.bsValue    = house and house.BSValue.Value    or 'Unknown'
        writefile(
            string.format('Yazu/Bloxburg Houses/%s.json', player.Name),
            _HttpSvc:JSONEncode(save)
        )
        Library:Notify(string.format('House of %s saved!', player.Name))
        _bxRefreshHouseList()
    end

    -- ── Load House ────────────────────────────────────────────
    _fnLoadHouse = function(houseData)
        local myPlot   = workspace.Plots['Plot_' .. LocalPlayer.Name]
        local myGround = myPlot.Ground
        local placements = 0
        local oldFW = _bxFW
        local streamRefTypes = { 'PlaceObject','PlaceWall','PlaceFloor','PlacePath','PlaceRoof' }
        local fw = {
            net = setmetatable({
                InvokeServer = function(self, data, ...)
                    placements = placements + 1
                    if placements >= 4 then placements = 0; task.wait(3) end
                    local dt  = data.Type
                    local ret = { oldFW.net:InvokeServer(data) }
                    if table.find(streamRefTypes, dt) then
                        ret[1] = typeof(ret[1]) == 'Instance' and ret[1].Value
                    end
                    return unpack(ret)
                end
            }, { __index = oldFW.net })
        }
        local pos = fw.net:InvokeServer({ Type='ToPlot', Player=LocalPlayer })
        LocalPlayer.Character:SetPrimaryPartCFrame(pos)
        fw.net:InvokeServer({ Type='EnterBuild', Plot=myPlot })
        local function cvt3(s)
            return myGround.CFrame:PointToWorldSpace(Vector3.new(unpack(s:split(','))))
        end
        local function cvtPts(pts)
            local r = {}
            for _, v in next, pts do table.insert(r, cvt3(v)) end
            return r
        end
        local function cvtRot(cf)
            if not cf then return end
            local c = myGround.CFrame:ToWorldSpace(CFrame.new(unpack(cf:split(','))))
            local r = -math.atan2(c.lookVector.z, c.lookVector.x) - math.pi * 0.5
            if r < 0 then r = 2 * math.pi + r end
            return r
        end
        for _, wd in next, houseData.Walls do
            local wall = fw.net:InvokeServer({ Type='PlaceWall', From=cvt3(wd.From), To=cvt3(wd.To) })
            for _, id in next, wd.Items do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=id.Name, TargetModel=wall, Rot=cvtRot(id.Rot), Pos=cvt3(id.Position) })
                if id.Items then for _, id2 in next, id.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=id.AppearanceData })
            end
            fw.net:InvokeServer({ Type='ColorObject', Object=wall, UseMaterials=true, Data={wd.AppearanceData[1],{},{},{}}, Side='R' })
            fw.net:InvokeServer({ Type='ColorObject', Object=wall, UseMaterials=true, Data={wd.AppearanceData[2],{},{},{}}, Side='L' })
        end
        for _, fd in next, houseData.Floors do
            local floor = fw.net:InvokeServer({ Type='PlaceFloor', Points=cvtPts(fd.Points) })
            for _, od in next, fd.Objects or {} do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=od.Name, TargetModel=floor, Rot=cvtRot(od.Rot), Pos=cvt3(od.Position) })
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=od.AppearanceData })
                if od.Fences and item then for _, fcd in next, od.Fences do local fe=fw.net:InvokeServer({Type='PlaceObject',Name=fcd.Name,Pos=cvt3(fcd.From),RailingSegment=item.ObjectModel.Railings[fcd.Segment]}); fw.net:InvokeServer({Type='ColorObject',Object=fe,UseMaterials=true,Data=fcd.AppearanceData}) end end
                if od.Items then for _, id2 in next, od.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
            end
            for _, cd in next, fd.Counters or {} do
                local item = fw.net:InvokeServer({ Type='PlaceObject', Name=cd.Name, TargetModel=floor, Rot=cvtRot(cd.Rot), Pos=cvt3(cd.Position) })
                if cd.Items then for _, id2 in next, cd.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
                fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=cd.AppearanceData })
            end
            fw.net:InvokeServer({ Type='ColorObject', Object=floor, UseMaterials=true, Data=fd.AppearanceData })
        end
        for _, pd in next, houseData.Paths do
            local path = fw.net:InvokeServer({ Type='PlacePath', To=cvt3(pd.To), From=cvt3(pd.From) })
            fw.net:InvokeServer({ Type='ColorObject', Object=path, UseMaterials=true, Data=pd.AppearanceData })
        end
        for _, rd in next, houseData.Roofs do
            local roof = fw.net:InvokeServer({ Type='PlaceRoof', Points=cvtPts(rd.Points), Start=cvt3(rd.Points[1]), Settings={IsPreview=true,Type=rd.Name,RotateNum=0} })
            for _, id in next, rd.Items or {} do local item=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=roof,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=item,UseMaterials=true,Data=id.AppearanceData}) end
            fw.net:InvokeServer({ Type='ColorObject', Object=roof, UseMaterials=true, Data=rd.AppearanceData })
        end
        for _, poolD in next, houseData.Pools do
            fw.net:InvokeServer({ Type='PlacePool', Size=Vector2.new(unpack(poolD.Size:split(','))), Center=CFrame.new(unpack(poolD.Position:split(','))), ItemType=poolD.Type })
        end
        for _, bsD in next, houseData.Basements do
            fw.net:InvokeServer({ Type='PlaceBasement', ItemType='Basements', Size=Vector2.new(unpack(bsD.Size:split(','))), Center=CFrame.new(unpack(bsD.Position:split(','))) - Vector3.new(0,-12.49,0) })
        end
        for _, fcd in next, houseData.Fences do
            local fence = fw.net:InvokeServer({ Type='PlaceObject', Name=fcd.Name, StartPos=cvt3(fcd.From), Pos=cvt3(fcd.To), ItemType=fcd.Name })
            for _, id in next, fcd.Items do local item=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=fence,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=item,UseMaterials=true,Data=id.AppearanceData}) end
            fw.net:InvokeServer({ Type='ColorObject', Object=fence, UseMaterials=true, Data=fcd.AppearanceData })
        end
        for _, gi in next, houseData.Ground.Objects do
            local item = fw.net:InvokeServer({ Type='PlaceObject', Name=gi.Name, TargetModel=myPlot.GroundParts.Ground, Rot=cvtRot(gi.Rot), Pos=cvt3(gi.Position) })
            if gi.Fences and item then for _, fcd in next, gi.Fences do local fe=fw.net:InvokeServer({Type='PlaceObject',Name=fcd.Name,Pos=cvt3(fcd.From),RailingSegment=item.ObjectModel.Railings[fcd.Segment]}); fw.net:InvokeServer({Type='ColorObject',Object=fe,UseMaterials=true,Data=fcd.AppearanceData}) end end
            if gi.Items then for _, id2 in next, gi.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id2.Name,TargetModel=item,Rot=cvtRot(id2.Rot),Pos=cvt3(id2.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id2.AppearanceData}) end end
            fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=gi.AppearanceData })
        end
        for _, ci in next, houseData.Ground.Counters do
            local item = fw.net:InvokeServer({ Type='PlaceObject', Name=ci.Name, Pos=cvt3(ci.Position), Rot=cvtRot(ci.Rot), TargetModel=myPlot.GroundParts.Ground })
            if ci.Items then for _, id in next, ci.Items do local i2=fw.net:InvokeServer({Type='PlaceObject',Name=id.Name,TargetModel=item,Rot=cvtRot(id.Rot),Pos=cvt3(id.Position)}); fw.net:InvokeServer({Type='ColorObject',Object=i2,UseMaterials=true,Data=id.AppearanceData}) end end
            fw.net:InvokeServer({ Type='ColorObject', Object=item, UseMaterials=true, Data=ci.AppearanceData })
        end
        fw.net:FireServer({ Type='ExitBuild' })
        Library:Notify('House loaded!')
    end

    -- ── Teleport to plot ──────────────────────────────────────
    _fnTeleportPlot = function(name)
        local target = Players:FindFirstChild(name)
        if not target then Library:Notify('Player not found!'); return end
        local pos = _bxFW.net:InvokeServer({ Type = 'ToPlot', Player = target })
        LocalPlayer.Character:SetPrimaryPartCFrame(pos)
        Library:Notify('Teleported to ' .. name .. "'s plot")
    end

    _bxReady = true
    Library:Notify('[BXBRG] Framework loaded!')

    -- ── Stop After Amount monitor ─────────────────────────────
    task.spawn(function()
        while task.wait(2) do
            if not _stopAfterEnabled or not _bxFW then continue end
            local ok, earnings = pcall(function()
                return _RepStore.Stats[LocalPlayer.Name].Job.ShiftEarnings.Value
            end)
            if ok and earnings and math.floor(earnings) >= _stopAfterAmount then
                if Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value then
                    Toggles.BX_PizzaDelivery:SetValue(false)
                end
                if Toggles.BX_HairdresserFarm and Toggles.BX_HairdresserFarm.Value then
                    Toggles.BX_HairdresserFarm:SetValue(false)
                end
                Library:Notify('[Job] Earnings goal reached! ($' .. math.floor(earnings) .. ') — Stopped farming.')
                dbg('STOP', 'Stop after amount triggered at ' .. tostring(earnings))
            end
        end
    end)

    -- ── Auto Mood logic ───────────────────────────────────────
    _fnAutoMood = function()
        if _autoMoodRunning then return end
        _autoMoodRunning = true

        local function getMood(moodType)
            local ok, val = pcall(function()
                return _RepStore.Stats[LocalPlayer.Name].MoodData[moodType].Value
            end)
            return ok and math.ceil(val) or 100
        end

        local function getAppliance(types)
            local plot = workspace.Plots['Plot_' .. LocalPlayer.Name]
            if not plot then return nil end
            local closest, closestDist = nil, math.huge
            for _, buildType in next, plot.House:GetChildren() do
                for _, obj in next, buildType:GetDescendants() do
                    for _, t in next, types do
                        if obj.Name:find(t) and obj:IsA('Part') then
                            local dist = (LocalPlayer.Character.HumanoidRootPart.Position - obj.Position).Magnitude
                            if dist < closestDist then
                                closestDist, closest = dist, obj
                            end
                        end
                    end
                end
            end
            return closest
        end

        local function doMood(moodType)
            if moodType == 'Hunger' then
                -- Try to find already cooked food first
                local plot = workspace.Plots['Plot_' .. LocalPlayer.Name]
                if plot then
                    for _, counter in next, plot.House.Counters:GetChildren() do
                        if counter:FindFirstChild('ItemHolder') then
                            for _, item in next, counter.ItemHolder:GetChildren() do
                                if item:FindFirstChild('ObjectData') and item.ObjectData:FindFirstChild('FoodQuantity') then
                                    if item.ObjectData.FoodQuantity.Value > -1 then
                                        _bxNet:FireServer({ Type = 'Interact', Target = item, Path = '2' })
                                        Library:Notify('[AutoMood] Eating from counter...')
                                        task.wait(3)
                                        return
                                    end
                                end
                            end
                        end
                    end
                end
                Library:Notify('[AutoMood] Hunger low — attempting to cook ' .. _autoMoodFood)
            elseif moodType == 'Hygiene' then
                local app = getAppliance({'Bath', 'Shower', 'The Barrel', 'Jacuzzi'})
                if app then
                    Library:Notify('[AutoMood] Hygiene low — using bath/shower')
                    _bxNet:FireServer({ Type = 'Interact', Target = app, Path = '1' })
                    task.wait(10)
                    LocalPlayer.Character.Humanoid.Jump = true
                else
                    Library:Notify('[AutoMood] No bath/shower found on plot!')
                end
            elseif moodType == 'Fun' then
                local app = getAppliance({'TV', 'Television', 'Pixelview'})
                if app then
                    Library:Notify('[AutoMood] Fun low — watching TV')
                    _bxNet:FireServer({ Type = 'Interact', Target = app, Path = '1' })
                    task.wait(1)
                    _bxNet:FireServer({ Type = 'Interact', Target = app, Path = '3' })
                    task.wait(15)
                    _bxNet:FireServer({ Type = 'Interact', Target = app, Path = '1' })
                else
                    Library:Notify('[AutoMood] No TV found on plot!')
                end
            elseif moodType == 'Energy' then
                local app = getAppliance({'Bed'})
                if app then
                    Library:Notify('[AutoMood] Energy low — sleeping')
                    _bxNet:FireServer({ Type = 'Interact', Target = app, Path = '1' })
                    task.wait(20)
                    LocalPlayer.Character.Humanoid.Jump = true
                else
                    Library:Notify('[AutoMood] No bed found on plot!')
                end
            end
        end

        while _autoMoodEnabled do
            task.wait(5)
            if not _bxNet then continue end
            local moods = {
                { name = 'Hunger',  enabled = _autoMoodHunger  },
                { name = 'Fun',     enabled = _autoMoodFun     },
                { name = 'Energy',  enabled = _autoMoodEnergy  },
                { name = 'Hygiene', enabled = _autoMoodHygiene },
            }
            for _, mood in next, moods do
                if mood.enabled and getMood(mood.name) < _moodThreshold then
                    dbg('MOOD', mood.name .. ' is low (' .. getMood(mood.name) .. ')')
                    doMood(mood.name)
                end
            end
        end

        _autoMoodRunning = false
    end
    dbg('BOOT', 'Bootstrap complete.')
end)

end -- return function
