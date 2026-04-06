-- ================================================================
--  features/misc.lua
--  Contains: Desync (Instant + Delayed lag-mimic), SpinBot UI,
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

-- ================================================================
--  DESYNC STATE
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'

-- Two SEPARATE ownership flags — this was the conflict root cause.
-- The heartbeat backs off when EITHER is true.
--   burstWindowOpen  → delayed loop owns the fflag right now
--   forceSyncActive  → a state-change sync (seat/ragdoll) owns it
-- Previously both shared one flag so they would race and corrupt
-- each other's timing.
local burstWindowOpen = false
local forceSyncActive = false

local lastFlagState   = nil   -- avoids redundant setfflag pcalls

local function setReplicator(enabled)
    local val = enabled and 'True' or 'False'
    if lastFlagState == val then return end
    lastFlagState = val
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', val) end)
end

-- Heartbeat should back off when either system owns the fflag
local function replicatorIsOwned()
    return burstWindowOpen or forceSyncActive
end

-- ================================================================
--  PART HELPERS
-- ================================================================
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
local vizConn = nil

-- ================================================================
--  SERVER ROOT PART — FORCED STATE SYNC
--
--  Certain humanoid states (Seated, Ragdoll, etc.) bypass the
--  fflag and force Roblox to push a real position packet.
--  We catch those, open replication intentionally, wait 5 frames
--  for the engine + weld to settle, snapshot what the server sees,
--  then lock again. Uses its own flag (forceSyncActive) completely
--  separate from the delayed burst system.
-- ================================================================
local charStateConn  = nil
local syncQueued     = false   -- prevent stacking multiple syncs

local FORCED_REPLICATION_STATES = {
    [Enum.HumanoidStateType.Seated]      = true,
    [Enum.HumanoidStateType.GettingUp]   = true,
    [Enum.HumanoidStateType.Ragdoll]     = true,
    [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.Climbing]    = true,
    [Enum.HumanoidStateType.Swimming]    = true,
}

local function forceSyncServerPos()
    if syncQueued then return end
    syncQueued = true

    task.spawn(function()
        -- If the burst loop is mid-window, wait for it to finish first
        while burstWindowOpen do RunService.Heartbeat:Wait() end

        forceSyncActive = true
        lastFlagState   = nil

        setReplicator(true)
        for _ = 1, 5 do RunService.Heartbeat:Wait() end

        local hrp = getLocalHRP()
        if hrp then State.frozenServerPos = hrp.Position end

        setReplicator(false)
        forceSyncActive = false
        syncQueued      = false
    end)
end

local function connectCharacterStateTracking(char)
    if charStateConn then charStateConn:Disconnect(); charStateConn = nil end
    if not char then return end

    local hum = char:FindFirstChildWhichIsA('Humanoid')
    if not hum then
        local waitConn; waitConn = char.ChildAdded:Connect(function(child)
            if child:IsA('Humanoid') then
                waitConn:Disconnect()
                connectCharacterStateTracking(char)
            end
        end)
        return
    end

    charStateConn = hum.StateChanged:Connect(function(_, newState)
        if not State.desyncActive then return end
        if FORCED_REPLICATION_STATES[newState] then
            forceSyncServerPos()
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
            local tag  = State.desyncMode == 'delayed' and '[LAG] ' or ''
            serverLbl.Text = 'SERVER ' .. tag .. dist .. 'm'
            clientLbl.Text = 'CLIENT'
        else
            serverPart.CFrame = hrp.CFrame
            serverLbl.Text = 'SERVER (synced)'
            clientLbl.Text = 'CLIENT'
        end
    end)

    connectCharacterStateTracking(LocalPlayer.Character)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil; serverPart.Parent = nil
end

-- ================================================================
--  DELAYED DESYNC — BURST LAG LOOP
--
--  Uses burstWindowOpen (not shared with forceSyncServerPos).
--  Pattern every N±jitter seconds:
--    1. Raise burstWindowOpen  → heartbeat backs off
--    2. Open replicator
--    3. Wait exactly 3 heartbeat frames  (physics-aligned flush)
--    4. Snapshot frozenServerPos
--    5. Close replicator
--    6. Lower burstWindowOpen  → heartbeat resumes guard
-- ================================================================
local delayedLoopActive = false

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true

    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            local base   = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            local jitter = math.random(-500, 500) / 1000
            task.wait(math.max(0.1, base + jitter))

            if not State.desyncActive or State.desyncMode ~= 'delayed' then break end

            -- Wait for any active force-sync to finish before our burst
            while forceSyncActive do RunService.Heartbeat:Wait() end

            burstWindowOpen = true
            lastFlagState   = nil

            setReplicator(true)
            for _ = 1, 3 do RunService.Heartbeat:Wait() end

            local hrp = getLocalHRP()
            if hrp then State.frozenServerPos = hrp.Position end

            setReplicator(false)
            burstWindowOpen = false
        end

        delayedLoopActive = false
    end)
end

local function stopDelayedLoop()
    burstWindowOpen     = false
    delayedLoopActive   = false
end

-- ================================================================
--  DESYNC ENABLE / DISABLE
-- ================================================================
local function pauseDesync()
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen       = false
    forceSyncActive       = false
    syncQueued            = false
    stopDelayedLoop()
    lastFlagState = nil
    setReplicator(true)
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    local hrp = getLocalHRP()
    if not hrp then
        Library:Notify('No character!')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
    end
    State.frozenServerPos = hrp.Position
    State.desyncActive    = true
    burstWindowOpen       = false
    forceSyncActive       = false
    syncQueued            = false
    lastFlagState         = nil
    setReplicator(false)

    if State.desyncMode == 'delayed' then
        startDelayedLoop()
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        Library:Notify(('Lag Desync ON — bursts every ~%.0fs'):format(iv))
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
--  CHARACTER ADDED
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    if State.desyncHbConn then State.desyncHbConn:Disconnect(); State.desyncHbConn = nil end
    desyncInitialized     = false
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen       = false
    forceSyncActive       = false
    syncQueued            = false
    lastFlagState         = nil
    stopDelayedLoop()
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
--  INIT DESYNC
-- ================================================================
local function initDesync()
    if not setfflag then Library:Notify('setfflag not available in this executor'); return end
    if desyncInitialized then Library:Notify('Already initialized — use the Enable toggle'); return end
    if not getLocalHRP() then Library:Notify('No character — spawn in first'); return end
    desyncInitialized = true

    State.desyncHbConn = RunService.Heartbeat:Connect(function()
        if not State.desyncActive then return end
        if replicatorIsOwned() then return end  -- burst or forceSync owns it

        if State.desyncMode == 'instant' then
            setReplicator(false)
        elseif State.desyncMode == 'delayed' then
            setReplicator(false)
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

DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Initialize first, then toggle.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text    = 'Desync Mode',
    Default = 'Instant',
    Values  = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v)
        State.desyncMode = (v == 'Instant') and 'instant' or 'delayed'
        if State.desyncActive then
            if State.desyncMode == 'instant' then
                stopDelayedLoop()
                lastFlagState = nil
                setReplicator(false)
                Library:Notify('Switched → Instant Desync')
            else
                burstWindowOpen = false
                lastFlagState   = nil
                startDelayedLoop()
                local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
                Library:Notify(('Switched → Lag Mimic (~%.0fs bursts)'):format(iv))
            end
        end
    end,
})

DesyncGrp:AddSlider('DelayedDesyncInterval', {
    Text     = 'Lag Interval (seconds)',
    Default  = 5,
    Min      = 1,
    Max      = 30,
    Rounding = 0,
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
--  RUNTIME LOOPS
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
