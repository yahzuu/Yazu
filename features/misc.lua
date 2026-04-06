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
--  DESYNC LOGIC
-- ================================================================
local desyncInitialized  = false
State.desyncMode         = State.desyncMode or 'instant'  -- 'instant' | 'delayed'
State.delayedWindowOpen  = false  -- true during the ~200ms replication window

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
--  SERVER ROOT PART TRACKING
--
--  Root cause of the bug:
--  State transitions like Seated / Ragdoll / GettingUp force Roblox
--  to push a real position packet to the server regardless of fflag.
--  So frozenServerPos falls out of sync with what the server sees.
--
--  Fix:
--  Listen to StateChanged. When a forced-replication state fires,
--  wait 0.2s (enough time for the engine to move the HRP AND for
--  the replication packet to actually flush), then re-snapshot.
--  task.defer was too short (1 frame ~16ms) — physics + replication
--  needs more time to settle, especially for seat welds.
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

local function syncServerPos()
    -- Wait long enough for the engine to finish moving the HRP
    -- and for the replication packet to flush to the server.
    task.delay(0.2, function()
        if not State.desyncActive then return end
        local hrp = getLocalHRP()
        if hrp then
            State.frozenServerPos = hrp.Position
        end
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
            -- Roblox just force-pushed our position to the server.
            -- Re-snapshot after physics settle so our marker stays accurate.
            syncServerPos()
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
--  DELAYED DESYNC — LAG MIMIC LOOP
--
--  Previous approach was broken because the heartbeat loop and the
--  timed window were fighting each other:
--    heartbeat fires every ~16ms → sets fflag False
--    window phase sets fflag True → heartbeat immediately overrides it
--    net result: window never actually stays open long enough
--
--  Correct approach:
--    1. Heartbeat does setfflag False ONLY when delayedWindowOpen == false.
--    2. A separate task.spawn loop owns the window timing:
--         - wait N seconds
--         - set delayedWindowOpen = true  (heartbeat backs off)
--         - set fflag True                (replication opens)
--         - wait 0.2s                     (server gets the packet)
--         - snapshot frozenServerPos      (visualizer updates)
--         - set fflag False               (lock it again)
--         - set delayedWindowOpen = false (heartbeat resumes guarding)
--         - repeat
--
--  The heartbeat and the loop never conflict. The window stays open
--  for the full 0.2s every time, giving the server a clean snapshot.
-- ================================================================
local delayedLoopActive = false

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true

    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            task.wait(interval)

            if not State.desyncActive or State.desyncMode ~= 'delayed' then break end

            -- Open window: tell heartbeat to back off, then enable replication
            State.delayedWindowOpen = true
            pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'True') end)

            -- Let the engine send the position packet (~3-4 physics frames)
            task.wait(0.2)

            -- Snapshot what the server just received
            local hrp = getLocalHRP()
            if hrp then State.frozenServerPos = hrp.Position end

            -- Close window: lock replication off, resume heartbeat guard
            pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)
            State.delayedWindowOpen = false
        end

        delayedLoopActive = false
    end)
end

local function stopDelayedLoop()
    -- Setting desyncMode away from 'delayed' or desyncActive = false
    -- causes the loop's while-condition to exit naturally next iteration.
    State.delayedWindowOpen = false
    delayedLoopActive = false
end

-- ================================================================
--  DESYNC ENABLE / DISABLE
-- ================================================================
local function pauseDesync()
    State.desyncActive      = false
    State.frozenServerPos   = nil
    State.delayedWindowOpen = false
    stopDelayedLoop()
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'True') end)
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
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)

    if State.desyncMode == 'delayed' then
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        startDelayedLoop()
        Library:Notify(('Lag Desync ON — server updates every %.0fs'):format(iv))
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
--
--  Sets up the master heartbeat that drives replication locking.
--
--  INSTANT MODE:
--    setfflag False every single heartbeat. Server permanently frozen.
--    (Unchanged from original.)
--
--  DELAYED MODE:
--    Heartbeat sets fflag False every frame UNLESS delayedWindowOpen
--    is true (meaning the lag-loop owns the fflag right now).
--    The actual timed window is handled by startDelayedLoop() above.
-- ================================================================
local function initDesync()
    if not setfflag then Library:Notify('setfflag not available in this executor'); return end
    if desyncInitialized   then Library:Notify('Already initialized — use the Enable toggle'); return end
    if not getLocalHRP()   then Library:Notify('No character — spawn in first'); return end
    desyncInitialized = true

    State.desyncHbConn = RunService.Heartbeat:Connect(function()
        if not State.desyncActive then return end

        if State.desyncMode == 'instant' then
            -- Original behaviour: lock every frame
            pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)

        elseif State.desyncMode == 'delayed' then
            -- Only lock when the lag-loop isn't mid-window
            if not State.delayedWindowOpen then
                pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)
            end
            -- (When delayedWindowOpen == true the lag-loop owns the fflag)
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
        local wasDelayed = State.desyncMode == 'delayed'
        State.desyncMode = (v == 'Instant') and 'instant' or 'delayed'

        if State.desyncActive then
            if State.desyncMode == 'instant' then
                -- Kill the delayed loop, resume instant locking
                stopDelayedLoop()
                pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'False') end)
                Library:Notify('Switched → Instant Desync')
            else
                -- Start the delayed loop from scratch
                State.delayedWindowOpen = false
                startDelayedLoop()
                local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
                Library:Notify(('Switched → Lag Mimic (%.0fs interval)'):format(iv))
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
    -- The delayed loop reads this live on each task.wait() call.
    -- Changing the slider takes effect on the very next cycle.
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
