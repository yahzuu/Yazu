-- ================================================================
--  features/misc.lua
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService  = Services.RunService
local Players     = Services.Players
local LocalPlayer = Services.LocalPlayer
local TweenService = Services.TweenService
local UIS = game:GetService('UserInputService')

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
--  Detected once at load. Gates every feature that needs them.
-- ================================================================
local Exec = {
    hasSetfflag     = type(setfflag)           == 'function',
    hasGetfflag     = type(getfflag)           == 'function',
    hasHookMeta     = type(hookmetamethod)     == 'function',
    hasGetRawMeta   = type(getrawmetatable)    == 'function',
    hasReadMem      = type(readprocessmemory)  == 'function',
    hasWriteMem     = type(writeprocessmemory) == 'function',
    hasGetAddress   = type(getaddress)         == 'function',
    hasFireServer   = type(game.FindFirstChild) == 'function',  -- always true; real check below
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

    -- Step 1: read current value
    local readOk, current = false, nil
    if Exec.hasGetfflag then
        readOk, current = pcall(function() return getfflag(flag) end)
    else
        current = 'True'   -- assume True as safe baseline if we can't read
        readOk  = true
    end

    if not readOk or current == nil then
        Library:Notify('[COMPAT] ' .. flag .. ' — read failed')
        print('[COMPAT] ' .. flag .. ' | read failed')
        State.replicatorCompatible = false
        return false
    end

    -- Step 2: write same value back (harmless no-op write)
    local writeOk = pcall(function() setfflag(flag, tostring(current)) end)
    if not writeOk then
        Library:Notify('[COMPAT] ' .. flag .. ' — write rejected')
        print('[COMPAT] ' .. flag .. ' | write rejected')
        State.replicatorCompatible = false
        return false
    end

    -- Step 3: verify the write applied (only if getfflag available)
    if Exec.hasGetfflag then
        local verOk, after = pcall(function() return getfflag(flag) end)
        if not verOk or tostring(after) ~= tostring(current) then
            Library:Notify('[COMPAT] ' .. flag .. ' — write did not apply')
            print('[COMPAT] ' .. flag .. ' | write did not apply | before=' .. tostring(current) .. ' after=' .. tostring(after))
            State.replicatorCompatible = false
            return false
        end
    end

    State.replicatorCompatible = true
    Library:Notify('[COMPAT] NextGenReplicatorEnabledWrite4 — COMPATIBLE ✓')
    print('[COMPAT] ' .. flag .. ' | read + write verified | current=' .. tostring(current))

    -- Also log other executor capabilities to console
    print('[COMPAT] hookmetamethod  : ' .. tostring(Exec.hasHookMeta))
    print('[COMPAT] getrawmetatable : ' .. tostring(Exec.hasGetRawMeta))
    print('[COMPAT] readprocessmemory  : ' .. tostring(Exec.hasReadMem))
    print('[COMPAT] writeprocessmemory : ' .. tostring(Exec.hasWriteMem))
    print('[COMPAT] getaddress      : ' .. tostring(Exec.hasGetAddress))

    return true
end

-- ================================================================
--  REPLICATOR HELPER
-- ================================================================
local lastFlagState   = nil
local burstWindowOpen = false
local forceSyncActive = false

local function setReplicator(enabled)
    if not State.replicatorCompatible then return end
    local val = enabled and 'True' or 'False'
    if lastFlagState == val then return end
    lastFlagState = val
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', val) end)
end

local function replicatorIsOwned()
    return burstWindowOpen or forceSyncActive
end

-- ================================================================
--  PANIC — instantly restores everything
-- ================================================================
local function triggerPanic()
    -- Kill desync
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen       = false
    forceSyncActive       = false
    lastFlagState         = nil

    -- Kill bait
    State.baitActive      = false
    State.baitPos         = nil

    -- Restore replicator
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', 'True') end)
    lastFlagState = 'True'

    -- Safe-disable toggles
    task.defer(function()
        if Toggles.DesyncEnabled      then Toggles.DesyncEnabled:SetValue(false)      end
        if Toggles.HitConfusionEnabled then Toggles.HitConfusionEnabled:SetValue(false) end
        if Toggles.BaitEnabled        then Toggles.BaitEnabled:SetValue(false)        end
    end)

    Library:Notify('PANIC — all systems reset, replication restored')
end

-- ================================================================
--  PANIC KEYBIND — monitored every heartbeat
-- ================================================================
RunService.Heartbeat:Connect(function()
    if not (Options.PanicKey and Options.PanicKey.Value) then return end
    -- KeyPicker in Toggle mode fires Callback; we also check manually as fallback
end)

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
    task.spawn(function()
        while burstWindowOpen do RunService.Heartbeat:Wait() end
        forceSyncActive = true; lastFlagState = nil
        setReplicator(true)
        for _ = 1, 5 do RunService.Heartbeat:Wait() end
        local hrp = getLocalHRP()
        if hrp then State.frozenServerPos = hrp.Position end
        setReplicator(false)
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
    clientPart.Parent = workspace
    serverPart.Parent = workspace
    if State.baitActive then baitPart.Parent = workspace end

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
            serverLbl.Text = 'SERVER (synced)'; clientLbl.Text = 'CLIENT'
        end

        if State.baitActive and State.baitPos then
            baitPart.CFrame = CFrame.new(State.baitPos)
            local bd = math.floor((hrp.Position - State.baitPos).Magnitude)
            baitLbl.Text = 'BAIT  ' .. bd .. 'm'
        end
    end)
    connectCharacterStateTracking(LocalPlayer.Character)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil; serverPart.Parent = nil; baitPart.Parent = nil
end

-- ================================================================
--  DELAYED DESYNC BURST LOOP
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'
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
            burstWindowOpen = true; lastFlagState = nil
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
    burstWindowOpen = false; delayedLoopActive = false
end

-- ================================================================
--  DESYNC ENABLE / DISABLE
-- ================================================================
local function pauseDesync()
    State.desyncActive    = false
    State.frozenServerPos = nil
    burstWindowOpen = false; forceSyncActive = false; syncQueued = false
    stopDelayedLoop(); lastFlagState = nil
    setReplicator(true)
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    if not State.replicatorCompatible then
        Library:Notify('Run Compat Check first!'); task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return
    end
    local hrp = getLocalHRP()
    if not hrp then Library:Notify('No character!'); task.defer(function() Toggles.DesyncEnabled:SetValue(false) end); return end
    State.frozenServerPos = hrp.Position; State.desyncActive = true
    burstWindowOpen = false; forceSyncActive = false; syncQueued = false; lastFlagState = nil
    setReplicator(false)
    if State.desyncMode == 'delayed' then
        startDelayedLoop()
        local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
        Library:Notify(('Lag Desync ON — bursts every ~%.0fs'):format(iv))
    else
        Library:Notify('Instant Desync ON')
    end
end

-- ================================================================
--  HIT VALIDATION CONFUSION
--
--  Keeps replication blocked specifically while the local player
--  is the network owner of their character and is within combat
--  range of any other player. The server continues to think you
--  are at frozenServerPos, so any server-side hit detection
--  (raycasts, proximity checks, melee) fires against that ghost
--  position rather than where you actually are.
--
--  Works by keeping its own frozen position independent of the
--  main desync toggle — you can arm it separately and it will
--  activate automatically when another player is within range.
-- ================================================================
State.hitConfusionArmed    = false
State.hitConfusionFrozenAt = nil
local hitConfusionConn     = nil
local HIT_CONFUSION_RANGE  = 60   -- studs — arm range

local function startHitConfusion()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    hitConfusionConn = RunService.Heartbeat:Connect(function()
        if not State.hitConfusionArmed then return end
        local hrp = getLocalHRP(); if not hrp then return end

        -- Check if any other player is within range
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
            -- Player nearby — lock replication, server sees old position
            if not State.desyncActive then   -- don't conflict if main desync is running
                if not State.hitConfusionFrozenAt then
                    State.hitConfusionFrozenAt = hrp.Position
                end
                if not replicatorIsOwned() then setReplicator(false) end
            end
        else
            -- Nobody nearby — release lock and reset frozen pos
            if State.hitConfusionFrozenAt and not State.desyncActive then
                State.hitConfusionFrozenAt = nil
                if not replicatorIsOwned() then setReplicator(true) end
            end
        end
    end)
end

local function stopHitConfusion()
    if hitConfusionConn then hitConfusionConn:Disconnect(); hitConfusionConn = nil end
    State.hitConfusionArmed    = false
    State.hitConfusionFrozenAt = nil
    if not State.desyncActive then setReplicator(true) end
end

-- ================================================================
--  BAIT POSITIONING
--
--  Freezes a "bait" position at your current location, then lets
--  you open replication briefly to stamp that position into the
--  server, then locks replication again as you walk away.
--  To others on the server, your character remains at the bait
--  spot while you move freely. Orange visualizer part marks it.
--
--  Re-stamp button refreshes the bait to your current position
--  if you want to move the decoy.
-- ================================================================
State.baitActive = false
State.baitPos    = nil

local function stampBaitPosition()
    if not State.replicatorCompatible then Library:Notify('Run Compat Check first!'); return end
    local hrp = getLocalHRP(); if not hrp then Library:Notify('No character!'); return end

    -- Briefly open replication so server receives this exact position as a real update
    lastFlagState = nil
    setReplicator(true)
    task.spawn(function()
        for _ = 1, 4 do RunService.Heartbeat:Wait() end  -- 4 frames = clean stamp
        State.baitPos    = hrp.Position
        State.baitActive = true
        if Toggles.DesyncVisualizer and Toggles.DesyncVisualizer.Value then
            baitPart.Parent = workspace
        end
        setReplicator(false); lastFlagState = 'False'
        Library:Notify('Bait stamped at current position — walk away freely')
    end)
end

local function clearBait()
    State.baitActive = false
    State.baitPos    = nil
    baitPart.Parent  = nil
    -- Release replication only if main desync is also off
    if not State.desyncActive and not State.hitConfusionArmed then
        setReplicator(true)
    end
    Library:Notify('Bait cleared')
end

-- ================================================================
--  TOUCH DETECTION (auto-off for desync)
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
                    Library:Notify('Desync OFF — touched player')
                end); return
            end
        end
    end)
end

-- ================================================================
--  NETWORK MANIPULATION
--  Uses hookmetamethod on the game metatable to intercept all
--  FireServer / InvokeServer calls. Potassium exposes this.
--
--  Remote Spy — logs every outgoing remote call to console.
--  Remote Block — lets you block specific named remotes from firing.
-- ================================================================
local remoteSpyHook   = nil
local remoteBlockHook = nil
local blockedRemotes  = {}   -- set of remote names to silently drop

local function startRemoteSpy()
    if not Exec.hasHookMeta or not Exec.hasGetRawMeta then
        Library:Notify('hookmetamethod not available in this executor'); return
    end
    if remoteSpyHook then Library:Notify('Remote spy already running'); return end

    local mt = getrawmetatable(game)
    local oldIndex = mt.__index

    remoteSpyHook = hookmetamethod(game, '__index', function(self, key)
        local result = oldIndex(self, key)
        -- We hook the result of indexing so we can wrap FireServer/InvokeServer
        if (key == 'FireServer' or key == 'InvokeServer') and typeof(self) == 'Instance' then
            return function(remote, ...)
                local args = {...}
                print('[REMOTE SPY] ' .. key .. ' | ' .. remote.Name .. ' | ' .. remote:GetFullName())
                for i, v in ipairs(args) do
                    print('  arg[' .. i .. '] = ' .. tostring(v))
                end
                -- Block check
                if blockedRemotes[remote.Name] then
                    Library:Notify('Blocked: ' .. remote.Name)
                    return
                end
                return result(remote, table.unpack(args))
            end
        end
        return result
    end)

    Library:Notify('Remote Spy ON — check console')
end

local function stopRemoteSpy()
    if remoteSpyHook then
        pcall(function() remoteSpyHook() end)  -- unhook
        remoteSpyHook = nil
    end
    Library:Notify('Remote Spy OFF')
end

local function addBlockedRemote(name)
    if name and #name > 0 then
        blockedRemotes[name] = true
        Library:Notify('Blocking remote: ' .. name)
    end
end

local function removeBlockedRemote(name)
    if name and #name > 0 then
        blockedRemotes[name] = nil
        Library:Notify('Unblocked: ' .. name)
    end
end

-- ================================================================
--  MEMORY MANIPULATION (Potassium)
--  Potassium exposes readprocessmemory / writeprocessmemory /
--  getaddress. We use this to write WalkSpeed and Gravity directly
--  to memory — bypasses Humanoid property replication entirely,
--  so the server never sees the speed change even if someone
--  reads the Humanoid. Also unlocks locked instance properties.
-- ================================================================
local function memWriteWalkSpeed(speed)
    if not Exec.hasGetAddress or not Exec.hasWriteMem then
        Library:Notify('Memory write not available'); return
    end
    local hum = getLocalHum(); if not hum then Library:Notify('No humanoid'); return end
    local ok, err = pcall(function()
        local addr = getaddress(hum) + 0x140   -- WalkSpeed offset (Potassium/R6 typical)
        writeprocessmemory(addr, {speed}, 4)    -- float32
    end)
    if ok then
        Library:Notify('Memory WalkSpeed written: ' .. tostring(speed))
    else
        Library:Notify('Memory write failed — offset may differ: ' .. tostring(err))
        print('[MEM] WalkSpeed write error: ' .. tostring(err))
    end
end

local function memWriteGravity(gravity)
    if not Exec.hasGetAddress or not Exec.hasWriteMem then
        Library:Notify('Memory write not available'); return
    end
    local ok, err = pcall(function()
        -- workspace Gravity sits at a known offset from workspace base
        local addr = getaddress(workspace) + 0x2C0
        writeprocessmemory(addr, {gravity}, 4)
    end)
    if ok then
        Library:Notify('Memory Gravity written: ' .. tostring(gravity))
    else
        Library:Notify('Gravity write failed — offset may differ: ' .. tostring(err))
        print('[MEM] Gravity write error: ' .. tostring(err))
    end
end

-- Property unlock via getrawmetatable — lets you set locked properties
-- (e.g. BasePart.LocalTransparencyModifier, Humanoid properties, etc.)
local unlockedMT = false
local function unlockProperties()
    if not Exec.hasGetRawMeta then Library:Notify('getrawmetatable not available'); return end
    if unlockedMT then Library:Notify('Already unlocked'); return end
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__newindex
        mt.__newindex = function(t, k, v)
            if not pcall(old, t, k, v) then
                rawset(t, k, v)
            end
        end
    end)
    if ok then
        unlockedMT = true
        Library:Notify('Instance properties unlocked via rawmetatable')
    else
        Library:Notify('Property unlock failed')
    end
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
    State.desyncHbConn = RunService.Heartbeat:Connect(function()
        if not State.desyncActive then return end
        if replicatorIsOwned() then return end
        setReplicator(false)
    end)
    Library:Notify('Desync ready — toggle to enable')
end

-- ================================================================
--  CHARACTER ADDED
-- ================================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    if State.desyncHbConn then State.desyncHbConn:Disconnect(); State.desyncHbConn = nil end
    desyncInitialized = false; State.desyncActive = false; State.frozenServerPos = nil
    State.baitActive = false; State.baitPos = nil
    State.hitConfusionFrozenAt = nil
    burstWindowOpen = false; forceSyncActive = false; syncQueued = false; lastFlagState = nil
    stopDelayedLoop(); baitPart.Parent = nil
    pcall(function() if setfflag then setfflag('NextGenReplicatorEnabledWrite4', 'True') end end)
    stopViz()
    task.defer(function()
        if Toggles.DesyncEnabled       then Toggles.DesyncEnabled:SetValue(false)       end
        if Toggles.HitConfusionEnabled then Toggles.HitConfusionEnabled:SetValue(false) end
        if Toggles.BaitEnabled         then Toggles.BaitEnabled:SetValue(false)         end
    end)
    task.wait(1)
    connectTouchDetection()
    connectCharacterStateTracking(char)
    -- Re-arm hit confusion if it was on
    if State.hitConfusionArmed then startHitConfusion() end
end)

if LocalPlayer.Character then
    connectTouchDetection()
    connectCharacterStateTracking(LocalPlayer.Character)
end

-- ================================================================
--  UI — MISC TAB
-- ================================================================
local CompatGrp   = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp   = Tabs.Misc:AddLeftGroupbox('Desync')
local CombatGrp   = Tabs.Misc:AddLeftGroupbox('Combat (NextGenReplicator)')
local NetworkGrp  = Tabs.Misc:AddLeftGroupbox('Network')
local MemoryGrp   = Tabs.Misc:AddLeftGroupbox('Memory (Potassium)')
local SpinGrp     = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp     = Tabs.Misc:AddRightGroupbox('Misc')

-- ── Compat ────────────────────────────────────────────────────────
CompatGrp:AddLabel('Tests NextGenReplicatorEnabledWrite4\nand logs all executor capabilities.')
CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })

-- ── Panic ─────────────────────────────────────────────────────────
CompatGrp:AddLabel('Panic Key — instantly resets everything.')
CompatGrp:AddLabel('Panic Key'):AddKeyPicker('PanicKey', {
    Default = 'End', Text = 'Panic Key', Mode = 'Toggle',
    Callback = function(v) if v then triggerPanic(); Options.PanicKey:SetValue(false) end end,
})

-- ── Desync ────────────────────────────────────────────────────────
DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Run compat check first.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v)
        State.desyncMode = (v == 'Instant') and 'instant' or 'delayed'
        if State.desyncActive then
            if State.desyncMode == 'instant' then
                stopDelayedLoop(); lastFlagState = nil; setReplicator(false)
                Library:Notify('Switched → Instant')
            else
                burstWindowOpen = false; lastFlagState = nil; startDelayedLoop()
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

-- ── Combat ────────────────────────────────────────────────────────
-- Hit Validation Confusion
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
            Library:Notify('Hit Confusion ARMED — activates when player within ' .. HIT_CONFUSION_RANGE .. ' studs')
        else
            stopHitConfusion()
            Library:Notify('Hit Confusion OFF')
        end
    end,
})
CombatGrp:AddLabel('Freezes your server position when a player\nenters range. Their hits resolve against\nyour ghost position, not where you are.')

-- Bait Positioning
CombatGrp:AddToggle('BaitEnabled', {
    Text = 'Bait Mode (freeze + walk away)', Default = false,
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
CombatGrp:AddButton({ Text = 'Re-Stamp Bait (move decoy here)', Func = function()
    if State.baitActive then
        clearBait()
        task.wait(0.1)
        stampBaitPosition()
    else
        Library:Notify('Enable Bait Mode first')
    end
end })
CombatGrp:AddLabel('Stamps your position to server then lets\nyou walk away. Server sees you standing\nstill at the bait spot.')

-- ── Network ───────────────────────────────────────────────────────
NetworkGrp:AddToggle('RemoteSpyEnabled', {
    Text = 'Remote Spy (log all FireServer)', Default = false,
    Callback = function(v)
        if v then startRemoteSpy() else stopRemoteSpy() end
    end,
})
NetworkGrp:AddLabel('Logs every outgoing remote call\nto console with arguments.')

NetworkGrp:AddInput('BlockRemoteInput', {
    Default = '', Text = 'Remote Name to Block', Placeholder = 'Exact remote name...',
})
NetworkGrp:AddButton({ Text = 'Block Remote', Func = function()
    local v = Options.BlockRemoteInput and Options.BlockRemoteInput.Value or ''
    addBlockedRemote(v)
end })
NetworkGrp:AddButton({ Text = 'Unblock Remote', Func = function()
    local v = Options.BlockRemoteInput and Options.BlockRemoteInput.Value or ''
    removeBlockedRemote(v)
end })
NetworkGrp:AddLabel('Silently drops FireServer calls\nfor the named remote.')

-- ── Memory ────────────────────────────────────────────────────────
MemoryGrp:AddLabel('Writes values directly to memory.\nBypasses property replication entirely.')

MemoryGrp:AddSlider('MemWalkSpeed', {
    Text = 'Memory WalkSpeed', Default = 16, Min = 1, Max = 500, Rounding = 0,
})
MemoryGrp:AddButton({ Text = 'Write WalkSpeed to Memory', Func = function()
    local v = Options.MemWalkSpeed and Options.MemWalkSpeed.Value or 16
    memWriteWalkSpeed(v)
end })

MemoryGrp:AddSlider('MemGravity', {
    Text = 'Memory Gravity', Default = 196, Min = 0, Max = 1000, Rounding = 0,
})
MemoryGrp:AddButton({ Text = 'Write Gravity to Memory', Func = function()
    local v = Options.MemGravity and Options.MemGravity.Value or 196
    memWriteGravity(v)
end })

MemoryGrp:AddButton({ Text = 'Unlock Instance Properties', Func = unlockProperties })
MemoryGrp:AddLabel('Unlocks locked instance properties\nvia rawmetatable hook.')

-- ── SpinBot ───────────────────────────────────────────────────────
SpinGrp:AddToggle('SpinBotEnabled',       { Text = 'Enable SpinBot', Default = false })
SpinGrp:AddLabel('Spin Key'):AddKeyPicker('SpinKey', { Default = 'None', Text = 'Spin Key', Mode = 'Hold' })
SpinGrp:AddToggle('OnePressSpinningMode', { Text = 'One-Press Mode', Default = false })
SpinGrp:AddSlider('SpinVelocity',         { Text = 'Spin Velocity',  Default = 50, Min = 1, Max = 50, Rounding = 1 })
SpinGrp:AddDropdown('SpinPart', { Text = 'Spin Part', Default = 2, Values = State.spinPartValues })
SpinGrp:AddInput('AddSpinPartInput', { Default = '', Text = 'Add Spin Part', Placeholder = 'Part name...' })
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
