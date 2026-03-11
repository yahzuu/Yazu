-- ================================================================
--  features/bloxburg.lua
--  Pizza Delivery only — all other jobs removed.
--
--  Fixes v2:
--   1. Tab-out support         → All interactions use remote calls
--                               only. keypress(0x45) removed as
--                               primary — it cannot fire when the
--                               window is not focused. Remote calls
--                               (InvokeServer / FireServer) work
--                               fully in the background.
--   2. Moped fling fix         → Moped BaseParts are ANCHORED
--                               before any character movement and
--                               UNANCHORED after. This prevents the
--                               vehicle physics from going haywire
--                               while tweening / teleporting.
--   3. Moped never detached    → _detachMoped() removed entirely.
--                               The moped stays on the character
--                               at all times. Anchoring it during
--                               travel is enough to prevent fling.
--   4. Desync moped fix        → When the HumanoidRootPart is
--                               anchored server-side, we now also
--                               anchor every moped part so the
--                               entire vehicle stays frozen at
--                               PizzaPlanet as far as the server
--                               is concerned.
--   5. Teleport moped fix      → Same anchor-before-TP approach
--                               prevents physics explosion on
--                               instant moves.
--   6. Moped recovery          → Each loop iteration verifies the
--                               moped is present on the character.
--                               If missing it re-spawns via
--                               UsePizzaMoped before proceeding.
--   7. Speed/ShiftLoop kick    → UsePizzaMoped keeps moped on
--                               character; moped proximity branch
--                               in ShiftLoop keeps check passing.
--   8. Proper box pickup       → InvokeServer({Type='TakePizzaBox'})
--   9. Proper delivery         → FireServer({Type='DeliverPizza'})
--  10. Customer detection      → CollectionService tags +
--                               workspace._game.SpawnedCharacters
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
        if _fnDelivery then
            task.spawn(_fnDelivery, v)
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

-- Toggle noclip on character parts only (NOT moped — handled separately)
local function _setCharNoclip(state)
    local char = LocalPlayer.Character; if not char then return end
    for _, part in next, char:GetDescendants() do
        -- Skip the moped — we anchor it instead
        if part:IsA('BasePart') and not part:FindFirstAncestorWhichIsA('Tool') then
            local mopedParent = part:FindFirstAncestor('Vehicle_Delivery Moped')
            if not mopedParent then
                part.CanCollide = not state
            end
        end
    end
end

-- ================================================================
--  MOPED MANAGEMENT
--  The moped must NEVER be detached from the character.
--  Instead we anchor every BasePart in it before any movement and
--  unanchor after arrival. This prevents physics explosions while
--  keeping the vehicle present (required for the ShiftLoop check).
-- ================================================================

-- Anchor or unanchor every BasePart inside the moped model.
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

-- Returns true if the moped is on the character and in workspace.
local function _hasMoped()
    local char = LocalPlayer.Character
    if not char then return false end
    local moped = char:FindFirstChild('Vehicle_Delivery Moped')
    return moped ~= nil and moped:IsDescendantOf(workspace)
end

-- Spawn / recover the moped via UsePizzaMoped.
-- Waits up to `timeout` seconds for it to appear on the character.
local function _spawnMoped(remote, timeout)
    timeout = timeout or 6
    if _hasMoped() then return true end
    if not remote then return false end

    local ok = pcall(function()
        remote:InvokeServer({ Type = 'UsePizzaMoped' })
    end)
    if not ok then
        Library:Notify('[Pizza] UsePizzaMoped invoke failed')
        return false
    end

    -- Wait for moped to attach to character
    local elapsed = 0
    while elapsed < timeout do
        task.wait(0.25)
        elapsed = elapsed + 0.25
        if _hasMoped() then
            Library:Notify('[Pizza] Moped ready!')
            return true
        end
    end

    Library:Notify('[Pizza] Moped did not appear within ' .. timeout .. 's')
    return false
end

-- ================================================================
--  MOVEMENT MODES
-- ================================================================
local function _moveToPos(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if not root then return end

    local mode  = Options.BX_MoveMode  and Options.BX_MoveMode.Value  or 'Tween (Safe)'
    local speed = Options.BX_TweenSpeed and Options.BX_TweenSpeed.Value or 55
    local yOff  = Options.BX_YOffset    and Options.BX_YOffset.Value    or 3

    local adjustedPos = Vector3.new(targetPos.X, targetPos.Y + yOff, targetPos.Z)

    -- Always anchor the moped BEFORE any movement to prevent fling
    _setMopedAnchored(true)

    if mode == 'Teleport' then
        -- ── Teleport ──────────────────────────────────────────
        -- Moped is anchored → TP the character → unanchor after.
        char:SetPrimaryPartCFrame(CFrame.new(adjustedPos))
        task.wait(0.05)
        _killVelocity()
        task.wait(0.08)

    elseif mode == 'Desync TP' then
        -- ── Desync TP ─────────────────────────────────────────
        -- Character root is already anchored server-side by the
        -- outer loop before calling _moveToPos.
        -- We just move the CLIENT visual here.
        char:SetPrimaryPartCFrame(CFrame.new(adjustedPos))
        task.wait(0.05)
        _killVelocity()

    else
        -- ── Tween (Safe) ──────────────────────────────────────
        local dist = (root.Position - adjustedPos).Magnitude
        if dist < 2 then
            _setMopedAnchored(false)
            return
        end

        -- Noclip character (not moped — moped is anchored)
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
            { Value = CFrame.new(adjustedPos) }
        )
        tw:Play()
        local done = false
        tw.Completed:Connect(function() done = true end)
        repeat task.wait(0.05) until done or not _isDelivering()
        tw:Cancel(); conn:Disconnect(); cfVal:Destroy()

        _setCharNoclip(false)
        _killVelocity()
    end

    -- Unanchor moped after movement is complete
    _setMopedAnchored(false)
end

-- ================================================================
--  PIZZA DELIVERY CORE
-- ================================================================
local BOX_TAG = 'PizzaPlanetDeliveryCustomer'

local function _getDeliveryRemote()
    local ok, remote = pcall(function()
        local modules = _RepStore:WaitForChild('Modules', 15)
        local ds      = modules:WaitForChild('DataService', 15)
        local idFolder
        local waited = 0
        repeat
            task.wait(0.2); waited = waited + 0.2
            idFolder = ds:GetChildren()[1]
        until idFolder or waited >= 10
        if not idFolder then error('DataService has no children after 10s') end
        local inner = idFolder:WaitForChild(idFolder.Name, 10)
        if not inner then error('Inner remote not found in ' .. idFolder.Name) end
        return inner
    end)
    if not ok or not remote then
        Library:Notify('[Pizza] No remote found — cannot deliver without remote')
        return nil
    end
    Library:Notify('[Pizza] Remote found!')
    return remote
end

local function _getConveyorBox()
    local env  = workspace:FindFirstChild('Environment');              if not env  then return nil end
    local loc  = env:FindFirstChild('Locations');                      if not loc  then return nil end
    local city = loc:FindFirstChild('City');                           if not city then return nil end
    local pp   = city:FindFirstChild('PizzaPlanet');                   if not pp   then return nil end
    local int_ = pp:FindFirstChild('Interior');                        if not int_ then return nil end
    local conv = int_:FindFirstChild('Conveyor');                      if not conv then return nil end
    local mb   = conv:FindFirstChild('MovingBoxes');                   if not mb   then return nil end
    return mb:FindFirstChildWhichIsA('UnionOperation')
end

local function _findCustomerForBox(customerTargetPos)
    local allCustomers = {}
    for _, c in next, _CollSvc:GetTagged(BOX_TAG) do
        table.insert(allCustomers, c)
    end
    local game_  = workspace:FindFirstChild('_game')
    local spawns = game_ and game_:FindFirstChild('SpawnedCharacters')
    if spawns then
        for _, v in next, spawns:GetChildren() do
            if v.Name:find('PizzaPlanet') then
                local found = false
                for _, already in next, allCustomers do
                    if already == v then found = true; break end
                end
                if not found then table.insert(allCustomers, v) end
            end
        end
    end
    if #allCustomers == 0 then return nil end
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
    return allCustomers[1]
end

-- ================================================================
--  REMOTE-ONLY INTERACTIONS (work when tabbed out)
--
--  keypress() requires the Roblox window to be focused.
--  InvokeServer() and FireServer() are network calls — they execute
--  regardless of window focus, so tab-out delivery works.
--
--  We still snap the character to the interaction position first so
--  the server-side proximity check passes.
-- ================================================================

-- Snap to position and invoke TakePizzaBox via remote.
-- Returns: gotBox (bool), customerTargetPos (Vector3 or nil)
local function _grabBox(remote, box, snapPos)
    local char = LocalPlayer.Character
    if not char then return false, nil end

    -- Snap character exactly onto box so server proximity check passes
    char:SetPrimaryPartCFrame(CFrame.new(snapPos))
    _killVelocity()
    task.wait(0.1)

    if not remote then
        Library:Notify('[Pizza] No remote — cannot grab box')
        return false, nil
    end

    local customerTargetPos = nil
    local ok1, r1, r2 = pcall(function()
        local a, b = remote:InvokeServer({ Type = 'TakePizzaBox', Box = box })
        return a, b
    end)

    if ok1 then
        if typeof(r2) == 'Vector3' then customerTargetPos = r2
        elseif typeof(r1) == 'Vector3' then customerTargetPos = r1 end
        task.wait(0.2)
    end

    char = LocalPlayer.Character
    local gotBox = char and char:FindFirstChild('Pizza Box') ~= nil
    return gotBox, customerTargetPos
end

-- Snap to customer and fire DeliverPizza via remote.
local function _deliverPizza(remote, customer, snapPos)
    local char = LocalPlayer.Character
    if not char then return false end

    -- Snap exactly onto customer so server proximity check passes
    char:SetPrimaryPartCFrame(CFrame.new(snapPos))
    _killVelocity()
    task.wait(0.1)

    if not remote then
        Library:Notify('[Pizza] No remote — cannot deliver')
        return false
    end

    -- Fire delivery to server — works tabbed out
    local ok = pcall(function()
        remote:FireServer({ Type = 'DeliverPizza', Customer = customer })
    end)

    if not ok then
        Library:Notify('[Pizza] DeliverPizza FireServer failed')
        return false
    end

    return true
end

-- ── Main delivery loop ─────────────────────────────────────────
_fnDelivery = function(toggle)
    if not toggle then return end

    local remote = _getDeliveryRemote()
    if not remote then
        Library:Notify('[Pizza] Cannot start — no remote found.')
        -- Force toggle off
        if Toggles.BX_PizzaDelivery then Toggles.BX_PizzaDelivery:SetValue(false) end
        return
    end

    Library:Notify('[Pizza] Spawning moped…')
    _spawnMoped(remote, 8)
    task.wait(1)

    Library:Notify('[Pizza Delivery] Loop running!')

    while _isDelivering() do
        task.wait(0.1)
        local char = LocalPlayer.Character
        if not char then task.wait(1); continue end

        local mode = Options.BX_MoveMode and Options.BX_MoveMode.Value or 'Tween (Safe)'

        -- ── 0. Ensure moped is present ─────────────────────────
        -- This is the key recovery step: if anything went wrong
        -- and the moped is gone, we re-spawn it before proceeding.
        if not _hasMoped() then
            Library:Notify('[Pizza] Moped missing — re-spawning…')
            local gotMoped = _spawnMoped(remote, 8)
            if not gotMoped then
                Library:Notify('[Pizza] Could not recover moped. Retrying…')
                task.wait(2); continue
            end
            char = LocalPlayer.Character
            if not char then task.wait(1); continue end
        end

        -- ── 1. Find a conveyor box ─────────────────────────────
        local box = _getConveyorBox()
        if not box then task.wait(0.4); continue end

        local root = char:FindFirstChild('HumanoidRootPart')
        if not root then task.wait(0.5); continue end

        -- ── Desync: record home position and anchor everything ──
        local desyncHomePos = nil
        if mode == 'Desync TP' then
            desyncHomePos = root.Position
            -- Anchor character root so server sees us frozen at PizzaPlanet
            root.Anchored = true
            -- ALSO anchor the moped so the server sees it frozen here too.
            -- (Moped is a child of character — we must freeze it explicitly.)
            _setMopedAnchored(true)
            task.wait(0.05)
        end

        -- ── 2. Move to box and grab it ─────────────────────────
        local boxSnapPos = Vector3.new(box.Position.X, box.Position.Y + 3, box.Position.Z)
        _moveToPos(box.Position)

        char = LocalPlayer.Character
        if not char then
            if mode == 'Desync TP' and root then
                root.Anchored = false; _setMopedAnchored(false)
            end
            continue
        end

        if not _isDelivering() then
            if mode == 'Desync TP' and root then
                root.Anchored = false; _setMopedAnchored(false)
            end
            break
        end

        local gotBox, customerTargetPos = _grabBox(remote, box, boxSnapPos)

        if not gotBox then
            Library:Notify('[Pizza] Could not grab box, retrying…')
            if mode == 'Desync TP' and root then
                -- Return client to home first, then unanchor
                char = LocalPlayer.Character
                if char and desyncHomePos then
                    char:SetPrimaryPartCFrame(CFrame.new(desyncHomePos))
                    task.wait(0.05)
                end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(0.5); continue
        end

        Library:Notify('[Pizza] Got box — finding customer…')

        -- ── 3. Find customer ───────────────────────────────────
        local customer = nil
        for _ = 1, 30 do
            task.wait(0.3)
            customer = _findCustomerForBox(customerTargetPos)
            if customer then break end
        end

        if not customer then
            Library:Notify('[Pizza] No customer found — retrying…')
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHomePos then
                    char:SetPrimaryPartCFrame(CFrame.new(desyncHomePos)); task.wait(0.05)
                end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(1); continue
        end

        local customerHRP = customer:FindFirstChild('HumanoidRootPart') or customer.PrimaryPart
        if not customerHRP then
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHomePos then
                    char:SetPrimaryPartCFrame(CFrame.new(desyncHomePos)); task.wait(0.05)
                end
                root.Anchored = false; _setMopedAnchored(false)
            end
            task.wait(0.5); continue
        end

        Library:Notify('[Pizza] Moving to customer…')

        -- ── 4. Move to customer ────────────────────────────────
        local exactCustomerPos = customerHRP.Position
        _moveToPos(exactCustomerPos)

        if not _isDelivering() then
            if mode == 'Desync TP' and root then
                char = LocalPlayer.Character
                if char and desyncHomePos then
                    char:SetPrimaryPartCFrame(CFrame.new(desyncHomePos)); task.wait(0.05)
                end
                root.Anchored = false; _setMopedAnchored(false)
            end
            break
        end

        -- ── 5. Deliver via remote (no keypress needed) ─────────
        local delivered = _deliverPizza(remote, customer, exactCustomerPos)
        if delivered then
            Library:Notify('[Pizza] Delivered!')
        else
            Library:Notify('[Pizza] Delivery remote call failed — continuing…')
        end

        -- ── 6. Desync cleanup ──────────────────────────────────
        -- CRITICAL ORDER:
        --   a) TP client BACK to PizzaPlanet (home pos)
        --   b) Unanchor root
        --   c) Unanchor moped
        -- If we unanchor at the customer position the server sees a
        -- position jump and may kick or flag the account.
        if mode == 'Desync TP' then
            task.wait(0.15)
            char = LocalPlayer.Character
            if char and desyncHomePos then
                char:SetPrimaryPartCFrame(CFrame.new(desyncHomePos))
                task.wait(0.05)
            end
            if root then
                root.Anchored = false
            end
            _setMopedAnchored(false)
            _killVelocity()
        end

        -- ── 7. Wait for box to leave inventory ─────────────────
        local timeout = 0
        repeat
            task.wait(0.2); timeout = timeout + 0.2
            char = LocalPlayer.Character
        until not (char and char:FindFirstChild('Pizza Box')) or timeout >= 10

        if timeout >= 10 then
            Library:Notify('[Pizza] Box did not clear — possible miss. Continuing…')
        end

        -- ── 8. Confirm moped is still OK before next loop ──────
        task.wait(0.3)
        if _isDelivering() and not _hasMoped() then
            Library:Notify('[Pizza] Moped lost after delivery — re-spawning…')
            _spawnMoped(remote, 6)
        end

        task.wait(0.2)
    end -- while _isDelivering()

    -- ── Cleanup on stop ────────────────────────────────────────
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if root then root.Anchored = false end
    _setMopedAnchored(false)
    _setCharNoclip(false)

    Library:Notify('[Pizza Delivery] Stopped.')
end

-- ================================================================
--  FRAMEWORK BOOTSTRAP
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

    -- ── EndShift suppression ──────────────────────────────────
    local _oldFS = _bxNet.FireServer
    _oldFS = hookfunction(_bxNet.FireServer, function(self, data, ...)
        if data and data.Type == 'EndShift'
        and Toggles.BX_PizzaDelivery and Toggles.BX_PizzaDelivery.Value then
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
