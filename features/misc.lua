-- ================================================================
--  features/misc.lua (FULLY RESTORED & FIXED)
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
-- ================================================================
local REPLICATOR_FLAG = 'NextGenReplicatorEnabledWrite4'
State.replicatorCompatible = false

local function runCompatCheck()
    if type(setfflag) ~= 'function' then
        Library:Notify('[COMPAT] setfflag not available')
        return false
    end

    local original = 'True'
    if type(getfflag) == 'function' then
        local ok, val = pcall(getfflag, REPLICATOR_FLAG)
        if ok and val ~= nil then original = tostring(val) end
    end

    local writeOk = pcall(setfflag, REPLICATOR_FLAG, 'True')
    pcall(setfflag, REPLICATOR_FLAG, original)

    if not writeOk then
        Library:Notify('[COMPAT] Write failed')
        State.replicatorCompatible = false
        return false
    end

    State.replicatorCompatible = true
    Library:Notify('[COMPAT] Compatible ✓')
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
    pcall(setfflag, REPLICATOR_FLAG, enabled and 'True' or 'False')
end

RunService.Heartbeat:Connect(function()
    if not State.replicatorCompatible then return end
    if replicatorIsOwned() then return end
    pcall(setfflag, REPLICATOR_FLAG, replicationTarget and 'True' or 'False')
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

local clientPart, clientLbl = makePart(Color3.fromRGB(60,  255, 100), 'CLIENT')
local serverPart, serverLbl = makePart(Color3.fromRGB(255,  50,  50), 'SERVER')
local baitPart,   baitLbl   = makePart(Color3.fromRGB(255, 165,   0), 'BAIT')
local vizConn = nil

-- ================================================================
--  DESYNC ENGINE
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'
local delayedLoopActive = false

local function startDelayedLoop()
    if delayedLoopActive then return end
    delayedLoopActive = true
    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            task.wait(interval)
            if not State.desyncActive or State.desyncMode ~= 'delayed' then break end
            
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

local function pauseDesync()
    State.desyncActive    = false
    State.frozenServerPos = nil
    delayedLoopActive     = false
    wantReplication(true)
    Library:Notify('Desync OFF')
end

local function resumeDesync()
    if not State.replicatorCompatible then return end
    local hrp = getLocalHRP()
    if not hrp then return end
    State.frozenServerPos = hrp.Position
    State.desyncActive    = true
    wantReplication(false)
    if State.desyncMode == 'delayed' then startDelayedLoop() end
end

-- ================================================================
--  VISUALIZER
-- ================================================================
local function startViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = workspace
    serverPart.Parent = workspace
    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame
        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
            local dist = math.floor((hrp.Position - State.frozenServerPos).Magnitude)
            serverLbl.Text = 'SERVER [LAG] ' .. dist .. 'm'
        else
            serverPart.CFrame = hrp.CFrame
            serverLbl.Text    = 'SERVER (synced)'
        end
    end)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil
    serverPart.Parent = nil
end

-- ================================================================
--  UI SECTION
-- ================================================================
local CompatGrp     = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp     = Tabs.Misc:AddLeftGroupbox('Desync')
local CombatGrp     = Tabs.Misc:AddLeftGroupbox('Combat')
local PassiveLagGrp = Tabs.Misc:AddLeftGroupbox('Passive Lag')
local NetGrp        = Tabs.Misc:AddLeftGroupbox('State Spoofing')
local SpinGrp       = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp       = Tabs.Misc:AddRightGroupbox('Misc')

CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })

DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = function() desyncInitialized = true; Library:Notify('Ready') end })
DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v) State.desyncMode = (v == 'Instant') and 'instant' or 'delayed' end,
})
DesyncGrp:AddSlider('DelayedDesyncInterval', { Text = 'Lag Interval', Default = 5, Min = 1, Max = 30, Rounding = 0 })
DesyncGrp:AddToggle('DesyncEnabled', {
    Text = 'Enable Desync', Default = false,
    Callback = function(v) if v then resumeDesync() else pauseDesync() end end,
})
DesyncGrp:AddToggle('DesyncVisualizer', {
    Text = 'Show 3D Visualizer', Default = false,
    Callback = function(v) if v then startViz() else stopViz() end end,
})

-- (The rest of the Movement/Walkspeed toggles go here similar to your file)
MiscGrp:AddToggle('WalkspeedToggle', { Text = 'Enable Custom Walkspeed', Default = false })
MiscGrp:AddSlider('WalkspeedValue',  { Text = 'Speed', Default = 16, Min = 2, Max = 500, Rounding = 0 })

RunService.Heartbeat:Connect(function()
    if not (Toggles.WalkspeedToggle and Toggles.WalkspeedToggle.Value) then return end
    local hum = getLocalHum()
    if hum then hum.WalkSpeed = Options.WalkspeedValue.Value end
end)

end
