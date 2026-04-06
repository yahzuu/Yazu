-- ================================================================
--  features/misc.lua
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
local function getLocalHum()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildWhichIsA('Humanoid')
end

-- ================================================================
--  EXECUTOR CAPABILITY FLAGS
-- ================================================================
local Exec = {
    hasSetfflag   = type(setfflag)        == 'function',
    hasGetfflag   = type(getfflag)        == 'function',
    hasHookMeta   = type(hookmetamethod)  == 'function',
    hasGetRawMeta = type(getrawmetatable) == 'function',
}

-- ================================================================
--  FFLAG COMPAT CHECK  (NextGenReplicatorEnabledWrite4 only)
-- ================================================================
State.replicatorCompatible = false

local function runCompatCheck()
    local flag = 'NextGenReplicatorEnabledWrite4'

    if not Exec.hasSetfflag then
        Library:Notify('[COMPAT] setfflag missing — executor unsupported')
        print('[COMPAT] setfflag not found')
        return false
    end

    local readOk, current = false, nil
    if Exec.hasGetfflag then
        readOk, current = pcall(function() return getfflag(flag) end)
    else
        current = 'True'; readOk = true
    end

    if not readOk or current == nil then
        Library:Notify('[COMPAT] ' .. flag .. ' — read failed')
        State.replicatorCompatible = false; return false
    end

    local writeOk = pcall(function() setfflag(flag, tostring(current)) end)
    if not writeOk then
        Library:Notify('[COMPAT] ' .. flag .. ' — write rejected')
        State.replicatorCompatible = false; return false
    end

    if Exec.hasGetfflag then
        local verOk, after = pcall(function() return getfflag(flag) end)
        if not verOk or tostring(after) ~= tostring(current) then
            Library:Notify('[COMPAT] ' .. flag .. ' — write did not apply')
            State.replicatorCompatible = false; return false
        end
    end

    State.replicatorCompatible = true
    Library:Notify('[COMPAT] NextGenReplicatorEnabledWrite4 — COMPATIBLE ✓')
    print('[COMPAT] ' .. flag .. ' | verified | current=' .. tostring(current))
    print('[COMPAT] hookmetamethod  : ' .. tostring(Exec.hasHookMeta))
    print('[COMPAT] getrawmetatable : ' .. tostring(Exec.hasGetRawMeta))
    return true
end

-- ================================================================
--  MASTER REPLICATOR CONTROLLER
--
--  THE FIX for the stuck-frozen bug:
--  Previously, turning desync OFF called setReplicator(true) once
--  and that was it. If the engine internally reset the flag, nothing
--  was there to push it back. Now a SINGLE master heartbeat runs
--  always and actively maintains whichever state we want, every frame.
--  replicationTarget = true  → heartbeat keeps replication OPEN
--  replicationTarget = false → heartbeat keeps replication CLOSED
--  No more one-shot calls. The heartbeat is the single source of truth.
-- ================================================================
local replicationTarget = true    -- start open (normal state)
local lastFlagState     = nil
local burstWindowOpen   = false   -- delayed loop owns fflag
local forceSyncActive   = false   -- state-change sync owns fflag
local passiveLagOwned   = false   -- passive lag owns fflag

-- These two own-flags gate the master loop
local function replicatorIsOwned()
    return burstWindowOpen or forceSyncActive or passiveLagOwned
end

-- Master controller — always running
RunService.Heartbeat:Connect(function()
    if not State.replicatorCompatible then return end
    if replicatorIsOwned() then return end
    local val = replicationTarget and 'True' or 'False'
    if lastFlagState == val then return end
    lastFlagState = val
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', val) end)
end)

-- Convenience: request a target state
local function wantReplication(open)
    replicationTarget = open
    lastFlagState     = nil   -- force master loop to apply it next frame
end

-- For burst operations that need to bypass the master loop
local function setReplicatorDirect(enabled)
    if not State.replicatorCompatible then return end
    local val = enabled and 'True' or 'False'
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

local clientPart, clientLbl = makePart(Color3.fromRGB(60,  255, 100), 'CLIENT')
local serverPart, serverLbl = makePart(Color3.fromRGB(255,  50,  50), 'SERVER')
local baitPart,   baitLbl   = makePart(Color3.fromRGB(255, 165,   0), 'BAIT')
local ghostPart,  ghostLbl  = makePart(Color3.fromRGB(180,  80, 255), 'GHOST')
local vizConn = nil

-- ================================================================
--  SERVER ROOT PART — FORCED STATE SYNC
-- ================================================================
local charStateConn = nil
local syncQueued    = false

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
        while burstWindowOpen do RunService.Heartbeat:Wait() end
        forceSyncActive = true
        setReplicatorDirect(true)
        for _ = 1, 5 do RunService.Heartbeat:Wait() end
        local hrp = getLocalHRP()
        if hrp then State.frozenServerPos = hrp.Position end
        setReplicatorDirect(false)
        forceSyncActive = false; syncQueued = false
    end)
end

local function connectCharacterStateTracking(char)
    if charStateConn then charStateConn:Disconnect(); charStateConn = nil end
    if not char then return end
    local hum = char:FindFirstChildWhichIsA('Humanoid')
    if not hum then
        local wc; wc = char.ChildAdded:Connect(function(child)
            if child:IsA('Humanoid') then wc:Disconnect(); connectCharacterStateTracking(char) end
        end)
        return
    end
    charStateConn = hum.StateChanged:Connect(function(_, newState)
        if not State.desyncActive then return end
        if FORCED_REPLICATION_STATES[newState] then forceSyncServerPos() end
    end)
end

-- ================================================================
--  VISUALIZER
-- ================================================================
local function startViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = workspace; serverPart.Parent = workspace
    if State.baitActive   then baitPart.Parent  = workspace end
    if State.ghostActive  then ghostPart.Parent = workspace end

    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame

        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
            local dist = math.floor((hrp.Position - State.frozenServerPos).Magnitude)
            local tag  = State.desyncMode == 'delayed' and '[LAG] '
                      or State.desyncMode == 'ghost'   and '[GHOST] ' or ''
            serverLbl.Text = 'SERVER ' .. tag .. dist .. 'm'
            clientLbl.Text = 'CLIENT'
        else
            serverPart.CFrame = hrp.CFrame
            serverLbl.Text = 'SERVER (synced)'; clientLbl.Text = 'CLIENT'
        end

        if State.baitActive and State.baitPos then
            baitPart.CFrame = CFrame.new(State.baitPos)
            baitLbl.Text = 'BAIT  ' .. math.floor((hrp.Position - State.baitPos).Magnitude) .. 'm'
        end

        if State.ghostActive and State.ghostPos then
            ghostPart.CFrame = CFrame.new(State.ghostPos)
            ghostLbl.Text = 'GHOST  ' .. math.floor((hrp.Position - State.ghostPos).Magnitude) .. 'm'
        end
    end)
    connectCharacterStateTracking(LocalPlayer.Character)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil; serverPart.Parent = nil
    baitPart.Parent   = nil; ghostPart.Parent  = nil
end

-- ================================================================
--  DESYNC MODES
--  State.desyncMode: 'instant' | 'delayed' | 'ghost'
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'

-- ── Delayed burst loop ────────────────────────────────────────────
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
            while forceSyncActive do RunService.Heartbeat:Wait() end
            burstWindowOpen = true
            setReplicatorDirect(true)
            for _ = 1, 3 do RunService.Heartbeat:Wait() end
            local hrp = getLocalHRP()
            if hrp then State.frozenServerPos = hrp.Position end
            setReplicatorDirect(false)
            burstWindowOpen = false
        end
        delayedLoopActive = false
    end)
end

local function stopDelayedLoop()
    burstWindowOpen = false; delayedLoopActive = false
end

-- ── CFrame Ghost loop (as desync mode + standalone) ──────────────
--
--  How it works:
--  Every N heartbeat frames we rapidly alternate the HRP CFrame
--  between your real current position and a stored ghost position.
--  The server receives conflicting snapshots and cannot resolve a
--  clean position — it sees you flickering between two locations.
--  As a desync mode: ghostPos is frozen at activation point.
--  As standalone: ghostPos updates to trail behind you by ~1s,
--  creating a persistent shadow position the server oscillates on.
-- ================================================================
State.ghostActive = false
State.ghostPos    = nil
local ghostLoopActive    = false
local ghostStandalonePos = nil   -- trailing position for standalone mode

local GHOST_FLICKER_FRAMES = 2   -- how many frames to hold each position
local GHOST_CYCLE_FRAMES   = 6   -- total frames per full cycle

local function startGhostLoop(asDesyncMode)
    if ghostLoopActive then return end
    ghostLoopActive = true
    State.ghostActive = true

    task.spawn(function()
        local frame = 0
        while ghostLoopActive do
            RunService.Heartbeat:Wait()
            if not ghostLoopActive then break end

            local hrp = getLocalHRP(); if not hrp then continue end
            frame = frame + 1

            -- Update trailing ghost pos in standalone mode every ~1s
            if not asDesyncMode then
                if frame % 60 == 0 then
                    ghostStandalonePos = hrp.Position
                end
                State.ghostPos = ghostStandalonePos or hrp.Position
            else
                -- In desync mode, ghost pos is the frozen server pos
                State.ghostPos = State.frozenServerPos or hrp.Position
            end

            if State.ghostPos then
                local phase = frame % GHOST_CYCLE_FRAMES
                if phase < GHOST_FLICKER_FRAMES then
                    -- Phase A: let replication see real position
                    if asDesyncMode then
                        -- In desync mode we own the fflag — briefly open
                        while forceSyncActive do RunService.Heartbeat:Wait() end
                        burstWindowOpen = true
                        setReplicatorDirect(true)
                        RunService.Heartbeat:Wait()
                        setReplicatorDirect(false)
                        burstWindowOpen = false
                    end
                    -- Move HRP to real position (already there, just let it replicate)
                else
                    -- Phase B: snap HRP to ghost pos for a frame
                    -- Server gets this as a conflicting update
                    local savedCF = hrp.CFrame
                    hrp.CFrame = CFrame.new(State.ghostPos)
                    RunService.Heartbeat:Wait()
                    hrp.CFrame = savedCF
                end
            end
        end
        State.ghostActive   = false
        State.ghostPos      = nil
        ghostStandalonePos  = nil
        ghostLoopActive     = false
        ghostPart.Parent    = nil
    end)
end

local function stopGhostLoop()
    ghostLoopActive = false
end

-- ================================================================
--  PASSIVE LAG — PURE API APPROACH (no fflags)
--
--  Mechanism: every N heartbeat frames, take a snapshot of the
--  HRP position. Between snapshots, lock the HRP CFrame to that
--  snapshot position for one frame to inject a "stale" position
--  packet into the replication stream. The rest of the time HRP
--  moves normally. Net effect: server receives position updates
--  that trail behind where you actually are — identical to high
--  latency from the server's perspective.
--
--  Indicator: tracks how many injected stale frames happened vs
--  real frames in the last second and displays as an "effective
--  lag %" so you can see whether it's actually doing anything.
-- ================================================================
State.passiveLagActive = false
local passiveLagConn   = nil
local passiveLagLabel  = nil   -- set after UI is built

local passiveLagStats = {
    injectedFrames = 0,
    totalFrames    = 0,
    lastReset      = os.clock(),
    effectivePct   = 0,
}

local function startPassiveLag()
    if passiveLagConn then passiveLagConn:Disconnect(); passiveLagConn = nil end
    State.passiveLagActive = true

    local snapshotPos    = nil
    local frameCount     = 0

    passiveLagConn = RunService.Heartbeat:Connect(function()
        if not State.passiveLagActive then return end
        local hrp = getLocalHRP(); if not hrp then return end

        local throttle = Options.PassiveLagThrottle and Options.PassiveLagThrottle.Value or 10
        -- throttle = how many real frames between stale injections
        -- lower = more lag-like, higher = closer to normal

        frameCount = frameCount + 1
        passiveLagStats.totalFrames = passiveLagStats.totalFrames + 1

        -- Take a new position snapshot every `throttle` frames
        if frameCount % throttle == 0 or snapshotPos == nil then
            snapshotPos = hrp.Position
        end

        -- Every other frame, inject the stale snapshot position
        -- This sends a "you were here" packet to the server
        if frameCount % 2 == 1 and snapshotPos then
            local realCF = hrp.CFrame
            hrp.CFrame   = CFrame.new(snapshotPos) * (realCF - realCF.Position)
            -- One physics step with stale pos, then snap back
            task.defer(function()
                if hrp and hrp.Parent then
                    hrp.CFrame = realCF
                end
            end)
            passiveLagStats.injectedFrames = passiveLagStats.injectedFrames + 1
        end

        -- Update indicator every second
        local now = os.clock()
        if now - passiveLagStats.lastReset >= 1 then
            local pct = 0
            if passiveLagStats.totalFrames > 0 then
                pct = math.floor((passiveLagStats.injectedFrames / passiveLagStats.totalFrames) * 100)
            end
            passiveLagStats.effectivePct   = pct
            passiveLagStats.injectedFrames = 0
            passiveLagStats.totalFrames    = 0
            passiveLagStats.lastReset      = now
            -- Update UI label if it exists
            if passiveLagLabel then
                passiveLagLabel:SetText('Effective lag injection: ' .. pct .. '%  |  ' ..
                    (pct > 30 and 'ACTIVE ✓' or 'low — increase throttle'))
            end
        end
    end)
end

local function stopPassiveLag()
    State.passiveLagActive = false
    if passiveLagConn then passiveLagConn:Disconnect(); passiveLagConn = nil end
    passiveLagStats.effectivePct   = 0
    passiveLagStats.injectedFrames = 0
    passiveLagStats.totalFrames    = 0
    if passiveLagLabel then passiveLagLabel:SetText('Passive Lag OFF') end
end

-- ================================================================
--  NETWORK OWNERSHIP MANIPULATION
--
--  `BasePart:SetNetworkOwner()` is server-only in normal scripts.
--  Some executors expose it via the raw Roblox C++ binding or via
--  syn.set_thread_identity. We attempt it and report honestly.
--  If it works: rhythmically releasing and reclaiming ownership
--  of your HRP forces the server to briefly take physics control,
--  then give it back — creates natural-looking ownership handoffs
--  that confuse position authority.
-- ================================================================
State.netOwnActive  = false
local netOwnConn    = nil
local netOwnWorking = false   -- whether SetNetworkOwner actually did anything

local function testNetworkOwnership()
    local hrp = getLocalHRP()
    if not hrp then Library:Notify('No character'); return end

    local ok = pcall(function()
        hrp:SetNetworkOwner(LocalPlayer)
    end)

    if ok then
        netOwnWorking = true
        Library:Notify('SetNetworkOwner — WORKS on this executor ✓')
        print('[NETOWNER] SetNetworkOwner is callable')
    else
        netOwnWorking = false
        Library:Notify('SetNetworkOwner — not available on this executor ✗')
        print('[NETOWNER] SetNetworkOwner pcall failed — server-only')
    end
end

local function startNetworkOwnerCycle()
    if not netOwnWorking then
        Library:Notify('Run ownership test first — may not be supported')
    end
    if netOwnConn then netOwnConn:Disconnect(); netOwnConn = nil end
    State.netOwnActive = true
    local frame = 0

    netOwnConn = RunService.Heartbeat:Connect(function()
        if not State.netOwnActive then return end
        local hrp = getLocalHRP(); if not hrp then return end
        frame = frame + 1

        local cycleLen = Options.NetOwnCycleFrames and Options.NetOwnCycleFrames.Value or 20
        local phase    = frame % cycleLen

        if phase == 0 then
            -- Release ownership → server briefly owns physics
            pcall(function() hrp:SetNetworkOwner(nil) end)
        elseif phase == math.floor(cycleLen / 2) then
            -- Reclaim ownership → we own physics again
            pcall(function() hrp:SetNetworkOwner(LocalPlayer) end)
        end
    end)
    Library:Notify('Network ownership cycling ON')
end

local function stopNetworkOwnerCycle()
    State.netOwnActive = false
    if netOwnConn then netOwnConn:Disconnect(); netOwnConn = nil end
    -- Restore our ownership
    local hrp = getLocalHRP()
    if hrp then pcall(function() hrp:SetNetworkOwner(LocalPlayer) end) end
    Library:Notify('Network ownership cycling OFF')
end

-- ================================================================
--  CHARACTER STATE SPOOFER
--
--  Humanoid:ChangeState() replicates to the server. By calling it
--  with a fake state while you're in a different state client-side,
--  the server thinks your character is in a different physical state
--  than it actually is. Useful for:
--    Seated  — server thinks you're sitting (ignores movement)
--    Ragdoll — server treats you as physics ragdoll
--    Dead    — server-side death state without actually dying
--  The spoof is pulsed every N seconds to keep it active since
--  the humanoid will naturally transition out of fake states.
-- ================================================================
State.stateSpoofActive = false
local stateSpoofConn   = nil

local STATE_MAP = {
    ['Seated']      = Enum.HumanoidStateType.Seated,
    ['Ragdoll']     = Enum.HumanoidStateType.Ragdoll,
    ['FallingDown'] = Enum.HumanoidStateType.FallingDown,
    ['Jumping']     = Enum.HumanoidStateType.Jumping,
    ['Swimming']    = Enum.HumanoidStateType.Swimming,
    ['Climbing']    = Enum.HumanoidStateType.Climbing,
}

local function startStateSpoof(stateName)
    if stateSpoofConn then stateSpoofConn:Disconnect(); stateSpoofConn = nil end
    local targetState = STATE_MAP[stateName]
    if not targetState then Library:Notify('Unknown state: ' .. tostring(stateName)); return end

    State.stateSpoofActive = true
    local interval = Options.StateSpoofInterval and Options.StateSpoofInterval.Value or 2

    stateSpoofConn = RunService.Heartbeat:Connect(function()
        if not State.stateSpoofActive then return end
        local hum = getLocalHum(); if not hum then return end
        -- Re-pulse the fake state every `interval` seconds
        -- task.wait inside heartbeat would block, so we use os.clock
    end)

    -- Use a separate loop for the timed pulse
    task.spawn(function()
        while State.stateSpoofActive do
            local hum = getLocalHum()
            if hum then
                pcall(function() hum:ChangeState(targetState) end)
            end
            task.wait(Options.StateSpoofInterval and Options.StateSpoofInterval.Value or 2)
        end
    end)

    Library:Notify('State Spoof ON — sending fake state: ' .. stateName)
end

local function stopStateSpoof()
    State.stateSpoofActive = false
    if stateSpoofConn then stateSpoofConn:Disconnect(); stateSpoofConn = nil end
    -- Restore running state
    local hum = getLocalHum()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end) end
    Library:Notify('State Spoof OFF — restored Running state')
end

-- ================================================================
--  HIT VALIDATION CONFUSION
-- ================================================================
State.hitConfusionArmed    = false
State.hitConfusionFrozenAt = nil
local hitConfusionConn     = nil
local HIT_CONFUSION_RANGE  = 60

local function startHitConfusion()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    hitConfusionConn = RunService.Heartbeat:Connect(function()
        if not State.hitConfusionArmed then return end
        local hrp = getLocalHRP(); if not hrp then return end
        local inRange = false
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer and p.Character then
                local theirHRP = p.Character:FindFirstChild('HumanoidRootPart')
                if theirHRP and (hrp.Position - theirHRP.Position).Magnitude <= HIT_CONFUSION_RANGE then
                    inRange = true; break
                end
            end
        end
        if inRange then
            if not State.desyncActive then
                if not State.hitConfusionFrozenAt then
                    State.hitConfusionFrozenAt = hrp.Position
                end
                if not replicatorIsOwned() then
                    wantReplication(false)
                end
            end
        else
            if State.hitConfusionFrozenAt and not State.desyncActive then
                State.hitConfusionFrozenAt = nil
                if not replicatorIsOwned() then wantReplication(true) end
            end
        end
    end)
end

local function stopHitConfusion()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    State.hitConfusionArmed    = false
    State.hitConfusionFrozenAt = nil
    if not State.desyncActive then wantReplication(true) end
end

-- ================================================================
--  BAIT POSITIONING
-- ================================================================
State.baitActive = false
State.baitPos    = nil

local function stampBaitPosition()
    if not State.replicatorCompatible then Library:Notify('Run Compat Check first!'); return end
    local hrp = getLocalHRP(); if not hrp then Library:Notify('No character!'); return end
    task.spawn(function()
        burstWindowOpen = true
        setReplicatorDirect(true)
        for _ = 1, 4 do RunService.Heartbeat:Wait() end
        State.baitPos    = hrp.Position
        State.baitActive = true
        if Toggles.DesyncVisualizer and Toggles.DesyncVisualizer.Value then
            baitPart.Parent = workspace
        end
        setReplicatorDirect(false)
        burstWindowOpen = false
        wantReplication(false)   -- lock: server stays at bait pos
        Library:Notify('Bait stamped — walk away freely')
    end)
end

local function clearBait()
    State.baitActive = false; State.baitPos = nil
    baitPart.Parent = nil
    if not State.desyncActive and not State.hitConfusionArmed then
        wantReplication(true)
    end
    Library:Notify('Bait cleared')
end

-- ================================================================
--  PANIC
-- ================================================================
local function triggerPanic()
    State.desyncActive         = false
    State.frozenServerPos      = nil
    State.baitActive           = false
    State.baitPos              = nil
    State.hitConfusionArmed    = false
    State.hitConfusionFrozenAt = nil
    State.ghostActive          = false
    State.ghostPos             = nil
    State.netOwnActive         = false
    State.stateSpoofActive     = false
    State.passiveLagActive     = false
    burstWindowOpen            = false
    forceSyncActive            = false
    passiveLagOwned            = false

    stopDelayedLoop()
    stopGhostLoop()
    stopPassiveLag()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    if netOwnConn       then netOwnConn:Disconnect();       netOwnConn       = nil end
    if stateSpoofConn   then stateSpoofConn:Disconnect();   stateSpoofConn   = nil end

    -- Restore network ownership
    local hrp = getLocalHRP()
    if hrp then pcall(function() hrp:SetNetworkOwner(LocalPlayer) end) end

    -- Restore humanoid state
    local hum = getLocalHum()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end) end

    -- Tell master loop: open replication
    wantReplication(true)

    task.defer(function()
        for _, key in ipairs({
            'DesyncEnabled','HitConfusionEnabled','BaitEnabled',
            'GhostStandaloneEnabled','NetOwnEnabled',
            'StateSpoofEnabled','PassiveLagEnabled'
        }) do
            if Toggles[key] then Toggles[key]:SetValue(false) end
        end
    end)

    Library:Notify('PANIC — all systems reset')
end

-- ================================================================
--  TOUCH DETECTION
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
                    State.desyncActive    = false
                    State.frozenServerPos = nil
                    stopDelayedLoop(); stopGhostLoop()
                    wantReplication(true)
                    Toggles.DesyncEnabled:SetValue(false)
                    Library:Notify('Desync OFF — touched player')
                end); return
            end
        end
    end)
end

-- ================================================================
--  INIT DESYNC
-- ================================================================
local function initDesync()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!'); return
    end
    if desyncInitialized then Library:Notify('Already initialized'); return end
    if not getLocalHRP() then Library:Notify('No character'); return end
    desyncInitialized = true
    Library:Notify('Desync ready — toggle to enable')
    -- Note: the master RunService.Heartbeat loop (defined at top)
    -- is already handling the fflag maintenance. No extra loop needed.
end

local function pauseDesync()
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen = false; forceSyncActive = false; syncQueued = false
    stopDelayedLoop(); stopGhostLoop()
    wantReplication(true)   -- master loop will maintain this open
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
    end
    local hrp = getLocalHRP()
    if not hrp then
        Library:Notify('No character!')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
    end
    State.frozenServerPos = hrp.Position; State.desyncActive = true
    burstWindowOpen = false; forceSyncActive = false; syncQueued = false
    wantReplication(false)   -- master loop locks replication off

    if State.desyncMode == 'delayed' then
        startDelayedLoop()
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        Library:Notify(('Lag Desync ON — bursts every ~%.0fs'):format(iv))
    elseif State.desyncMode == 'ghost' then
        startGhostLoop(true)
        Library:Notify('Ghost Desync ON — server sees flickering position')
    else
        Library:Notify('Instant Desync ON')
    end
end

-- ================================================================
--  CHARACTER ADDED
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    if State.desyncHbConn then State.desyncHbConn:Disconnect(); State.desyncHbConn = nil end
    desyncInitialized     = false
    State.desyncActive    = false; State.frozenServerPos   = nil
    State.baitActive      = false; State.baitPos           = nil
    State.ghostActive     = false; State.ghostPos          = nil
    State.hitConfusionFrozenAt = nil; State.netOwnActive   = false
    State.stateSpoofActive = false; State.passiveLagActive = false
    burstWindowOpen = false; forceSyncActive = false
    syncQueued = false; passiveLagOwned = false
    stopDelayedLoop(); stopGhostLoop(); stopPassiveLag()
    baitPart.Parent = nil; ghostPart.Parent = nil
    wantReplication(true)
    stopViz()
    task.defer(function()
        for _, key in ipairs({
            'DesyncEnabled','HitConfusionEnabled','BaitEnabled',
            'GhostStandaloneEnabled','NetOwnEnabled',
            'StateSpoofEnabled','PassiveLagEnabled'
        }) do
            if Toggles[key] then Toggles[key]:SetValue(false) end
        end
    end)
    task.wait(1)
    connectTouchDetection()
    connectCharacterStateTracking(char)
    if State.hitConfusionArmed then startHitConfusion() end
end)

if LocalPlayer.Character then
    connectTouchDetection()
    connectCharacterStateTracking(LocalPlayer.Character)
end

-- ================================================================
--  UI — MISC TAB
-- ================================================================
local CompatGrp    = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp    = Tabs.Misc:AddLeftGroupbox('Desync')
local CombatGrp    = Tabs.Misc:AddLeftGroupbox('Combat')
local PassiveLagGrp = Tabs.Misc:AddLeftGroupbox('Passive Lag')
local NetGrp       = Tabs.Misc:AddLeftGroupbox('Network & State')
local SpinGrp      = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp      = Tabs.Misc:AddRightGroupbox('Misc')

-- ── Compat + Panic ────────────────────────────────────────────────
CompatGrp:AddLabel('Tests NextGenReplicatorEnabledWrite4.\nAlso logs executor capabilities to console.')
CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })
CompatGrp:AddLabel('Panic Key — resets all systems instantly.')
CompatGrp:AddLabel('Panic Key'):AddKeyPicker('PanicKey', {
    Default = 'End', Text = 'Panic Key', Mode = 'Toggle',
    Callback = function(v) if v then triggerPanic(); Options.PanicKey:SetValue(false) end end,
})

-- ── Desync ────────────────────────────────────────────────────────
DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Run compat check first.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)', 'Ghost (Flicker)' },
    Callback = function(v)
        local prev = State.desyncMode
        if v == 'Instant'              then State.desyncMode = 'instant'
        elseif v == 'Delayed (Lag Mimic)' then State.desyncMode = 'delayed'
        elseif v == 'Ghost (Flicker)'  then State.desyncMode = 'ghost'
        end
        if State.desyncActive then
            if prev == 'delayed' then stopDelayedLoop() end
            if prev == 'ghost'   then stopGhostLoop() end
            if State.desyncMode == 'delayed' then
                startDelayedLoop()
                Library:Notify('Switched → Lag Mimic')
            elseif State.desyncMode == 'ghost' then
                startGhostLoop(true)
                Library:Notify('Switched → Ghost Flicker')
            else
                wantReplication(false)
                Library:Notify('Switched → Instant')
            end
        end
    end,
})

DesyncGrp:AddSlider('DelayedDesyncInterval', {
    Text = 'Lag Interval (seconds)', Default = 5, Min = 1, Max = 30, Rounding = 0,
})

DesyncGrp:AddToggle('DesyncEnabled', {
    Text = 'Enable Desync', Default = false,
    Callback = function(v)
        if v then
            if not desyncInitialized then
                Library:Notify('Initialize first!')
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
    Text = 'Show 3D Visualizer', Default = false,
    Callback = function(v) if v then startViz() else stopViz() end end,
})
DesyncGrp:AddToggle('DesyncAutoOff', { Text = 'Auto-Off on Player Contact', Default = true })

-- ── Ghost Standalone ─────────────────────────────────────────────
DesyncGrp:AddToggle('GhostStandaloneEnabled', {
    Text = 'Ghost Mode (standalone)', Default = false,
    Callback = function(v)
        if v then
            if State.desyncActive then
                Library:Notify('Disable main desync first to use standalone ghost')
                task.defer(function() Toggles.GhostStandaloneEnabled:SetValue(false) end); return
            end
            ghostStandalonePos = nil
            local hrp = getLocalHRP()
            if hrp then ghostStandalonePos = hrp.Position end
            startGhostLoop(false)
            if Toggles.DesyncVisualizer and Toggles.DesyncVisualizer.Value then
                ghostPart.Parent = workspace
            end
            Library:Notify('Ghost standalone ON — server sees flickering shadow')
        else
            stopGhostLoop()
            ghostPart.Parent = nil
            Library:Notify('Ghost standalone OFF')
        end
    end,
})
DesyncGrp:AddLabel('Standalone ghost trails ~1s behind you.\nServer sees you flicker between real and shadow pos.')

-- ── Combat ────────────────────────────────────────────────────────
CombatGrp:AddToggle('HitConfusionEnabled', {
    Text = 'Hit Validation Confusion', Default = false,
    Callback = function(v)
        if v then
            if not State.replicatorCompatible then
                Library:Notify('Run Compat Check first!')
                task.defer(function() Toggles.HitConfusionEnabled:SetValue(false) end); return
            end
            State.hitConfusionArmed = true
            startHitConfusion()
            Library:Notify('Hit Confusion ARMED (' .. HIT_CONFUSION_RANGE .. ' stud range)')
        else
            stopHitConfusion()
        end
    end,
})
CombatGrp:AddLabel('Freezes server pos when enemy is in range.')

CombatGrp:AddToggle('BaitEnabled', {
    Text = 'Bait Mode', Default = false,
    Callback = function(v)
        if v then
            if not State.replicatorCompatible then
                Library:Notify('Run Compat Check first!')
                task.defer(function() Toggles.BaitEnabled:SetValue(false) end); return
            end
            stampBaitPosition()
        else
            clearBait()
        end
    end,
})
CombatGrp:AddButton({ Text = 'Re-Stamp Bait Here', Func = function()
    if State.baitActive then clearBait(); task.wait(0.1); stampBaitPosition()
    else Library:Notify('Enable Bait Mode first') end
end })

-- ── Passive Lag ───────────────────────────────────────────────────
PassiveLagGrp:AddToggle('PassiveLagEnabled', {
    Text = 'Enable Passive Lag', Default = false,
    Callback = function(v)
        if v then startPassiveLag() else stopPassiveLag() end
    end,
})
PassiveLagGrp:AddSlider('PassiveLagThrottle', {
    Text = 'Throttle (frames between snapshots)',
    Default = 10, Min = 2, Max = 60, Rounding = 0,
    Callback = function()
        if State.passiveLagActive then stopPassiveLag(); startPassiveLag() end
    end,
})
-- Store label ref so the loop can update it
passiveLagLabel = PassiveLagGrp:AddLabel('Passive Lag OFF')
PassiveLagGrp:AddLabel('No fflags used. Lower throttle = more stale\ninjections = more lag-like server view.')

-- ── Network & State ───────────────────────────────────────────────
NetGrp:AddButton({ Text = 'Test Network Ownership', Func = testNetworkOwnership })
NetGrp:AddLabel('Tests if SetNetworkOwner is callable.\nCheck console for result.')

NetGrp:AddToggle('NetOwnEnabled', {
    Text = 'Network Ownership Cycling', Default = false,
    Callback = function(v)
        if v then startNetworkOwnerCycle() else stopNetworkOwnerCycle() end
    end,
})
NetGrp:AddSlider('NetOwnCycleFrames', {
    Text = 'Cycle Length (frames)', Default = 20, Min = 5, Max = 60, Rounding = 0,
})
NetGrp:AddLabel('Cycles ownership between client + server.\nMay not work — test first.')

NetGrp:AddDropdown('StateSpoofState', {
    Text = 'Spoof State', Default = 'Seated',
    Values = { 'Seated', 'Ragdoll', 'FallingDown', 'Jumping', 'Swimming', 'Climbing' },
})
NetGrp:AddSlider('StateSpoofInterval', {
    Text = 'Re-pulse interval (seconds)', Default = 2, Min = 0.5, Max = 10, Rounding = 1,
})
NetGrp:AddToggle('StateSpoofEnabled', {
    Text = 'Enable State Spoofer', Default = false,
    Callback = function(v)
        if v then
            local stateName = Options.StateSpoofState and Options.StateSpoofState.Value or 'Seated'
            startStateSpoof(stateName)
        else
            stopStateSpoof()
        end
    end,
})
NetGrp:AddLabel('Sends fake humanoid state to server\nwhile you move normally client-side.')

-- ── SpinBot ───────────────────────────────────────────────────────
SpinGrp:AddToggle('SpinBotEnabled',       { Text = 'Enable SpinBot', Default = false })
SpinGrp:AddLabel('Spin Key'):AddKeyPicker('SpinKey', { Default = 'None', Text = 'Spin Key', Mode = 'Hold' })
SpinGrp:AddToggle('OnePressSpinningMode', { Text = 'One-Press Mode', Default = false })
SpinGrp:AddSlider('SpinVelocity',         { Text = 'Spin Velocity', Default = 50, Min = 1, Max = 50, Rounding = 1 })
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
