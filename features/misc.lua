-- ================================================================
--  features/misc.lua (FULL RESTORATION)
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

local clientPart, clientLbl = makePart(Color3.fromRGB(60, 255, 100), 'CLIENT')
local serverPart, serverLbl = makePart(Color3.fromRGB(255, 50, 50), 'SERVER')
local baitPart,   baitLbl   = makePart(Color3.fromRGB(255, 165, 0), 'BAIT')
local vizConn = nil

local function startViz()
    if vizConn then vizConn:Disconnect() end
    clientPart.Parent = workspace; serverPart.Parent = workspace
    if State.baitActive then baitPart.Parent = workspace end
    vizConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        clientPart.CFrame = hrp.CFrame
        if State.desyncActive and State.frozenServerPos then
            serverPart.CFrame = CFrame.new(State.frozenServerPos)
        else
            serverPart.CFrame = hrp.CFrame
        end
        if State.baitActive and State.baitPos then
            baitPart.CFrame = CFrame.new(State.baitPos)
        end
    end)
end

-- ================================================================
--  DESYNC & PASSIVE LAG LOGIC
-- ================================================================
local function startDelayedLoop()
    task.spawn(function()
        while State.desyncActive and State.desyncMode == 'delayed' do
            local interval = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
            task.wait(interval)
            if not State.desyncActive then break end
            burstWindowOpen = true
            setReplicatorDirect(true)
            for _ = 1, 4 do RunService.Heartbeat:Wait() end
            local hrp = getLocalHRP()
            if hrp then State.frozenServerPos = hrp.Position end
            setReplicatorDirect(false)
            burstWindowOpen = false
        end
    end)
end

local function startPassiveLag()
    local frameCount = 0
    State.passiveLagConn = RunService.Heartbeat:Connect(function()
        local hrp = getLocalHRP(); if not hrp then return end
        local throttle = Options.PassiveLagThrottle and Options.PassiveLagThrottle.Value or 10
        frameCount = frameCount + 1
        if frameCount % throttle == 0 then
            local realCF = hrp.CFrame
            hrp.CFrame = realCF * CFrame.new(0, 0.01, 0)
            task.defer(function() hrp.CFrame = realCF end)
        end
    end)
end

-- ================================================================
--  UI CONSTRUCTION
-- ================================================================
local CompatGrp     = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp     = Tabs.Misc:AddLeftGroupbox('Desync')
local CombatGrp     = Tabs.Misc:AddLeftGroupbox('Combat')
local PassiveLagGrp = Tabs.Misc:AddLeftGroupbox('Passive Lag')
local NetGrp        = Tabs.Misc:AddLeftGroupbox('State Spoofing')
local SpinGrp       = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp       = Tabs.Misc:AddRightGroupbox('Misc')

CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = runCompatCheck })

DesyncGrp:AddDropdown('DesyncMode', {
    Text = 'Desync Mode', Default = 'Instant',
    Values = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v) State.desyncMode = (v == 'Instant') and 'instant' or 'delayed' end,
})

DesyncGrp:AddToggle('DesyncEnabled', {
    Text = 'Enable Desync', Default = false,
    Callback = function(v)
        State.desyncActive = v
        if v then
            wantReplication(false)
            if State.desyncMode == 'delayed' then startDelayedLoop() end
        else
            wantReplication(true)
        end
    end,
})

CombatGrp:AddToggle('HitConfusionEnabled', {
    Text = 'Hit Validation Confusion', Default = false,
    Callback = function(v) State.hitConfusionArmed = v end,
})

CombatGrp:AddToggle('BaitEnabled', {
    Text = 'Bait Mode', Default = false,
    Callback = function(v)
        State.baitActive = v
        if v then
            local hrp = getLocalHRP()
            if hrp then State.baitPos = hrp.Position end
            wantReplication(false)
        else
            wantReplication(true)
        end
    end,
})

PassiveLagGrp:AddToggle('PassiveLagEnabled', {
    Text = 'Enable Passive Lag', Default = false,
    Callback = function(v)
        if v then startPassiveLag() else if State.passiveLagConn then State.passiveLagConn:Disconnect() end end
    end,
})

PassiveLagGrp:AddSlider('PassiveLagThrottle', { Text = 'Throttle', Default = 10, Min = 2, Max = 120, Rounding = 0 })

-- ── SpinBot ───────────────────────────────────────────────────────
SpinGrp:AddToggle('SpinBotEnabled', { Text = 'Enable SpinBot', Default = false })
SpinGrp:AddSlider('SpinVelocity', { Text = 'Spin Velocity', Default = 50, Min = 1, Max = 100, Rounding = 1 })

-- ── Movement ──────────────────────────────────────────────────────
MiscGrp:AddToggle('WalkspeedToggle', { Text = 'Enable Custom Walkspeed', Default = false })
MiscGrp:AddSlider('WalkspeedValue',  { Text = 'Speed', Default = 16, Min = 16, Max = 500, Rounding = 0 })

RunService.Heartbeat:Connect(function()
    if Toggles.WalkspeedToggle and Toggles.WalkspeedToggle.Value then
        local hum = getLocalHum()
        if hum then hum.WalkSpeed = Options.WalkspeedValue.Value end
    end
    if Toggles.SpinBotEnabled and Toggles.SpinBotEnabled.Value then
        local hrp = getLocalHRP()
        if hrp then
            hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(Options.SpinVelocity.Value), 0)
        end
    end
end)

end
