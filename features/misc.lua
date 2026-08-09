-- ================================================================
--  features/misc.lua
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService  = Services.RunService
local Players     = Services.Players
local LocalPlayer = Services.LocalPlayer

local function getLocalHRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild('HumanoidRootPart')
end
local function getLocalHum()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildWhichIsA('Humanoid')
end

-- ================================================================
--  FFLAG COMPAT CHECK
--
--  FIXED: flag name typo 'NextGenReplictorEnabledWrite4' (missing 'a')
--  was causing compat to pass but desync to do nothing because the
--  two functions were writing to different flag names entirely.
--  Both now use the exact same constant to prevent this class of bug.
-- ================================================================
local REPLICATOR_FLAG = 'NextGenReplicatorEnabledWrite4'

State.replicatorCompatible = false

local function runCompatCheck()
    print('[COMPAT] Starting compatibility check for: ' .. REPLICATOR_FLAG)

    if type(setfflag) ~= 'function' then
        Library:Notify('[COMPAT] setfflag not available on this executor')
        print('[COMPAT] FAIL — setfflag is not a function')
        return false
    end
    print('[COMPAT] setfflag exists ✓')

    -- Save original value for restore (optional — only if getfflag available)
    local original = 'True'
    if type(getfflag) == 'function' then
        local ok, val = pcall(getfflag, REPLICATOR_FLAG)
        if ok and val ~= nil then
            original = tostring(val)
            print('[COMPAT] Current flag value: ' .. original)
        else
            print('[COMPAT] getfflag exists but read failed — using default restore value: True')
        end
    else
        print('[COMPAT] getfflag not available — skipping read, will restore to True')
    end

    -- Test write — the only real compatibility gate
    local writeOk = pcall(setfflag, REPLICATOR_FLAG, 'True')

    -- Restore original immediately regardless of result
    pcall(setfflag, REPLICATOR_FLAG, original)
    print('[COMPAT] Restored flag to: ' .. original)

    if not writeOk then
        Library:Notify('[COMPAT] Write failed — not compatible')
        print('[COMPAT] FAIL — setfflag call threw an error')
        State.replicatorCompatible = false
        return false
    end

    State.replicatorCompatible = true
    Library:Notify('[COMPAT] Compatible ✓ — ready to use desync features')
    print('[COMPAT] PASS — flag is writable')
    return true
end


local nullStrikeActive = false
local function runNullStrike()
    if not State.replicatorCompatible then return end
    print("[NULL STRIKE] Initializing Packet Flood...")
    
    task.spawn(function()
        while nullStrikeActive do
            -- Rapidly oscillate replication state and CFrame to congest the buffer
            setReplicatorDirect(true)
            local hrp = getLocalHRP()
            if hrp then
                for i = 1, 40 do -- Intensity of the strike
                    hrp.CFrame = hrp.CFrame * CFrame.new(0, math.random(-1,1)/5, 0)
                    setReplicatorDirect(not replicationTarget)
                    RunService.Heartbeat:Wait()
                end
            end
            setReplicatorDirect(false)
            task.wait(0.05) 
        end
        print("[NULL STRIKE] Stopped.")
    end)
end


-- ================================================================
--  MASTER REPLICATOR CONTROLLER
--
--  No caching. Writes every heartbeat frame.
--  replicationTarget is the single source of truth.
--  wantReplication(true/false) is the only public interface.
-- ================================================================
local replicationTarget = true
local burstWindowOpen   = false
local forceSyncActive   = false

local function replicatorIsOwned()   -- FIXED: was 'replicatorIs/owned' (syntax error)
    return burstWindowOpen or forceSyncActive
end

local function wantReplication(open)
    replicationTarget = open
    print('[REPLICATOR] Target set to: ' .. (open and 'OPEN' or 'CLOSED'))
end

local function setReplicatorDirect(enabled)
    if not State.replicatorCompatible then return end
    pcall(setfflag, REPLICATOR_FLAG, enabled and 'True' or 'False')
end

-- Master loop — no caching, always enforced
RunService.Heartbeat:Connect(function()
    if not State.replicatorCompatible then return end
    if replicatorIsOwned() then return end
    pcall(setfflag, REPLICATOR_FLAG, replicationTarget and 'True' or 'False')
end)

-- ================================================================
--  PART HELPERS
--  FIXED: 'InstanceInstance.new' → 'Instance.new'
-- ================================================================
local function makePart(col, label)
    local p = Instance.new('Part')
    p.Anchored = true; p.CanCollide = false; p.CastShadow = false
    p.Size = Vector3.new(2, 5, 1); p.Material = Enum.Material.Neon
    p.Color = col; p.Transparency = 0.4; p.Parent = nil
    local bb = Instance.new('BillboardGui', p)   -- FIXED: was InstanceInstance.new
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
    print('[SYNC] Forced state sync triggered — opening replication briefly')
    task.spawn(function()
        while burstWindowOpen do RunService.Heartbeat:Wait() end
        forceSyncActive = true
        setReplicatorDirect(true)
        for _ = 1, 5 do RunService.Heartbeat:Wait() end
        local hrp = getLocalHRP()
        if hrp then
            State.frozenServerPos = hrp.Position
            print('[SYNC] Server pos re-snapped to: ' .. tostring(State.frozenServerPos))
        end
        setReplicatorDirect(replicationTarget)
        forceSyncActive = false
        syncQueued      = false
        print('[SYNC] Force sync complete')
    end)
end

local function connectCharacterStateTracking(char)
    if charStateConn then charStateConn:Disconnect(); charStateConn = nil end
    if not char then return end
    local hum = char:FindFirstChildWhichIsA('Humanoid')
    if not hum then
        local wc; wc = char.ChildAdded:Connect(function(child)
            if child:IsA('Humanoid') then
                wc:Disconnect()
                connectCharacterStateTracking(char)
            end
        end)
        return
    end
    charStateConn = hum.StateChanged:Connect(function(_, newState)
        if not State.desyncActive then return end
        if FORCED_REPLICATION_STATES[newState] then
            print('[SYNC] State changed to ' .. tostring(newState) .. ' — triggering forced sync')
            forceSyncServerPos()
        end
    end)
    print('[SYNC] Character state tracking connected')
end

-- ================================================================
--  VISUALIZER
--  FIXED: 'State.frozen/ServerPos' → 'State.frozenServerPos'
-- ================================================================
local function startViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = workspace
    serverPart.Parent = workspace
    if State.baitActive then baitPart.Parent = workspace end

    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame

        if State.desyncActive and State.frozenServerPos then   -- FIXED: was 'frozen/ServerPos'
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
            local dist = math.floor((hrp.Position - State.frozenServerPos).Magnitude)
            local tag  = State.desyncMode == 'delayed' and '[LAG] ' or ''
            serverLbl.Text = 'SERVER ' .. tag .. dist .. 'm'
            clientLbl.Text = 'CLIENT'
        else
            serverPart.CFrame = hrp.CFrame
            serverLbl.Text    = 'SERVER (synced)'
            clientLbl.Text    = 'CLIENT'
        end

        if State.baitActive and State.baitPos then
            baitPart.CFrame = CFrame.new(State.baitPos)
            baitLbl.Text    = 'BAIT  ' .. math.floor((hrp.Position - State.baitPos).Magnitude) .. 'm'
        end
    end)

    connectCharacterStateTracking(LocalPlayer.Character)
    print('[VIZ] Visualizer started')
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil
    serverPart.Parent = nil
    baitPart.Parent   = nil
    print('[VIZ] Visualizer stopped')
end

-- ================================================================
--  DESYNC
--
--  FIXED: Delayed interval timing was misaligned. The old approach
--  calculated nextBurstTime once and didn't re-read the slider,
--  meaning if you changed the slider mid-session it had no effect
--  until the loop restarted. Also the repeat/until pattern was
--  checking os.clock() every frame which drifted over time.
--
--  Fix: use task.wait(interval) directly inside the loop, reading
--  the slider fresh each cycle. This means the interval always
--  reflects the current slider value and timing stays accurate.
--  Added detailed print statements so you can verify timing in console.
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'
local delayedLoopActive = false

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true
    print('[DESYNC] Delayed loop started')

    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            -- Read interval fresh each cycle so slider changes take effect immediately
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            print('[DESYNC] Next burst in ' .. interval .. 's')

            -- Accurate wait using os.clock to compensate for task.wait drift
            local waitStart = os.clock()
            task.wait(interval)
            local actualWait = os.clock() - waitStart
            print('[DESYNC] Waited ' .. string.format('%.3f', actualWait) .. 's (target: ' .. interval .. 's)')

            if not State.desyncActive or State.desyncMode ~= 'delayed' then
                print('[DESYNC] Loop exiting — desync disabled or mode changed')
                break
            end

            while forceSyncActive do RunService.Heartbeat:Wait() end

            print('[DESYNC] Opening replication burst...')
            burstWindowOpen = true
            setReplicatorDirect(true)

            for _ = 1, 3 do RunService.Heartbeat:Wait() end

            local hrp = getLocalHRP()
            if hrp then
                State.frozenServerPos = hrp.Position
                print('[DESYNC] Server pos updated to: ' .. tostring(State.frozenServerPos))
            else
                print('[DESYNC] WARNING — no HRP found during burst')
            end

            setReplicatorDirect(false)
            burstWindowOpen = false
            print('[DESYNC] Burst complete — replication locked again')
        end

        delayedLoopActive = false
        print('[DESYNC] Delayed loop stopped')
    end)
end

local function stopDelayedLoop()
    burstWindowOpen   = false
    delayedLoopActive = false
    print('[DESYNC] Delayed loop force-stopped')
end

local function pauseDesync()
    print('[DESYNC] Pausing desync')
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen       = false
    forceSyncActive       = false
    syncQueued            = false
    stopDelayedLoop()
    wantReplication(true)
    Library:Notify('Desync OFF — replication restored')
    print('[DESYNC] Paused — replication open')
end

local function resumeDesync()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!')
        print('[DESYNC] Blocked — not compatible')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end)
        return
    end
    local hrp = getLocalHRP()
    if not hrp then
        Library:Notify('No character!')
        print('[DESYNC] Blocked — no HRP')
        task.defer(function() Toggles.DesyncEnabled:SetValue(false) end)
        return
    end

    State.frozenServerPos = hrp.Position
    State.desyncActive    = true
    burstWindowOpen       = false
    forceSyncActive       = false
    syncQueued            = false
    wantReplication(false)

    print('[DESYNC] Started in mode: ' .. State.desyncMode)
    print('[DESYNC] Initial frozen pos: ' .. tostring(State.frozenServerPos))

    if State.desyncMode == 'delayed' then
        startDelayedLoop()
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        Library:Notify(('Lag Desync ON — bursts every ~%.0fs'):format(iv))
    else
        Library:Notify('Instant Desync ON — server frozen')
    end
end

local function initDesync()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!')
        print('[DESYNC] Init blocked — not compatible'); return
    end
    if desyncInitialized then
        Library:Notify('Already initialized')
        print('[DESYNC] Already initialized'); return
    end
    if not getLocalHRP() then
        Library:Notify('No character — spawn first')
        print('[DESYNC] Init blocked — no character'); return
    end
    desyncInitialized = true
    Library:Notify('Desync ready — use the Enable toggle')
    print('[DESYNC] Initialized successfully')
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
    print('[HIT CONFUSION] Armed — watching for players within ' .. HIT_CONFUSION_RANGE .. ' studs')
    hitConfusionConn = RunService.Heartbeat:Connect(function()
        if not State.hitConfusionArmed then return end
        local hrp = getLocalHRP(); if not hrp then return end
        local inRange = false
        for _, p in next, Players:GetPlayers() do
            if p ~= LocalPlayer and p.Character then
                local eh = p.Character:FindFirstChild('HumanoidRootPart')
                if eh and (hrp.Position - eh.Position).Magnitude <= HIT_CONFUSION_RANGE then
                    inRange = true; break
                end
            end
        end
        if inRange then
            if not State.desyncActive then
                if not State.hitConfusionFrozenAt then
                    State.hitConfusionFrozenAt = hrp.Position
                    print('[HIT CONFUSION] Player in range — freezing server pos at: ' .. tostring(State.hitConfusionFrozenAt))
                end
                if not replicatorIsOwned() then wantReplication(false) end
            end
        else
            if State.hitConfusionFrozenAt and not State.desyncActive then
                print('[HIT CONFUSION] Player out of range — releasing replication')
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
    print('[HIT CONFUSION] Disarmed')
end

-- ================================================================
--  BAIT POSITIONING
-- ================================================================
State.baitActive = false
State.baitPos    = nil

local function stampBaitPosition()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!'); return
    end
    local hrp = getLocalHRP()
    if not hrp then Library:Notify('No character!'); return end
    print('[BAIT] Stamping position...')
    task.spawn(function()
        burstWindowOpen = true
        setReplicatorDirect(true)
        for _ = 1, 4 do RunService.Heartbeat:Wait() end
        State.baitPos    = hrp.Position
        State.baitActive = true
        print('[BAIT] Stamped at: ' .. tostring(State.baitPos))
        if Toggles.DesyncVisualizer and Toggles.DesyncVisualizer.Value then
            baitPart.Parent = workspace
        end
        setReplicatorDirect(false)
        burstWindowOpen = false
        wantReplication(false)
        Library:Notify('Bait stamped — walk away freely')
    end)
end

local function clearBait()
    State.baitActive = false
    State.baitPos    = nil
    baitPart.Parent  = nil
    if not State.desyncActive and not State.hitConfusionArmed then
        wantReplication(true)
    end
    Library:Notify('Bait cleared')
    print('[BAIT] Cleared')
end

-- ================================================================
--  PASSIVE LAG — PURE API (no fflags)
-- ================================================================
State.passiveLagActive = false
local passiveLagConn   = nil
local passiveLagLabel  = nil

local lagStats = { injected = 0, total = 0, lastReset = os.clock() }

local function startPassiveLag()
    if passiveLagConn then passiveLagConn:Disconnect(); passiveLagConn = nil end
    State.passiveLagActive = true
    print('[PASSIVE LAG] Started')

    local snapshotPos     = nil
    local frameCount      = 0
    local injectNextFrame = false

    passiveLagConn = RunService.Heartbeat:Connect(function()
        if not State.passiveLagActive then return end
        local hrp = getLocalHRP(); if not hrp then return end

        local throttle  = Options.PassiveLagThrottle and Options.PassiveLagThrottle.Value or 10
        frameCount      = frameCount + 1
        lagStats.total  = lagStats.total + 1

        if frameCount % throttle == 0 then
            snapshotPos       = hrp.Position
            injectNextFrame   = true
        elseif injectNextFrame and snapshotPos then
            injectNextFrame = false
            local realCF    = hrp.CFrame
            hrp.CFrame = CFrame.new(snapshotPos) * CFrame.fromMatrix(
                Vector3.new(), realCF.RightVector, realCF.UpVector, -realCF.LookVector)
            task.defer(function()
                if hrp and hrp.Parent then hrp.CFrame = realCF end
            end)
            lagStats.injected = lagStats.injected + 1
        end

        local now = os.clock()
        if now - lagStats.lastReset >= 1 then
            local pct = lagStats.total > 0
                and math.floor((lagStats.injected / lagStats.total) * 100) or 0
            if passiveLagLabel then
                passiveLagLabel:SetText(
                    'Injection: ' .. pct .. '%  ' .. (pct > 2 and '| ACTIVE ✓' or '| lower throttle'))
            end
            print('[PASSIVE LAG] Injection rate: ' .. pct .. '%')
            lagStats.injected  = 0
            lagStats.total     = 0
            lagStats.lastReset = now
        end
    end)
end

local function stopPassiveLag()
    State.passiveLagActive = false
    if passiveLagConn then passiveLagConn:Disconnect(); passiveLagConn = nil end
    lagStats.injected = 0; lagStats.total = 0
    if passiveLagLabel then passiveLagLabel:SetText('Passive Lag OFF') end
    print('[PASSIVE LAG] Stopped')
end

-- ================================================================
--  CHARACTER STATE SPOOFER
-- ================================================================
State.stateSpoofActive = false
local stateSpoofThread = nil

local STATE_MAP = {
    ['Seated']      = Enum.HumanoidStateType.Seated,
    ['Ragdoll']     = Enum.HumanoidStateType.Ragdoll,
    ['FallingDown'] = Enum.HumanoidStateType.FallingDown,
    ['Jumping']     = Enum.HumanoidStateType.Jumping,
    ['Swimming']    = Enum.HumanoidStateType.Swimming,
    ['Climbing']    = Enum.HumanoidStateType.Climbing,
}

local function startStateSpoof(stateName)
    State.stateSpoofActive = false
    if stateSpoofThread then task.cancel(stateSpoofThread); stateSpoofThread = nil end

    local targetState = STATE_MAP[stateName]
    if not targetState then
        Library:Notify('Unknown state: ' .. tostring(stateName)); return
    end

    State.stateSpoofActive = true
    print('[STATE SPOOF] Started — spoofing: ' .. stateName)

    stateSpoofThread = task.spawn(function()
        while State.stateSpoofActive do
            local hum = getLocalHum()
            if hum then
                local realState = hum:GetState()
                pcall(function() hum:ChangeState(targetState) end)
                -- One physics frame so the replication packet goes out
                task.wait(1 / 60)
                local h = getLocalHum()
                if h then pcall(function() h:ChangeState(realState) end) end
                print('[STATE SPOOF] Pulsed ' .. stateName .. ' | restored to ' .. tostring(realState))
            end

            local interval = Options.StateSpoofInterval and Options.StateSpoofInterval.Value or 2
            task.wait(interval)
        end
    end)

    Library:Notify('State Spoof ON → ' .. stateName)
end

local function stopStateSpoof()
    State.stateSpoofActive = false
    if stateSpoofThread then task.cancel(stateSpoofThread); stateSpoofThread = nil end
    local hum = getLocalHum()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end) end
    Library:Notify('State Spoof OFF')
    print('[STATE SPOOF] Stopped')
end

-- ================================================================
--  PANIC
-- ================================================================
local function triggerPanic()
    print('[PANIC] Triggered — resetting all systems')
    State.desyncActive         = false
    State.frozenServerPos      = nil
    State.baitActive           = false
    State.baitPos              = nil
    State.hitConfusionArmed    = false
    State.hitConfusionFrozenAt = nil
    State.stateSpoofActive     = false
    State.passiveLagActive     = false
    burstWindowOpen            = false
    forceSyncActive            = false
    syncQueued                 = false

    stopDelayedLoop()
    stopPassiveLag()
    stopStateSpoof()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    baitPart.Parent = nil

    local hum = getLocalHum()
    if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end) end

    wantReplication(true)

    task.defer(function()
        for _, key in ipairs({
            'DesyncEnabled', 'HitConfusionEnabled', 'BaitEnabled',
            'StateSpoofEnabled', 'PassiveLagEnabled'
        }) do
            if Toggles[key] then Toggles[key]:SetValue(false) end
        end
    end)

    Library:Notify('PANIC — all systems reset')
    print('[PANIC] Complete')
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
                    print('[DESYNC] Auto-off triggered — touched player: ' .. p.Name)
                    State.desyncActive    = false
                    State.frozenServerPos = nil
                    stopDelayedLoop()
                    wantReplication(true)
                    if Toggles.DesyncEnabled then Toggles.DesyncEnabled:SetValue(false) end
                    Library:Notify('Desync OFF — touched player')
                end)
                return
            end
        end
    end)
end

-- ================================================================
--  CHARACTER ADDED
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    print('[CHAR] Character added — resetting all desync state')
    desyncInitialized          = false
    State.desyncActive         = false
    State.frozenServerPos      = nil
    State.baitActive           = false
    State.baitPos              = nil
    State.hitConfusionFrozenAt = nil
    State.stateSpoofActive     = false
    State.passiveLagActive     = false
    burstWindowOpen            = false
    forceSyncActive            = false
    syncQueued                 = false

    stopDelayedLoop()
    stopPassiveLag()
    stopStateSpoof()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    baitPart.Parent = nil
    wantReplication(true)
    stopViz()

    task.defer(function()
        for _, key in ipairs({
            'DesyncEnabled', 'HitConfusionEnabled', 'BaitEnabled',
            'StateSpoofEnabled', 'PassiveLagEnabled'
        }) do
            if Toggles[key] then Toggles[key]:SetValue(false) end
        end
    end)

    task.wait(1)
    connectTouchDetection()
    connectCharacterStateTracking(char)
    if State.hitConfusionArmed then startHitConfusion() end
    print('[CHAR] Character setup complete')
end)

if LocalPlayer.Character then
    connectTouchDetection()
    connectCharacterStateTracking(LocalPlayer.Character)
    print('[CHAR] Existing character hooked on script load')
end

-- ================================================================
--  UI
-- ================================================================
local CompatGrp     = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp     = Tabs.Misc:AddLeftGroupbox('Desync')
local CombatGrp     = Tabs.Misc:AddLeftGroupbox('Combat')
local PassiveLagGrp = Tabs.Misc:AddLeftGroupbox('Passive Lag')
local NetGrp        = Tabs.Misc:AddLeftGroupbox('State Spoofing')
local SpinGrp       = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp       = Tabs.Misc:AddRightGroupbox('Misc')
local NetGrp      = Tabs.Misc:AddRightGroupbox('Network/Null')

-- ── Compat + Panic ────────────────────────────────────────────────
CompatGrp:AddLabel('Tests if setfflag accepts the call.\nRestores original value — no side effects.')
CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })
CompatGrp:AddLabel('Panic Key — kills all systems instantly.')
CompatGrp:AddLabel('Panic Key'):AddKeyPicker('PanicKey', {
    Default = 'End', Text = 'Panic Key', Mode = 'Toggle',
    Callback = function(v)
        if v then triggerPanic(); Options.PanicKey:SetValue(false) end
    end,
})

NetGrp:AddLabel('Server Lag Switch')
NetGrp:AddToggle('NullStrikeEnabled', {
    Text = 'Enable Null Strike', Default = false,
    Callback = function(v)
        nullStrikeActive = v
        if v then runNullStrike() end
    end,
})

-- ── Desync ────────────────────────────────────────────────────────
DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Run compat check first, then initialize.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v)
        State.desyncMode = (v == 'Instant') and 'instant' or 'delayed'
        print('[DESYNC] Mode switched to: ' .. State.desyncMode)
        if State.desyncActive then
            if State.desyncMode == 'instant' then
                stopDelayedLoop()
                wantReplication(false)
                Library:Notify('Switched → Instant')
            else
                startDelayedLoop()
                local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
                Library:Notify(('Switched → Lag Mimic (~%.0fs)'):format(iv))
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
                task.defer(function() Toggles.DesyncEnabled:SetValue(false) end)
                return
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

-- ── Combat ────────────────────────────────────────────────────────
CombatGrp:AddToggle('HitConfusionEnabled', {
    Text = 'Hit Validation Confusion', Default = false,
    Callback = function(v)
        if v then
            if not State.replicatorCompatible then
                Library:Notify('Run Compat Check first!')
                task.defer(function() Toggles.HitConfusionEnabled:SetValue(false) end)
                return
            end
            State.hitConfusionArmed = true
            startHitConfusion()
            Library:Notify('Hit Confusion ARMED — ' .. HIT_CONFUSION_RANGE .. ' stud range')
        else
            stopHitConfusion()
            Library:Notify('Hit Confusion OFF')
        end
    end,
})
CombatGrp:AddLabel('Freezes server pos when enemy enters range.')

CombatGrp:AddToggle('BaitEnabled', {
    Text = 'Bait Mode', Default = false,
    Callback = function(v)
        if v then
            if not State.replicatorCompatible then
                Library:Notify('Run Compat Check first!')
                task.defer(function() Toggles.BaitEnabled:SetValue(false) end)
                return
            end
            stampBaitPosition()
        else
            clearBait()
        end
    end,
})
CombatGrp:AddButton({ Text = 'Re-Stamp Bait Here', Func = function()
    if State.baitActive then
        clearBait(); task.wait(0.1); stampBaitPosition()
    else
        Library:Notify('Enable Bait Mode first')
    end
end })
CombatGrp:AddLabel('Stamps pos to server then walk away freely.')

-- ── Passive Lag ───────────────────────────────────────────────────
PassiveLagGrp:AddToggle('PassiveLagEnabled', {
    Text = 'Enable Passive Lag', Default = false,
    Callback = function(v)
        if v then startPassiveLag() else stopPassiveLag() end
    end,
})
PassiveLagGrp:AddSlider('PassiveLagThrottle', {
    Text = 'Throttle (inject every N frames)',
    Default = 10, Min = 2, Max = 120, Rounding = 0,
    Callback = function()
        if State.passiveLagActive then stopPassiveLag(); startPassiveLag() end
    end,
})
passiveLagLabel = PassiveLagGrp:AddLabel('Passive Lag OFF')
PassiveLagGrp:AddLabel('N=2 → ~50%  |  N=10 → ~10%  |  N=60 → ~2%')

-- ── State Spoofing ────────────────────────────────────────────────
NetGrp:AddDropdown('StateSpoofState', {
    Text    = 'Spoof State',
    Default = 'Jumping',
    Values  = { 'Jumping', 'FallingDown', 'Seated', 'Ragdoll', 'Swimming', 'Climbing' },
})
NetGrp:AddSlider('StateSpoofInterval', {
    Text = 'Pulse interval (seconds)', Default = 2, Min = 0.5, Max = 10, Rounding = 1,
})
NetGrp:AddToggle('StateSpoofEnabled', {
    Text = 'Enable State Spoofer', Default = false,
    Callback = function(v)
        if v then
            local s = Options.StateSpoofState and Options.StateSpoofState.Value or 'Jumping'
            startStateSpoof(s)
        else
            stopStateSpoof()
        end
    end,
})
NetGrp:AddLabel('Jumping/FallingDown = no movement restriction.\nSeated/Ragdoll = 1 frame blip per pulse.')

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
MiscGrp:AddToggle('NoClipToggle',     { Text = 'No Clip',              Default = false })
MiscGrp:AddToggle('BetterNoClip',     { Text = 'Better No Clip (anti-rubberband)', Default = false })
MiscGrp:AddToggle('FlyToggle',        { Text = 'Fly',                  Default = false })
MiscGrp:AddSlider('FlySpeed',         { Text = 'Fly Speed', Default = 50, Min = 1, Max = 500, Rounding = 0 })
MiscGrp:AddToggle('FreeCamToggle',    { Text = 'Free Cam',             Default = false })
MiscGrp:AddSlider('FreeCamSpeed',     { Text = 'FreeCam Speed', Default = 80, Min = 5, Max = 500, Rounding = 0 })
MiscGrp:AddToggle('ClickTeleport',    { Text = 'Click to Teleport',    Default = false })
MiscGrp:AddToggle('InfiniteJump',     { Text = 'Infinite Jump',        Default = false })
MiscGrp:AddToggle('GhostMode',        { Text = 'Ghost Mode (noclip + transparent)', Default = false })
MiscGrp:AddLabel('Walkspeed')
MiscGrp:AddToggle('WalkspeedToggle',  { Text = 'Enable Custom Walkspeed', Default = false })
MiscGrp:AddSlider('WalkspeedValue',   { Text = 'Speed', Default = 16, Min = 2, Max = 500, Rounding = 0 })
MiscGrp:AddLabel('Jump Power')
MiscGrp:AddToggle('JumpPowerToggle',  { Text = 'Enable Custom Jump Power', Default = false })
MiscGrp:AddSlider('JumpPowerValue',   { Text = 'Power', Default = 50, Min = 10, Max = 500, Rounding = 0 })

-- ================================================================
--  RUNTIME LOOPS
-- ================================================================

-- ── Basic NoClip ─────────────────────────────────────────────────
RunService.Stepped:Connect(function()
    if not (Toggles.NoClipToggle and Toggles.NoClipToggle.Value) then return end
    local char = LocalPlayer.Character; if not char then return end
    for _, v in next, char:GetDescendants() do
        if v:IsA('BasePart') then v.CanCollide = false end
    end
end)

-- ── Better NoClip ────────────────────────────────────────────────
--
--  Standard noclip sets CanCollide=false client-side, but the server
--  still sees a physics body colliding — after ~0.5s it rubber-bands
--  you back. Better noclip works by:
--    1. Disabling CanCollide (client visual)
--    2. Zeroing the HRP velocity every frame so Roblox's network
--       ownership code doesn't see sudden position jumps
--    3. Moving via CFrame directly (not physics) so the server
--       interpolates smoothly instead of detecting a warp
--    4. Keeping HumanoidState = GettingUp (disables physics
--       simulation on the humanoid) so the server never tries to
--       correct your position via its own physics solver
-- ─────────────────────────────────────────────────────────────────
local betterNoClipConn = nil
local function startBetterNoClip()
    if betterNoClipConn then betterNoClipConn:Disconnect() end
    betterNoClipConn = RunService.Stepped:Connect(function()
        if not (Toggles.BetterNoClip and Toggles.BetterNoClip.Value) then return end
        local char = LocalPlayer.Character; if not char then return end
        local hrp  = char:FindFirstChild('HumanoidRootPart'); if not hrp then return end
        local hum  = char:FindFirstChildWhichIsA('Humanoid'); if not hum then return end

        -- Kill all collision on every part
        for _, v in next, char:GetDescendants() do
            if v:IsA('BasePart') then
                v.CanCollide  = false
                v.CustomPhysicalProperties = PhysicalProperties.new(0.5, 0.3, 0.5, 0, 0)
            end
        end

        -- Zero velocity so server-side position interpolation stays smooth
        hrp.AssemblyLinearVelocity  = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero

        -- Force humanoid into a state that suppresses physics correction
        -- PlatformStanding: engine treats character as manually positioned
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.PlatformStanding) end)
    end)
end

local function stopBetterNoClip()
    if betterNoClipConn then betterNoClipConn:Disconnect(); betterNoClipConn = nil end
    -- Restore physics on all parts
    local char = LocalPlayer.Character
    if char then
        for _, v in next, char:GetDescendants() do
            if v:IsA('BasePart') then
                v.CanCollide = true
                v.CustomPhysicalProperties = PhysicalProperties.new(
                    Enum.Material.SmoothPlastic)
            end
        end
        local hum = char:FindFirstChildWhichIsA('Humanoid')
        if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end) end
    end
end

Toggles:GetToggle('BetterNoClip'):OnChanged(function(v)
    if v then startBetterNoClip() else stopBetterNoClip() end
end)

-- ── Infinite Jump ────────────────────────────────────────────────
local jumpConn = nil
UserInputService = Services.UserInputService or game:GetService('UserInputService')
jumpConn = UserInputService.JumpRequest:Connect(function()
    if not (Toggles.InfiniteJump and Toggles.InfiniteJump.Value) then return end
    local hum = getLocalHum()
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

-- ── Fly ──────────────────────────────────────────────────────────
local flyConn      = nil
local flyBodyVel   = nil
local flyBodyGyro  = nil
local UIS = Services.UserInputService or game:GetService('UserInputService')

local function stopFly()
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    if flyBodyVel  then flyBodyVel:Destroy();  flyBodyVel  = nil end
    if flyBodyGyro then flyBodyGyro:Destroy(); flyBodyGyro = nil end
    local hum = getLocalHum()
    if hum then
        hum.PlatformStand = false
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
    end
end

local function startFly()
    stopFly()
    local hrp = getLocalHRP(); if not hrp then return end
    local hum = getLocalHum(); if not hum then return end

    hum.PlatformStand = true

    flyBodyVel = Instance.new('BodyVelocity')
    flyBodyVel.Velocity       = Vector3.zero
    flyBodyVel.MaxForce       = Vector3.new(1e5, 1e5, 1e5)
    flyBodyVel.Parent         = hrp

    flyBodyGyro = Instance.new('BodyGyro')
    flyBodyGyro.MaxTorque     = Vector3.new(1e5, 1e5, 1e5)
    flyBodyGyro.D             = 100
    flyBodyGyro.CFrame        = hrp.CFrame
    flyBodyGyro.Parent        = hrp

    flyConn = RunService.Heartbeat:Connect(function()
        if not (Toggles.FlyToggle and Toggles.FlyToggle.Value) then stopFly(); return end
        local cam   = workspace.CurrentCamera; if not cam then return end
        local speed = Options.FlySpeed and Options.FlySpeed.Value or 50
        local dir   = Vector3.zero

        if UIS:IsKeyDown(Enum.KeyCode.W) then dir = dir + cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir = dir - cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir = dir - cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir = dir + cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space)       then dir = dir + Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftShift)   then speed = speed * 3 end

        flyBodyVel.Velocity = dir.Magnitude > 0 and dir.Unit * speed or Vector3.zero
        flyBodyGyro.CFrame  = cam.CFrame
    end)
end

Toggles:GetToggle('FlyToggle'):OnChanged(function(v)
    if v then startFly() else stopFly() end
end)

-- ── Ghost Mode ───────────────────────────────────────────────────
--  Noclip + makes local character semi-transparent to others
local ghostConn = nil
local ghostOrigTransparencies = {}

local function stopGhost()
    if ghostConn then ghostConn:Disconnect(); ghostConn = nil end
    local char = LocalPlayer.Character
    if char then
        for _, v in next, char:GetDescendants() do
            if v:IsA('BasePart') then
                v.CanCollide  = true
                v.Transparency = ghostOrigTransparencies[v] or v.Transparency
            end
        end
    end
    ghostOrigTransparencies = {}
end

local function startGhost()
    stopGhost()
    local char = LocalPlayer.Character; if not char then return end
    -- Snapshot original transparencies and apply ghost look
    for _, v in next, char:GetDescendants() do
        if v:IsA('BasePart') then
            ghostOrigTransparencies[v] = v.Transparency
            v.Transparency = 0.6
        end
    end

    ghostConn = RunService.Stepped:Connect(function()
        if not (Toggles.GhostMode and Toggles.GhostMode.Value) then stopGhost(); return end
        local c = LocalPlayer.Character; if not c then return end
        for _, v in next, c:GetDescendants() do
            if v:IsA('BasePart') then
                v.CanCollide  = false
                v.Transparency = 0.6
            end
        end
        local hrp = c:FindFirstChild('HumanoidRootPart')
        local hum = c:FindFirstChildWhichIsA('Humanoid')
        if hrp then
            hrp.AssemblyLinearVelocity  = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end
        if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.PlatformStanding) end) end
    end)
end

Toggles:GetToggle('GhostMode'):OnChanged(function(v)
    if v then startGhost() else stopGhost() end
end)

-- ── Free Cam ─────────────────────────────────────────────────────
--
--  Custom scriptable camera with WASD + QE flight.
--  SHIFT = 3× speed boost.  Scroll wheel = speed adjust.
--  While active, camera.Focus + ReplicationFocus are set to the
--  camera position every frame, so Roblox streams in chunks
--  wherever you fly — same technique as spectate streaming fix.
-- ─────────────────────────────────────────────────────────────────
local freeCamActive   = false
local freeCamConn     = nil
local freeCamInputConn = nil
local freeCamWheelConn = nil
local savedCamType    = nil
local savedCamSubject = nil
local freeCamCF       = CFrame.new(0, 10, 0)
local freeCamSpeedMult = 1  -- scroll-wheel modifier

local FREECAM_KEYS = {
    forward  = Enum.KeyCode.W,
    backward = Enum.KeyCode.S,
    left     = Enum.KeyCode.A,
    right    = Enum.KeyCode.D,
    up       = Enum.KeyCode.E,
    down     = Enum.KeyCode.Q,
    sprint   = Enum.KeyCode.LeftShift,
}

local function stopFreeCam()
    freeCamActive = false
    if freeCamConn      then freeCamConn:Disconnect();      freeCamConn      = nil end
    if freeCamInputConn then freeCamInputConn:Disconnect(); freeCamInputConn = nil end
    if freeCamWheelConn then freeCamWheelConn:Disconnect(); freeCamWheelConn = nil end
    local cam = workspace.CurrentCamera
    if cam then
        cam.CameraType    = savedCamType    or Enum.CameraType.Follow
        cam.CameraSubject = savedCamSubject or (LocalPlayer.Character
            and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid'))
    end
    -- Restore replication focus to self
    pcall(function()
        local hrp = getLocalHRP()
        LocalPlayer.ReplicationFocus = hrp or workspace
    end)
    freeCamSpeedMult = 1
end

local function startFreeCam()
    stopFreeCam()
    local cam = workspace.CurrentCamera; if not cam then return end
    savedCamType    = cam.CameraType
    savedCamSubject = cam.CameraSubject

    -- Start freecam at current camera position
    freeCamCF = cam.CFrame
    cam.CameraType = Enum.CameraType.Scriptable

    freeCamActive = true
    local lastTime = os.clock()

    freeCamConn = RunService.RenderStepped:Connect(function()
        if not (Toggles.FreeCamToggle and Toggles.FreeCamToggle.Value) then stopFreeCam(); return end
        local now = os.clock()
        local dt  = math.min(now - lastTime, 0.1)
        lastTime  = now

        local speed = (Options.FreeCamSpeed and Options.FreeCamSpeed.Value or 80)
            * freeCamSpeedMult
            * (UIS:IsKeyDown(FREECAM_KEYS.sprint) and 3 or 1)
            * dt

        local move = Vector3.zero
        if UIS:IsKeyDown(FREECAM_KEYS.forward)  then move = move + freeCamCF.LookVector  end
        if UIS:IsKeyDown(FREECAM_KEYS.backward) then move = move - freeCamCF.LookVector  end
        if UIS:IsKeyDown(FREECAM_KEYS.right)    then move = move + freeCamCF.RightVector end
        if UIS:IsKeyDown(FREECAM_KEYS.left)     then move = move - freeCamCF.RightVector end
        if UIS:IsKeyDown(FREECAM_KEYS.up)       then move = move + Vector3.yAxis         end
        if UIS:IsKeyDown(FREECAM_KEYS.down)     then move = move - Vector3.yAxis         end

        if move.Magnitude > 0 then
            freeCamCF = CFrame.new(freeCamCF.Position + move.Unit * speed) *
                (freeCamCF - freeCamCF.Position)
        end

        -- Keep camera rotation locked to mouse look (Roblox handles mouse delta
        -- for Scriptable cameras natively in the CoreScript CameraModule, so we
        -- just update position — rotation is driven by RightMouseButton drag)
        cam.CFrame = freeCamCF

        -- ── Force chunk streaming to freecam position ──────────────
        local pos = freeCamCF.Position
        pcall(function() cam.Focus = CFrame.new(pos) end)
        pcall(function() LocalPlayer.ReplicationFocus = workspace.Terrain end)
        -- RequestStreamAroundAsync is the hard force — asks server for this area now
        pcall(function()
            if workspace.RequestStreamAroundAsync then
                workspace:RequestStreamAroundAsync(pos, 0)
            end
        end)
    end)

    -- Scroll wheel adjusts speed multiplier while in freecam
    freeCamWheelConn = UIS.InputChanged:Connect(function(input)
        if not freeCamActive then return end
        if input.UserInputType == Enum.UserInputType.MouseWheel then
            freeCamSpeedMult = math.clamp(freeCamSpeedMult + input.Position.Z * 0.2, 0.1, 10)
        end
    end)
end

Toggles:GetToggle('FreeCamToggle'):OnChanged(function(v)
    if v then startFreeCam() else stopFreeCam() end
end)

-- ── Click to Teleport ────────────────────────────────────────────
--
--  Left-click teleports your HRP to the raycast hit point.
--  Guards: ignores character parts, adds a small Y offset so you
--  land on top of the surface, and handles geometry by nudging
--  the position slightly upward to avoid spawning inside a wall.
-- ─────────────────────────────────────────────────────────────────
local clickTpConn = nil

Toggles:GetToggle('ClickTeleport'):OnChanged(function(v)
    if clickTpConn then clickTpConn:Disconnect(); clickTpConn = nil end
    if not v then return end

    clickTpConn = UIS.InputBegan:Connect(function(input, gp)
        if gp then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if not (Toggles.ClickTeleport and Toggles.ClickTeleport.Value) then return end

        local cam = workspace.CurrentCamera; if not cam then return end
        local hrp = getLocalHRP(); if not hrp then return end
        local char = LocalPlayer.Character; if not char then return end

        local mousePos = UIS:GetMouseLocation()
        local ray = cam:ViewportPointToRay(mousePos.X, mousePos.Y)

        -- Build exclusion list (ignore our own character)
        local exclude = { char }

        local result = workspace:Raycast(
            ray.Origin,
            ray.Direction * 5000,
            RaycastParams.new()
        )
        -- If basic raycast hits nothing, try with instance filter excluding self
        if not result then
            local params = RaycastParams.new()
            params.FilterDescendantsInstances = exclude
            params.FilterType = Enum.RaycastFilterType.Exclude
            result = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
        end

        if result then
            -- Check the hit isn't a part of another player's character
            local hitModel = result.Instance:FindFirstAncestorWhichIsA('Model')
            for _, p in next, Players:GetPlayers() do
                if p.Character == hitModel then return end  -- don't tp into a player
            end

            local targetPos = result.Position + result.Normal * 3  -- offset along surface normal
            hrp.CFrame = CFrame.new(targetPos) * (hrp.CFrame - hrp.CFrame.Position)
            Library:Notify(('Teleported → %.1f, %.1f, %.1f'):format(
                targetPos.X, targetPos.Y, targetPos.Z))
        end
    end)
end)

-- ── Walkspeed ────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function()
    if not (Toggles.WalkspeedToggle and Toggles.WalkspeedToggle.Value) then return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid')
    if hum then hum.WalkSpeed = Options.WalkspeedValue and Options.WalkspeedValue.Value or 16 end
end)

-- ── Jump Power ───────────────────────────────────────────────────
RunService.Heartbeat:Connect(function()
    if not (Toggles.JumpPowerToggle and Toggles.JumpPowerToggle.Value) then return end
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildWhichIsA('Humanoid')
    if hum then hum.JumpPower = Options.JumpPowerValue and Options.JumpPowerValue.Value or 50 end
end)

-- ── Random Part timers ───────────────────────────────────────────
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

-- ── Clean up movement on character reset ─────────────────────────
LocalPlayer.CharacterAdded:Connect(function()
    if flyBodyVel   then flyBodyVel:Destroy();   flyBodyVel   = nil end
    if flyBodyGyro  then flyBodyGyro:Destroy();  flyBodyGyro  = nil end
    if flyConn      then flyConn:Disconnect();   flyConn      = nil end
    ghostOrigTransparencies = {}
end)

end -- return function
