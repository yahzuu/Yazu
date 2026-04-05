-- ================================================================
--  features/misc.lua
--  Contains: Desync (Instant + Delayed), SpinBot UI,
--            Movement (noclip/walkspeed/jump), random part timers.
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService  = Services.RunService
local Players     = Services.Players
local LocalPlayer = Services.LocalPlayer
local TweenService = Services.TweenService

local function getLocalHRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild('HumanoidRootPart')
end

local function getLocalHumanoid()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildWhichIsA('Humanoid')
end

-- ================================================================
--  DESYNC LOGIC
-- ================================================================
local desyncInitialized = false

-- Delayed desync state
State.desyncMode           = State.desyncMode or 'instant'   -- 'instant' | 'delayed'
State.delayedDesyncTimer   = 0

local function makePart(col, label)
    local p = Instance.new('Part')
    p.Anchored = true; p.CanCollide = false; p.CastShadow = false
    p.Size = Vector3.new(2, 5, 1); p.Material = Enum.Material.Neon
    p.Color = col; p.Transparency = 0.4; p.Parent = nil
    local bb = Instance.new('BillboardGui', p)
    bb.Size = UDim2.new(0, 120, 0, 28); bb.StudsOffset = Vector3.new(0, 4, 0); bb.AlwaysOnTop = true
    local tx = Instance.new('TextLabel', bb)
    tx.Size = UDim2.new(1,0,1,0); tx.BackgroundTransparency = 1
    tx.TextColor3 = col; tx.TextStrokeTransparency = 0; tx.TextStrokeColor3 = Color3.new(0,0,0)
    tx.Font = Enum.Font.GothamBold; tx.TextSize = 13; tx.Text = label
    return p, tx
end

local clientPart, clientLbl = makePart(Color3.fromRGB(60, 255, 100), 'CLIENT')
local serverPart, serverLbl = makePart(Color3.fromRGB(255, 50,  50), 'SERVER')
local vizConn    = nil
local charStateConn = nil  -- tracks humanoid state changes for server part fix

-- ================================================================
--  SERVER ROOT PART — SEAT / STATE FIX
--  Reconnects humanoid state listener so server part stays pinned
--  even when the character sits, jumps, swims, etc.
-- ================================================================
local function connectCharacterStateTracking(char)
    if charStateConn then charStateConn:Disconnect(); charStateConn = nil end
    if not char then return end

    local hum = char:FindFirstChildWhichIsA('Humanoid')
    if not hum then
        -- Humanoid might not exist yet if char just added; wait for it
        char.ChildAdded:Connect(function(child)
            if child:IsA('Humanoid') then
                connectCharacterStateTracking(char)
            end
        end)
        return
    end

    charStateConn = hum.StateChanged:Connect(function(_, newState)
        -- On any state change (Seated, Jumping, etc.) force server part to stay pinned
        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
        end
    end)

    -- Also watch for HRP being re-parented (happens when SeatWeld is applied/removed)
    char.ChildAdded:Connect(function(child)
        if child.Name == 'HumanoidRootPart' and State.desyncActive then
            task.wait(0.1)   -- let the weld settle
            -- frozenServerPos stays the same; just re-anchor the visual
            if State.frozenServerPos then
                serverPart.CFrame = CFrame.new(State.frozenServerPos)
            end
        end
    end)
end

-- ================================================================
--  VISUALIZER
-- ================================================================
local function startViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = workspace; serverPart.Parent = workspace
    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame
        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
            local dist = math.floor((hrp.Position - State.frozenServerPos).Magnitude)
            local modeTag = State.desyncMode == 'delayed' and '[DELAY]' or ''
            serverLbl.Text = 'SERVER ' .. modeTag .. '  ' .. dist .. 'm'
            clientLbl.Text = 'CLIENT'
        else
            serverPart.CFrame = hrp.CFrame
            serverLbl.Text = 'SERVER (synced)'; clientLbl.Text = 'CLIENT'
        end
    end)
    -- Re-hook state tracking so visualizer stays correct through sits etc.
    connectCharacterStateTracking(LocalPlayer.Character)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil; serverPart.Parent = nil
end

-- ================================================================
--  DESYNC ENABLE / DISABLE
-- ================================================================
local function pauseDesync()
    State.desyncActive = false; State.frozenServerPos = nil
    State.delayedDesyncTimer = 0
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'True') end)
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    local hrp = getLocalHRP()
    if not hrp then
        Library:Notify('No character!')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
    end
    State.frozenServerPos    = hrp.Position
    State.desyncActive       = true
    State.delayedDesyncTimer = 0
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)

    if State.desyncMode == 'delayed' then
        local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        Library:Notify(('Delayed Desync ON — server updates every %.1fs'):format(interval))
    else
        Library:Notify('Instant Desync ON — server frozen at current position')
    end
end

-- ================================================================
--  TOUCH DETECTION (auto-off)
-- ================================================================
local touchConn = nil
local function connectTouchDetection()
    if touchConn then touchConn:Disconnect(); touchConn = nil end
    local char = LocalPlayer.Character; if not char then return end
    local hrp  = char:FindFirstChild('HumanoidRootPart'); if not hrp then return end
    touchConn = hrp.Touched:Connect(function(hit)
        if not State.desyncActive then return end
        if not (Toggles.DesyncAutoOff and Toggles.DesyncAutoOff.Value) then return end
        local model = hit:FindFirstAncestorWhichIsA('Model'); if not model then return end
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer and p.Character == model then
                task.defer(function()
                    if not State.desyncActive then return end
                    pauseDesync(); Toggles.DesyncEnabled:SetValue(false)
                    Library:Notify('Desync OFF — touched a player!')
                end); return
            end
        end
    end)
end

-- ================================================================
--  CHARACTER ADDED — reset everything cleanly
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    if State.desyncHbConn then State.desyncHbConn:Disconnect(); State.desyncHbConn = nil end
    desyncInitialized        = false
    State.desyncActive       = false
    State.frozenServerPos    = nil
    State.delayedDesyncTimer = 0
    pcall(function() if setfflag then setfflag('NextGenReplicatorEnabledWrite4', 'True') end end)
    stopViz()
    task.defer(function() Toggles.DesyncEnabled:SetValue(false) end)
    task.wait(1)
    connectTouchDetection()
    connectCharacterStateTracking(char)
end)

if LocalPlayer.Character then
    connectTouchDetection()
    connectCharacterStateTracking(LocalPlayer.Character)
end

-- ================================================================
--  INIT DESYNC — sets up the heartbeat that drives both modes
-- ================================================================
local function initDesync()
    if not setfflag then Library:Notify('setfflag not available in this executor'); return end
    if desyncInitialized   then Library:Notify('Already initialized — use the Enable toggle'); return end
    if not getLocalHRP()   then Library:Notify('No character — spawn in first'); return end
    desyncInitialized = true

    State.desyncHbConn = RunService.Heartbeat:Connect(function(dt)
        if not State.desyncActive then return end

        if State.desyncMode == 'instant' then
            -- ── INSTANT MODE ─────────────────────────────────────────────
            -- Original behaviour: keep replication disabled every frame.
            pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)

        elseif State.desyncMode == 'delayed' then
            -- ── DELAYED MODE ─────────────────────────────────────────────
            -- Passively accumulate time. Every N seconds, open a tiny
            -- replication window so the server gets ONE position snapshot,
            -- then lock again. Looks exactly like rubber-band / high-ping lag.
            State.delayedDesyncTimer = State.delayedDesyncTimer + dt
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5

            if State.delayedDesyncTimer >= interval then
                State.delayedDesyncTimer = 0

                -- Step 1: re-enable replication (server sees your real pos)
                pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'True') end)

                -- Step 2: grab the new "lag snapshot" position for the visualizer
                local hrp = getLocalHRP()
                if hrp then State.frozenServerPos = hrp.Position end

                -- Step 3: lock again after one physics frame (~100 ms is safe)
                task.delay(0.1, function()
                    if State.desyncActive and State.desyncMode == 'delayed' then
                        pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)
                    end
                end)
            else
                -- Between updates, keep replication off
                pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)
            end
        end
    end)

    Library:Notify('Desync ready — use the Enable Desync toggle')
end

-- ================================================================
--  UI — MISC TAB
-- ================================================================
local DesyncGrp = Tabs.Misc:AddLeftGroupbox('Desync')
local SpinGrp   = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp   = Tabs.Misc:AddRightGroupbox('Misc')

-- ── Desync ────────────────────────────────────────────────────────
DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Initialize first, then toggle.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text    = 'Desync Mode',
    Default = 'Instant',
    Values  = { 'Instant', 'Delayed' },
    Callback = function(v)
        State.desyncMode         = (v == 'Delayed') and 'delayed' or 'instant'
        State.delayedDesyncTimer = 0
        if State.desyncActive then
            if State.desyncMode == 'instant' then
                Library:Notify('Switched → Instant Desync')
            else
                local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
                Library:Notify(('Switched → Delayed Desync (%.1fs)'):format(iv))
            end
        end
    end,
})

DesyncGrp:AddSlider('DelayedDesyncInterval', {
    Text     = 'Delayed Interval (seconds)',
    Default  = 5,
    Min      = 1,
    Max      = 30,
    Rounding = 1,
    -- Live-updates during active delayed desync via the main hb loop automatically.
})

DesyncGrp:AddToggle('DesyncEnabled', {
    Text = 'Enable Desync', Default = false,
    Callback = function(v)
        if v then
            if not desyncInitialized then
                Library:Notify('Press Initialize Desync first!')
                task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
            end
            resumeDesync()
        else
            if not desyncInitialized then return end
            pauseDesync()
        end
    end,
})

DesyncGrp:AddToggle('DesyncVisualizer', {
    Text = 'Show Client + Server (3D)', Default = false,
    Callback = function(v) if v then startViz() else stopViz() end end,
})

DesyncGrp:AddToggle('DesyncAutoOff', { Text = 'Auto-Off on Player Contact', Default = true })

-- ── SpinBot ───────────────────────────────────────────────────────
SpinGrp:AddToggle('SpinBotEnabled',       { Text = 'Enable SpinBot', Default = false })
SpinGrp:AddLabel('Spin Key'):AddKeyPicker('SpinKey', { Default = 'None', Text = 'Spin Key', Mode = 'Hold' })
SpinGrp:AddToggle('OnePressSpinningMode', { Text = 'One-Press Mode', Default = false })
SpinGrp:AddSlider('SpinVelocity',         { Text = 'Spin Velocity',  Default = 50, Min = 1, Max = 50, Rounding = 1 })
SpinGrp:AddDropdown('SpinPart', { Text = 'Spin Part', Default = 2, Values = State.spinPartValues })
SpinGrp:AddInput('AddSpinPartInput',    { Default = '', Text = 'Add Spin Part',    Placeholder = 'Part name...' })
SpinGrp:AddButton({ Text = 'Add Spin Part', Func = function()
    local v = Options.AddSpinPartInput and Options.AddSpinPartInput.Value or ''
    if #v > 0 and not table.find(State.spinPartValues, v) then
        table.insert(State.spinPartValues, v)
        Options.SpinPart:SetValues(State.spinPartValues)
        Options.SpinPart:SetValue(v)
    end
end })
SpinGrp:AddInput('RemoveSpinPartInput', { Default = '', Text = 'Remove Spin Part', Placeholder = 'Part name...' })
SpinGrp:AddButton({ Text = 'Remove Spin Part', Func = function()
    local v = Options.RemoveSpinPartInput and Options.RemoveSpinPartInput.Value or ''
    local i = table.find(State.spinPartValues, v)
    if i then table.remove(State.spinPartValues, i); Options.SpinPart:SetValues(State.spinPartValues) end
end })
SpinGrp:AddToggle('RandomSpinPart', { Text = 'Random Spin Part (1s)', Default = false })

-- ── Movement ──────────────────────────────────────────────────────
MiscGrp:AddToggle('NoClipToggle', { Text = 'No Clip', Default = false })
MiscGrp:AddLabel('Walkspeed')
MiscGrp:AddToggle('WalkspeedToggle', { Text = 'Enable Custom Walkspeed', Default = false })
MiscGrp:AddSlider('WalkspeedValue',  { Text = 'Speed', Default = 16, Min = 2, Max = 500, Rounding = 0 })
MiscGrp:AddLabel('Jump Power')
MiscGrp:AddToggle('JumpPowerToggle', { Text = 'Enable Custom Jump Power', Default = false })
MiscGrp:AddSlider('JumpPowerValue',  { Text = 'Power', Default = 50, Min = 10, Max = 500, Rounding = 0 })

-- ================================================================
--  RUNTIME LOOPS (movement + random part timers)
-- ================================================================
RunService.Stepped:Connect(function()
    if not (Toggles.NoClipToggle and Toggles.NoClipToggle.Value) then return end
    local char = LocalPlayer.Character; if not char then return end
    for _, v in next, char:GetDescendants() do
        if v:IsA('BasePart') then v.CanCollide = false end
    end
end)

RunService.Heartbeat:Connect(function()
    if not (Toggles.WalkspeedToggle and Toggles.WalkspeedToggle.Value) then return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid')
    if hum then hum.WalkSpeed = Options.WalkspeedValue and Options.WalkspeedValue.Value or 16 end
end)

RunService.Heartbeat:Connect(function()
    if not (Toggles.JumpPowerToggle and Toggles.JumpPowerToggle.Value) then return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid')
    if hum then hum.JumpPower = Options.JumpPowerValue and Options.JumpPowerValue.Value or 50 end
end)

RunService.Heartbeat:Connect(function()
    local now = os.clock()
    if Toggles.RandomAimPart and Toggles.RandomAimPart.Value and now - State.lastRandAimTime >= 1 then
        State.lastRandAimTime = now
        if Options.AimPart and #State.aimPartValues > 0 then
            Options.AimPart:SetValue(State.aimPartValues[math.random(1, #State.aimPartValues)])
        end
    end
    if Toggles.RandomSpinPart and Toggles.RandomSpinPart.Value and now - State.lastRandSpinTime >= 1 then
        State.lastRandSpinTime = now
        if Options.SpinPart and #State.spinPartValues > 0 then
            Options.SpinPart:SetValue(State.spinPartValues[math.random(1, #State.spinPartValues)])
        end
    end
end)

end -- return function
