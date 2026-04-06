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
local desyncInitialized   = false
State.desyncMode          = State.desyncMode or 'instant'
State.delayedWindowOpen   = false   -- true while lag loop owns the fflag
local lastFlagState       = nil     -- tracks actual fflag value to avoid redundant calls

-- Only call setfflag when the value actually needs to change.
-- Calling pcall every heartbeat (~60x/sec) is expensive.
local function setReplicator(enabled)
    local val = enabled and 'True' or 'False'
    if lastFlagState == val then return end
    lastFlagState = val
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', val) end)
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
--  SERVER ROOT PART — FORCED REPLICATION SYNC
--
--  Problem: Seated / Ragdoll / GettingUp / Swimming / Climbing /
--  FallingDown all bypass the fflag and force a position packet.
--  When that happens frozenServerPos is stale and the server part
--  looks frozen at the wrong spot.
--
--  Fix: On those states, immediately take ownership of the fflag
--  (bypass delayedWindowOpen), open replication, wait exactly 5
--  heartbeat frames so the engine physically moves the HRP and
--  flushes the packet, THEN snapshot and re-lock.
--  5 frames (~83ms at 60fps) is the sweet spot: enough for the
--  seat weld + replication flush, not so long it's visible.
-- ================================================================
local charStateConn = nil

local FORCED_REPLICATION_STATES = {
    [Enum.HumanoidStateType.Seated]      = true,
    [Enum.HumanoidStateType.GettingUp]   = true,
    [Enum.HumanoidStateType.Ragdoll]     = true,
    [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.Climbing]    = true,
    [Enum.HumanoidStateType.Swimming]    = true,
}

local syncInProgress = false

local function forceSyncServerPos()
    if syncInProgress then return end
    syncInProgress = true

    task.spawn(function()
        -- Take ownership of the fflag regardless of delayed loop state
        local prevWindow = State.delayedWindowOpen
        State.delayedWindowOpen = true   -- pause the heartbeat guard
        lastFlagState = nil              -- force setReplicator to actually fire

        setReplicator(true)

        -- Wait exactly 5 physics frames — engine moves HRP, replication flushes
        for _ = 1, 5 do RunService.Heartbeat:Wait() end

        local hrp = getLocalHRP()
        if hrp then State.frozenServerPos = hrp.Position end

        setReplicator(false)
        State.delayedWindowOpen = prevWindow
        syncInProgress = false
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
--  Key insight from previous broken version:
--  The heartbeat (~60x/sec) and the time-window were fighting over
--  the same fflag. The heartbeat was setting it False before a
--  single packet could get through.
--
--  Architecture now:
--    • Heartbeat ONLY touches the fflag when delayedWindowOpen=false
--    • The lag loop sets delayedWindowOpen=true, does its burst,
--      then releases. They never overlap.
--
--  Burst pattern (mimics natural high-ping lag):
--    ├─ wait N±jitter seconds (fflag=False the whole time)
--    ├─ open fflag=True
--    ├─ wait exactly 3 heartbeat frames  ← reliable engine flush
--    ├─ snapshot frozenServerPos
--    ├─ close fflag=False
--    └─ repeat
--
--  Why Heartbeat:Wait() instead of task.wait(0.2)?
--  task.wait is time-based and doesn't align with the physics step.
--  3 heartbeat frames guarantees the engine has run 3 physics steps
--  and the replicator has had exactly 3 chances to send a packet.
--  This is consistent regardless of frame rate.
--
--  Jitter: real lag is never perfectly periodic. ±0.5s randomness
--  makes the pattern feel genuine and harder to predict/exploit.
-- ================================================================
local delayedLoopActive = false

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true

    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            local base    = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            local jitter  = math.random(-500, 500) / 1000   -- ±0.5s
            task.wait(math.max(0.1, base + jitter))

            if not State.desyncActive or State.desyncMode ~= 'delayed' then break end

            -- Take ownership — heartbeat will not touch fflag during this block
            State.delayedWindowOpen = true
            lastFlagState = nil   -- force the call to actually fire

            setReplicator(true)

            -- Wait exactly 3 physics frames — guaranteed engine flush
            for _ = 1, 3 do RunService.Heartbeat:Wait() end

            -- Snapshot what the server just received
            local hrp = getLocalHRP()
            if hrp then State.frozenServerPos = hrp.Position end

            setReplicator(false)
            State.delayedWindowOpen = false
        end

        delayedLoopActive = false
    end)
end

local function stopDelayedLoop()
    State.delayedWindowOpen = false
    delayedLoopActive = false
    -- Loop exits naturally on next iteration via while condition
end

-- ================================================================
--  DESYNC ENABLE / DISABLE
-- ================================================================
local function pauseDesync()
    State.desyncActive      = false
    State.frozenServerPos   = nil
    State.delayedWindowOpen = false
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
    State.frozenServerPos   = hrp.Position
    State.desyncActive      = true
    State.delayedWindowOpen = false
    lastFlagState = nil
    setReplicator(false)

    if State.desyncMode == 'delayed' then
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        startDelayedLoop()
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
--  CHARACTER ADDED — full reset
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    if State.desyncHbConn then State.desyncHbConn:Disconnect(); State.desyncHbConn = nil end
    desyncInitialized       = false
    State.desyncActive      = false
    State.frozenServerPos   = nil
    State.delayedWindowOpen = false
    syncInProgress          = false
    lastFlagState           = nil
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
--  Heartbeat guard: only keeps fflag locked while NOT in a window.
--  State-change optimized: only calls setReplicator when value
--  actually differs from lastFlagState (no wasted pcall spam).
-- ================================================================
local function initDesync()
    if not setfflag then Library:Notify('setfflag not available in this executor'); return end
    if desyncInitialized then Library:Notify('Already initialized — use the Enable toggle'); return end
    if not getLocalHRP() then Library:Notify('No character — spawn in first'); return end
    desyncInitialized = true

    State.desyncHbConn = RunService.Heartbeat:Connect(function()
        if not State.desyncActive then return end

        if State.desyncMode == 'instant' then
            setReplicator(false)

        elseif State.desyncMode == 'delayed' then
            -- Only guard when the lag loop isn't mid-burst
            if not State.delayedWindowOpen then
                setReplicator(false)
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
                State.delayedWindowOpen = false
                lastFlagState = nil
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
    -- Loop reads this live on every cycle. Changing the slider
    -- takes effect on the very next burst without restarting.
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
