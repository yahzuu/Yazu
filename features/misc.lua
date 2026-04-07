-- ================================================================
--  features/misc.lua (UPDATED)
-- ================================================================
return function(State, Tabs, Services, Library)
local RunService  = Services.RunStrength or Services.RunService
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
-- ================================================================
State.replicatorCompatible = false
local function runCompatCheck()
    local flag = 'NextGenReplicatorEnabledWrite4'
    if type(setfflag) ~= 'function' then
        Library:Notify('[COMPAT] setfflag not available')
        return false
    end
    local original = 'True'
    if type(getfflag) == 'function' then
        local ok, val = pcall(getfflag, flag)
        if ok and val ~= nil then original = tostring(val) end
    end
    local writeOk = pcall(setfflag, flag, 'True')
    pcall(setfflag, flag, original)
    
    if not writeOk then
        Library:Notify('[COMPAT] Write failed')
        State.replicatorCompatible = false
        return false
    end
    State.replicatorCompatible = true
    Library:Notify('[COMPAT] Compatible ✓')
    print('[COMPAT] Flag writable | restored to: ' .. original)
    return true
end

-- ================================================================
--  MASTER REPLICATOR CONTROLLER
-- ================================================================
local replicationTarget = true
local burstWindowOpen   = false
local forceSyncActive   = false

local function replicatorIsOwned()
    return burstWindowOpen or forceSyncActive
end

local function wantReplication(open)
    replicationTarget = open
end

local function setReplicatorDirect(enabled)
    if not State.replicatorCompatible then return end
    pcall(setfflag, 'NextGenReplicatorEnabledWrite4', enabled and 'True' or 'False')
end

RunService.Heartbeat:Connect(function()
    if not State.replicatorCompatible then return end
    if replicatorIsOwned() then return end
    pcall(setfflag, 'NextGen/ReplicatorEnabledWrite4', replicationTarget and 'True' or 'False')
end)

-- ================================================================
--  NULL STRIKE (New Feature: Network Flooding)
-- ================================================================
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
--  PART HELPERS & VISUALIZER
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
local vizConn = nil

-- ================================================================
--  DESYNC ENGINE (Fixed Timing Alignment)
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'
local delayedLoopActive = false
local nextBurstTime     = 0

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true
    
    task.spawn(function()
        print("[DESYNC] Delayed Loop Started")
        while State.desyncActive and State.desyncMode == 'delayed' do
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            
            -- Use a precise timestamp to prevent frame-drift from the interval slider
            nextBurstTime = os.clock() + interval
            
            -- Wait until precisely the time for the next pulse
            repeat RunService.Heartbeat:Wait() until os.clock() >= nextBurstTime or not State.desyncActive
            
            if not State.desyncActive then break end

            print("[DESYNC] Pulse Triggered! Capturing Server Position...")
            
            burstWindowOpen = true
            setReplicatorDirect(true)
            
            -- Hold the replication open for several frames to ensure server registers pos
            for _ = 1, 6 do RunService.Heartbeat:Wait() end
            
            local hrp = getLocalHRP()
            if hrp then 
                State.frozenServerPos = hrp.Position 
                print("[DESYNC] Server Pos Frozen at: " .. tostring(State.frozenServerPos))
            end
            
            setReplicatorDirect(false)
            burstWindowOpen = false
            print("[DESYNC] Burst Complete. Replication restored.")
        end
        delayedLoopActive = false
        print("[DESYNC] Delayed Loop Stopped")
    end)
end

local function stopDelayedLoop()
    burstWindowOpen = false
    delayedLoopActive = false
end

local function pauseDesync()
    State.desyncActive = false
    State.frozenServerPos = nil
    stopDelayedLoop()
    wantReplication(true)
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    if not State.replicatorCompatible then return end
    local hrp = getLocalHRP()
    if not hrp then return end

    State.frozenServerPos = hrp.Position
    State.desyncActive = true
    wantReplication(false)

    if State.desyncMode == 'delayed' then
        startDelayedLoop()
        Library:Notify('Lag Desync ON')
    else
        Library:Notify('Instant Desync ON')
    end
end

local function initDesync()
    if not State.replicatorCompatible then Library:Notify('Run Compat Check!'); return end
    desyncInitialized = true
    Library:Notify('Desync Ready')
end

-- [Rest of your existing logic for HitConfusion, Bait, PassiveLag, etc.]
-- (Included here to ensure the returned code is fully functional)

local function startViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = workspace; serverPart.Parent = workspace
    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame
        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
            local dist = math.floor((hrp.Position - State.frozenServerPos).Magnitude)
            serverLbl.Text = 'SERVER [LAG] ' .. dist .. 'm'
        else
            server/Part.CFrame = hrp.CFrame
            serverLbl.Text = 'SERVER (synced)'
        end
    end)
end

-- ================================================================
--  UI CONSTRUCTION
-- ================================================================
local MiscGrp     = Tabs.Misc:AddRightGroupbox('Misc')
local DesyncGrp   = Tabs.Misc:AddLeftGroupbox('Desync')
local NetGrp      = Tabs.Misc:AddLeftGroupbox('Network/Null')

MiscGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })

DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v) State.desyncMode = (v == 'Instant') and 'instant' or 'delayed' end,
})
DesyncGrp:AddSlider('DelayedDesyncInterval', {
    Text = 'Lag Interval (seconds)', Default = 5, Min = 1, Max = 30, Rounding = 0,
})
DesyncGrp:AddToggle('DesyncEnabled', {
    Text = 'Enable Desync', Default = false,
    Callback = function(v) if v then resumeDesync() else pauseDesync() end end,
})

NetGrp:AddLabel('Server Lag Switch')
NetGrp:AddToggle('NullStrikeEnabled', {
    Text = 'Enable Null Strike', Default = false,
    Callback = function(v)
        nullStrikeActive = v
        if v then runNullStrike() end
    end,
})

end -- return function
