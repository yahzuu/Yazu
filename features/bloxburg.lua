-- ================================================================
--  features/bloxburg.lua
--  Pizza Delivery only — all other jobs removed.
--
--  Fixes applied:
--   1. Speed/ShiftLoop kick   → UsePizzaMoped at start so ShiftLoop
--                               uses moped proximity (follows you)
--                               instead of AreaBlock distance check.
--   2. Proper box pickup       → InvokeServer({ Type='TakePizzaBox' })
--                               instead of unreliable keypress.
--   3. Proper delivery         → FireServer({ Type='DeliverPizza' })
--                               instead of unreliable keypress.
--   4. Customer detection      → checks both CollectionService tags
--                               AND workspace._game.SpawnedCharacters
--                               (found in decompiled game source).
--   5. EndShift suppression    → hooked via framework (backup layer).
--   6. Movement modes          → Tween (Safe), Teleport, Underground.
-- ================================================================

return function(State, Tabs, Services, Library)

local TweenService = Services.TweenService
local Players      = Services.Players
local LocalPlayer  = Services.LocalPlayer
local _HttpSvc     = Services.HttpService
local _RepStore    = Services.ReplicatedStorage
local _CollSvc     = Services.CollectionService
local _PathSvc     = Services.PathfindingService

-- Framework refs — populated once the async bootstrap finishes
local _bxFW, _bxNet
local _bxReady = false

local _fnDelivery, _fnSaveHouse, _fnLoadHouse, _fnTeleportPlot

local function _notReady() Library:Notify('Still loading Bloxburg framework…') end

-- ================================================================
--  UI
-- ================================================================
local BX_PizzaGrp = Tabs.BXBRG:AddLeftGroupbox('Pizza Delivery')
local BX_BuildGrp = Tabs.BXBRG:AddRightGroupbox('Auto Build')
local BX_MiscGrp  = Tabs.BXBRG:AddLeftGroupbox('Misc')

-- Movement settings
BX_PizzaGrp:AddDropdown('BX_MoveMode', {
    Text    = 'Movement Mode',
    Default = 1,
    Values  = { 'Tween (Safe)', 'Teleport', 'Desync TP', 'Underground' },
})
-- Tooltip hint shown as a label
BX_PizzaGrp:AddLabel('Safe=tween | TP=instant | Desync=server blind | UG=underground')

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
        if _fnDelivery then
            task.spawn(_fnDelivery, v)
        else
            Library:Notify('Still loading…')
        end
    end,
})

-- ── Auto Build (house save / load) ────────────────────────────
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

-- ── Misc (teleport to plot) ────────────────────────────────────
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

-- Keep player dropdowns fresh
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

-- Zero out all physics velocities on the character to stop flinging
local function _killVelocity()
    local char = LocalPlayer.Character; if not char then return end
    for _, part in next, char:GetDescendants() do
        if part:IsA('BasePart') then
            part.AssemblyLinearVelocity  = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

-- ================================================================
--  MOVEMENT MODES
--
--  Tween (Safe)   — smooth tween at configurable studs/s
--  Teleport       — instant TP, kills velocity after to stop fling
--  Desync TP      — anchors root client-side before teleporting so
--                   the server never sees you move (server position
--                   stays frozen at last replicated pos). Best for
--                   avoiding detection. Unanchors after interact.
--  Underground    — dips to Y=-500 then surfaces at target
-- ================================================================
local function _moveToPos(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if not root then return end

    local mode  = Options.BX_MoveMode  and Options.BX_MoveMode.Value  or 'Tween (Safe)'
    local speed = Options.BX_TweenSpeed and Options.BX_TweenSpeed.Value or 55

    if mode == 'Teleport' then
        char:SetPrimaryPartCFrame(CFrame.new(targetPos))
        task.wait(0.05)
        _killVelocity()
        task.wait(0.1)

    elseif mode == 'Desync TP' then
        -- Anchor client-side only. In Roblox, Anchored=true set by
        -- a client exploit does NOT replicate to the server — so the
        -- server keeps your character frozen at its last known pos.
        -- Your client then teleports freely without server knowing.
        root.Anchored = true
        task.wait(0.05)
        char:SetPrimaryPartCFrame(CFrame.new(targetPos))
        task.wait(0.05)
        _killVelocity()
        -- NOTE: root stays Anchored until after interaction (see delivery loop)
        -- so the server never sees movement during the delivery.
        -- Caller must unanchor after interact.

    elseif mode == 'Underground' then
        char:SetPrimaryPartCFrame(CFrame.new(Vector3.new(targetPos.X, -500, targetPos.Z)))
        task.wait(0.05)
        char:SetPrimaryPartCFrame(CFrame.new(targetPos))
        task.wait(0.05)
        _killVelocity()
        task.wait(0.1)

    else
        -- Tween (Safe): smooth movement at moped-like speed
        local dist = (root.Position - targetPos).Magnitude
        if dist < 3 then return end

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
            { Value = CFrame.new(targetPos) }
        )
        tw:Play()
        local done = false
        tw.Completed:Connect(function() done = true end)
        repeat task.wait(0.05) until done or not _isDelivering()
        tw:Cancel(); conn:Disconnect(); cfVal:Destroy()
    end
end

-- Unanchor helper used after desync interact
local function _desyncEnd()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if root then
        root.Anchored = false
        _killVelocity()
    end
end

-- ================================================================
--  PIZZA DELIVERY CORE
-- ================================================================
local BOX_TAG = 'PizzaPlanetDeliveryCustomer'

local function _getDeliveryRemote()
    -- Path from decompiled source:
    -- ReplicatedStorage.Modules.DataService.[numericId].[numericId]
    -- e.g. DataService > 756538457 > 756538457
    -- We don't hardcode the ID — we wait for the first child then
    -- wait for a same-named child inside it.
    local ok, remote = pcall(function()
        local modules = _RepStore:WaitForChild('Modules', 15)
        local ds      = modules:WaitForChild('DataService', 15)

        -- Wait for the numeric ID folder to appear
        local idFolder
        local waited = 0
        repeat
            task.wait(0.2); waited = waited + 0.2
            idFolder = ds:GetChildren()[1]
        until idFolder or waited >= 10

        if not idFolder then error('DataService has no children') end

        -- Inside the ID folder is a RemoteFunction/Event with the same name
        local innerRemote = idFolder:WaitForChild(idFolder.Name, 10)
        if not innerRemote then error('Inner remote not found inside ' .. idFolder.Name) end

        return innerRemote
    end)

    if not ok or not remote then
        Library:Notify('[Pizza] Remote lookup failed: ' .. tostring(remote))
        return nil
    end
    return remote
end

local function _getConveyorBox()
    local env  = workspace:FindFirstChild('Environment');                         if not env  then return nil end
    local loc  = env:FindFirstChild('Locations');                                 if not loc  then return nil end
    local city = loc:FindFirstChild('City');                                      if not city then return nil end
    local pp   = city:FindFirstChild('PizzaPlanet');                              if not pp   then return nil end
    local int_ = pp:FindFirstChild('Interior');                                   if not int_ then return nil end
    local conv = int_:FindFirstChild('Conveyor');                                 if not conv then return nil end
    local mb   = conv:FindFirstChild('MovingBoxes');                              if not mb   then return nil end
    return mb:FindFirstChildWhichIsA('UnionOperation')
end

-- Find the customer that belongs to THIS box delivery.
-- TakePizzaBox returns (_, customerTargetPos) — a Vector3 the
-- customer is walking toward. We find the tagged customer whose
-- HumanoidRootPart is closest to that target position.
-- Falls back to any tagged customer if no target pos given.
local function _findCustomerForBox(customerTargetPos)
    local allCustomers = {}

    -- Collect from CollectionService tag
    for _, c in next, _CollSvc:GetTagged(BOX_TAG) do
        table.insert(allCustomers, c)
    end

    -- Collect from workspace._game.SpawnedCharacters (decompile source)
    local game_  = workspace:FindFirstChild('_game')
    local spawns = game_ and game_:FindFirstChild('SpawnedCharacters')
    if spawns then
        for _, v in next, spawns:GetChildren() do
            if v.Name:find('PizzaPlanet') then
                -- avoid duplicates
                local found = false
                for _, already in next, allCustomers do
                    if already == v then found = true; break end
                end
                if not found then table.insert(allCustomers, v) end
            end
        end
    end

    if #allCustomers == 0 then return nil end

    -- If we have the target position the server gave us, pick the
    -- customer closest to it (this is the one assigned to our box)
    if customerTargetPos and typeof(customerTargetPos) == 'Vector3' then
        local best, bd = nil, math.huge
        for _, c in next, allCustomers do
            local hrp = c:FindFirstChild('HumanoidRootPart') or c.PrimaryPart
            if hrp then
                local d = (hrp.Position - customerTargetPos).Magnitude
                if d < bd then bd, best = d, c end
            end
        end
        return best
    end

    -- Fallback: return first one
    return allCustomers[1]
end

-- ── UsePizzaMoped — ShiftLoop bypass ─────────────────────────
-- ShiftLoop kicks you if sqrMag(AreaBlock - root) > 1225 (35 studs)
-- AND v_u_10 (moped vehicle) is nil/not in workspace.
-- Calling UsePizzaMoped spawns the moped on our character.
-- sqrMag(moped.pos - root.pos) ≈ 0 always → ShiftLoop always passes.
local _activeMoped = nil
local function _spawnMopedBypass(remote)
    local ok, result = pcall(function()
        return remote:InvokeServer({ Type = 'UsePizzaMoped' })
    end)
    if ok and result then
        _activeMoped = result
        Library:Notify('[Pizza] Moped active — ShiftLoop bypass on')
    else
        -- Also try finding it on character
        local char = LocalPlayer.Character
        _activeMoped = char and char:FindFirstChild('Vehicle_Delivery Moped')
        if _activeMoped then
            Library:Notify('[Pizza] Moped found on character')
        else
            Library:Notify('[Pizza] Moped spawn uncertain — delivery may still work')
        end
    end
    return _activeMoped
end

-- Detach moped before teleporting to prevent physics fling.
-- Server still thinks it exists (it's just reparented client-side).
local function _detachMoped()
    local char = LocalPlayer.Character; if not char then return end
    local moped = char:FindFirstChild('Vehicle_Delivery Moped')
    if moped then
        moped.Parent = workspace  -- move out of character, kills weld
        task.delay(2, function()
            -- quietly clean up
            pcall(function() moped:Destroy() end)
        end)
    end
end

-- ── Main delivery loop ────────────────────────────────────────
_fnDelivery = function(toggle)
    if not toggle then return end

    local remote = _getDeliveryRemote()
    if not remote then return end

    Library:Notify('[Pizza] Starting — setting up moped bypass…')
    _spawnMopedBypass(remote)
    task.wait(1.5)

    Library:Notify('[Pizza Delivery] Loop running!')

    while _isDelivering() do
        task.wait(0.1)

        local char = LocalPlayer.Character
        if not char then task.wait(1); continue end

        -- ── 1. Wait for a box on the conveyor ─────────────────
        local box = _getConveyorBox()
        if not box then task.wait(0.4); continue end

        -- Move to box pickup position
        local pickupPos = box.Position + Vector3.new(0, 3, 0)
        _moveToPos(pickupPos)

        -- If Desync mode, unanchor for the pickup keypress then re-anchor
        local mode = Options.BX_MoveMode and Options.BX_MoveMode.Value or 'Tween (Safe)'
        if mode == 'Desync TP' then _desyncEnd() end

        if not _isDelivering() then break end

        -- Snap character directly onto the box for reliable E-press
        char = LocalPlayer.Character
        if char then
            char:SetPrimaryPartCFrame(CFrame.new(box.Position + Vector3.new(0, 3, 0)))
        end
        task.wait(0.05)

        -- ── 2. Pick up the box ─────────────────────────────────
        -- Primary method: InvokeServer({ Type='TakePizzaBox' })
        -- Returns (_, customerTargetPos) per decompiled game source
        local gotBox          = false
        local customerTargetPos = nil

        local ok1, r1, r2 = pcall(function()
            -- The game returns two values: status, customer_target_pos
            local a, b = remote:InvokeServer({ Type = 'TakePizzaBox', Box = box })
            return a, b
        end)
        if ok1 then
            -- r2 is the customer target Vector3 if the server returned it
            if typeof(r2) == 'Vector3' then
                customerTargetPos = r2
            elseif typeof(r1) == 'Vector3' then
                customerTargetPos = r1
            end
            task.wait(0.15)
            char = LocalPlayer.Character
            gotBox = char and char:FindFirstChild('Pizza Box') ~= nil
        end

        -- Fallback: keypress E (0x45)
        if not gotBox then
            keypress(0x45); task.wait(0.1); keyrelease(0x45)
            task.wait(0.25)
            char = LocalPlayer.Character
            gotBox = char and char:FindFirstChild('Pizza Box') ~= nil
        end

        if not gotBox then
            Library:Notify('[Pizza] Failed to grab box, retrying…')
            task.wait(0.5); continue
        end

        Library:Notify('[Pizza] Box in hand! Locating correct customer…')

        -- ── 3. Find the specific customer for this box ─────────
        -- Poll a few times — customer may not spawn immediately
        local customer = nil
        for _ = 1, 30 do
            task.wait(0.3)
            customer = _findCustomerForBox(customerTargetPos)
            if customer then break end
        end

        if not customer then
            Library:Notify('[Pizza] No customer found — dropping and retrying')
            -- Drop the box (can't deliver to nobody)
            keypress(0x47); task.wait(0.1); keyrelease(0x47)  -- G key drop
            task.wait(1); continue
        end

        local customerHRP = customer:FindFirstChild('HumanoidRootPart') or customer.PrimaryPart
        if not customerHRP then task.wait(0.5); continue end

        Library:Notify('[Pizza] Found customer — moving to deliver…')

        -- ── 4. Move to customer ────────────────────────────────
        -- For Teleport/Desync: detach the moped FIRST to prevent fling.
        -- We'll respawn it after delivery.
        if mode == 'Teleport' or mode == 'Desync TP' or mode == 'Underground' then
            _detachMoped()
            task.wait(0.1)
        end

        -- Move right next to the customer (within 4 studs for interaction)
        local deliverPos = customerHRP.Position + Vector3.new(0, 2, 3)
        _moveToPos(deliverPos)
        if not _isDelivering() then
            if mode == 'Desync TP' then _desyncEnd() end
            break
        end

        -- Fine-adjust: snap directly in front of customer for E press
        char = LocalPlayer.Character
        if char then
            char:SetPrimaryPartCFrame(
                CFrame.new(customerHRP.Position + Vector3.new(0, 2, 3),
                           customerHRP.Position)
            )
        end
        task.wait(0.05)

        -- ── 5. Deliver via keypress E ──────────────────────────
        -- The game's proximity interaction fires when you're close enough
        -- and press E. This is the most reliable delivery method.
        -- We also fire the remote as a backup in the same frame.
        keypress(0x45)
        task.wait(0.05)

        -- Backup remote call simultaneously
        pcall(function()
            remote:FireServer({ Type = 'DeliverPizza', Customer = customer })
        end)

        task.wait(0.1)
        keyrelease(0x45)

        -- ── 6. If desync mode, unanchor now ─────────────────────
        if mode == 'Desync TP' then
            _desyncEnd()
        end

        Library:Notify('[Pizza] Delivered! Waiting for box to clear…')

        -- ── 7. Wait for pizza box to leave inventory ───────────
        local timeout = 0
        repeat
            task.wait(0.2); timeout = timeout + 0.2
            char = LocalPlayer.Character
        until not (char and char:FindFirstChild('Pizza Box')) or timeout >= 10

        if timeout >= 10 then
            Library:Notify('[Pizza] Box stuck — did not clear. Retrying next loop.')
        end

        -- ── 8. Respawn moped for ShiftLoop bypass next round ───
        task.wait(0.3)
        if _isDelivering() then
            pcall(function()
                _activeMoped = nil
                _spawnMopedBypass(remote)
            end)
        end

        task.wait(0.3)
    end

    -- Clean up on stop
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if root then root.Anchored = false end

    Library:Notify('[Pizza Delivery] Stopped.')
end

-- ================================================================
--  FRAMEWORK BOOTSTRAP
--  Needed for: house save/load, plot teleport, EndShift hook
-- ================================================================
task.spawn(function()
    local ok, fw = pcall(function()
        local m = require(_RepStore:WaitForChild('Framework', 10))
        return m and getupvalue(m, 3) or nil
    end)
    if not ok or not fw then
        Library:Notify('[BXBRG] Framework not found — run inside Bloxburg!')
        return
    end
    _bxFW = fw

    local _bxMods
    repeat task.wait()
        _bxMods = _bxFW.Modules
        _bxNet  = _bxFW.net
    until _bxMods and _bxNet

    if not isfolder('Yazu/Bloxburg Houses') then makefolder('Yazu/Bloxburg Houses') end

    -- ── EndShift suppression (backup layer) ───────────────────
    -- Even with the moped bypass, hook EndShift as a safety net.
    local _oldFS = _bxNet.FireServer
    _oldFS = hookfunction(_bxNet.FireServer, function(self, data, ...)
        if data and data.Type == 'EndShift'
        and Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value then
            -- Block the EndShift signal while we're actively delivering
            return
        end
        return pcall(_oldFS, self, data, ...)
    end)

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
end) -- end task.spawn

end -- return function
