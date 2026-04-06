-- ================================================================
--  features/misc.lua
--  Contains: FFlag Compatibility Check, Desync (Instant + Delayed),
--            Passive Lag, Physics Tweaks, Animation Throttle,
--            Render Tweaks, SpinBot UI, Movement, random part timers.
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
--  FFLAG COMPATIBILITY LAYER
--
--  Different executors expose different levels of fflag access:
--    Level 0 — setfflag / getfflag don't exist at all
--    Level 1 — setfflag exists but silently fails on most flags
--    Level 2 — setfflag works on some flags (usually DFInt*)
--    Level 3 — full read + write on all known flags
--
--  We probe each flag we care about by:
--    1. Checking if setfflag / getfflag functions exist
--    2. Attempting a harmless read via getfflag
--    3. Attempting a no-op write (write current value back)
--    4. Verifying the write actually took by reading back
--  Flags that pass all 4 steps are marked compatible.
-- ================================================================
local FlagCompat = {}   -- FlagCompat[flagName] = true/false
local compatChecked = false

-- Every fflag this script touches, grouped by feature
local ALL_FLAGS = {
    -- Desync core
    { name = 'NextGenReplicatorEnabledWrite4',  feature = 'Desync'          },
    -- Passive lag
    { name = 'DFIntS2PhysicsSendRate',          feature = 'Passive Lag'     },
    { name = 'DFIntDataSenderMaxBandwidthBps',  feature = 'Passive Lag'     },
    -- Physics tweaks
    { name = 'DFIntMaxMissedWorldStepsRemembered', feature = 'Physics'      },
    { name = 'DFIntPhysicsSimPingAdaptive',        feature = 'Physics'      },
    { name = 'DFIntPhysicsReceiveNumReplicators',  feature = 'Physics'      },
    -- Animation throttle
    { name = 'DFIntReplicatorAnimationTrackLodBps', feature = 'Animation'   },
    -- Render tweaks
    { name = 'FIntRenderShadowIntensity',          feature = 'Render'       },
    { name = 'DFIntDebugFRMMinQualityLevel',        feature = 'Render'       },
    { name = 'FFlagNewLightAttenuation',            feature = 'Render'       },
    { name = 'DFIntTextureCompositorActiveTexturesBudget', feature = 'Render' },
}

-- Run the compatibility probe. Returns a results table.
local function runCompatCheck()
    local results = {}
    local canSet = type(setfflag) == 'function'
    local canGet = type(getfflag) == 'function'

    for _, entry in ipairs(ALL_FLAGS) do
        local flag    = entry.name
        local compat  = false
        local reason  = ''

        if not canSet then
            reason = 'setfflag missing'
        elseif not canGet then
            -- Can write but can't verify — mark as partial
            local ok = pcall(function() setfflag(flag, tostring(setfflag(flag))) end)
            compat = ok   -- best guess
            reason = ok and 'write-only (unverified)' or 'write failed'
        else
            -- Full probe: read → write same value back → read again to verify
            local readOk, current = pcall(function() return getfflag(flag) end)
            if not readOk or current == nil then
                reason = 'read failed'
            else
                local writeOk = pcall(function() setfflag(flag, tostring(current)) end)
                if not writeOk then
                    reason = 'write rejected'
                else
                    local verifyOk, after = pcall(function() return getfflag(flag) end)
                    if verifyOk and tostring(after) == tostring(current) then
                        compat = true
                        reason = 'read + write verified'
                    else
                        reason = 'write did not apply'
                    end
                end
            end
        end

        FlagCompat[flag] = compat
        table.insert(results, {
            name    = flag,
            feature = entry.feature,
            compat  = compat,
            reason  = reason,
        })
    end

    compatChecked = true
    return results
end

-- Helper used by features: returns true only if flag is compatible
local function flagOk(name)
    if not compatChecked then return type(setfflag) == 'function' end
    return FlagCompat[name] == true
end

-- ================================================================
--  DESYNC STATE
-- ================================================================
local desyncInitialized = false
State.desyncMode        = State.desyncMode or 'instant'

local burstWindowOpen = false
local forceSyncActive = false
local lastFlagState   = nil

local function setReplicator(enabled)
    if not flagOk('NextGenReplicatorEnabledWrite4') then return end
    local val = enabled and 'True' or 'False'
    if lastFlagState == val then return end
    lastFlagState = val
    pcall(function() setfflag('NextGenReplicatorEnabledWrite4', val) end)
end

local function replicatorIsOwned()
    return burstWindowOpen or forceSyncActive
end

-- ================================================================
--  PASSIVE LAG
-- ================================================================
local originalSendRate  = nil
local originalBandwidth = nil
local DEFAULT_SEND_RATE  = '20'
local DEFAULT_BANDWIDTH  = '50000'

local function applyPassiveLag()
    if not originalSendRate then
        originalSendRate  = (flagOk('DFIntS2PhysicsSendRate')
            and pcall(function() return getfflag('DFIntS2PhysicsSendRate') end)
            and getfflag('DFIntS2PhysicsSendRate')) or DEFAULT_SEND_RATE
        originalBandwidth = (flagOk('DFIntDataSenderMaxBandwidthBps')
            and pcall(function() return getfflag('DFIntDataSenderMaxBandwidthBps') end)
            and getfflag('DFIntDataSenderMaxBandwidthBps')) or DEFAULT_BANDWIDTH
    end

    local rate = Options.PassiveLagSendRate    and Options.PassiveLagSendRate.Value    or 3
    local bw   = Options.PassiveLagBandwidth   and Options.PassiveLagBandwidth.Value   or 8000

    if flagOk('DFIntS2PhysicsSendRate') then
        pcall(function() setfflag('DFIntS2PhysicsSendRate', tostring(rate)) end)
    end
    if flagOk('DFIntDataSenderMaxBandwidthBps') then
        pcall(function() setfflag('DFIntDataSenderMaxBandwidthBps', tostring(bw)) end)
    end
end

local function removePassiveLag()
    if flagOk('DFIntS2PhysicsSendRate') then
        pcall(function() setfflag('DFIntS2PhysicsSendRate',         originalSendRate  or DEFAULT_SEND_RATE)  end)
    end
    if flagOk('DFIntDataSenderMaxBandwidthBps') then
        pcall(function() setfflag('DFIntDataSenderMaxBandwidthBps', originalBandwidth or DEFAULT_BANDWIDTH) end)
    end
    originalSendRate  = nil
    originalBandwidth = nil
end

local function refreshPassiveLag()
    if Toggles.PassiveLagEnabled and Toggles.PassiveLagEnabled.Value then applyPassiveLag() end
end

-- ================================================================
--  PHYSICS TWEAKS
-- ================================================================
local origPhysicsValues = {}

local PHYSICS_FLAGS = {
    { flag = 'DFIntMaxMissedWorldStepsRemembered', default = '16'  },
    { flag = 'DFIntPhysicsSimPingAdaptive',        default = '1'   },
    { flag = 'DFIntPhysicsReceiveNumReplicators',  default = '8'   },
}

local function applyPhysicsTweaks()
    -- Zero missed-steps: prevents engine from catching up physics gaps (no rubber-band correction)
    if flagOk('DFIntMaxMissedWorldStepsRemembered') then
        origPhysicsValues['DFIntMaxMissedWorldStepsRemembered'] =
            pcall(function() return getfflag('DFIntMaxMissedWorldStepsRemembered') end) and
            getfflag('DFIntMaxMissedWorldStepsRemembered') or '16'
        pcall(function() setfflag('DFIntMaxMissedWorldStepsRemembered', '0') end)
    end
    -- Disable adaptive ping compensation: movement feels snappier client-side
    if flagOk('DFIntPhysicsSimPingAdaptive') then
        origPhysicsValues['DFIntPhysicsSimPingAdaptive'] =
            pcall(function() return getfflag('DFIntPhysicsSimPingAdaptive') end) and
            getfflag('DFIntPhysicsSimPingAdaptive') or '1'
        pcall(function() setfflag('DFIntPhysicsSimPingAdaptive', '0') end)
    end
    -- Drop receive replicators: client ignores more server corrections
    if flagOk('DFIntPhysicsReceiveNumReplicators') then
        origPhysicsValues['DFIntPhysicsReceiveNumReplicators'] =
            pcall(function() return getfflag('DFIntPhysicsReceiveNumReplicators') end) and
            getfflag('DFIntPhysicsReceiveNumReplicators') or '8'
        pcall(function() setfflag('DFIntPhysicsReceiveNumReplicators', '1') end)
    end
    Library:Notify('Physics tweaks applied')
end

local function removePhysicsTweaks()
    for _, entry in ipairs(PHYSICS_FLAGS) do
        if flagOk(entry.flag) then
            pcall(function()
                setfflag(entry.flag, origPhysicsValues[entry.flag] or entry.default)
            end)
        end
    end
    origPhysicsValues = {}
    Library:Notify('Physics tweaks removed')
end

-- ================================================================
--  ANIMATION THROTTLE
-- ================================================================
local origAnimBps = nil

local function applyAnimThrottle()
    if not flagOk('DFIntReplicatorAnimationTrackLodBps') then
        Library:Notify('AnimTrackLodBps not compatible'); return
    end
    origAnimBps = (pcall(function() return getfflag('DFIntReplicatorAnimationTrackLodBps') end)
        and getfflag('DFIntReplicatorAnimationTrackLodBps')) or '1000'
    local bps = Options.AnimThrottleBps and Options.AnimThrottleBps.Value or 100
    pcall(function() setfflag('DFIntReplicatorAnimationTrackLodBps', tostring(bps)) end)
end

local function removeAnimThrottle()
    if not flagOk('DFIntReplicatorAnimationTrackLodBps') then return end
    pcall(function() setfflag('DFIntReplicatorAnimationTrackLodBps', origAnimBps or '1000') end)
    origAnimBps = nil
end

local function refreshAnimThrottle()
    if Toggles.AnimThrottleEnabled and Toggles.AnimThrottleEnabled.Value then applyAnimThrottle() end
end

-- ================================================================
--  RENDER TWEAKS
-- ================================================================
local origShadowIntensity   = nil
local origRenderQuality     = nil
local origLightAttenuation  = nil
local origTextureBudget     = nil

local function applyRenderTweaks()
    if flagOk('FIntRenderShadowIntensity') then
        origShadowIntensity = (pcall(function() return getfflag('FIntRenderShadowIntensity') end)
            and getfflag('FIntRenderShadowIntensity')) or '1000'
        pcall(function() setfflag('FIntRenderShadowIntensity', '0') end)
    end
    if flagOk('DFIntDebugFRMMinQualityLevel') then
        origRenderQuality = (pcall(function() return getfflag('DFIntDebugFRMMinQualityLevel') end)
            and getfflag('DFIntDebugFRMMinQualityLevel')) or '0'
        local q = Options.RenderQualityLevel and tostring(Options.RenderQualityLevel.Value) or '1'
        pcall(function() setfflag('DFIntDebugFRMMinQualityLevel', q) end)
    end
    if flagOk('FFlagNewLightAttenuation') then
        origLightAttenuation = (pcall(function() return getfflag('FFlagNewLightAttenuation') end)
            and getfflag('FFlagNewLightAttenuation')) or 'True'
        pcall(function() setfflag('FFlagNewLightAttenuation', 'False') end)
    end
    if flagOk('DFIntTextureCompositorActiveTexturesBudget') then
        origTextureBudget = (pcall(function() return getfflag('DFIntTextureCompositorActiveTexturesBudget') end)
            and getfflag('DFIntTextureCompositorActiveTexturesBudget')) or '64'
        local t = Options.TextureBudget and tostring(Options.TextureBudget.Value) or '8'
        pcall(function() setfflag('DFIntTextureCompositorActiveTexturesBudget', t) end)
    end
end

local function removeRenderTweaks()
    if flagOk('FIntRenderShadowIntensity') and origShadowIntensity then
        pcall(function() setfflag('FIntRenderShadowIntensity', origShadowIntensity) end)
        origShadowIntensity = nil
    end
    if flagOk('DFIntDebugFRMMinQualityLevel') and origRenderQuality then
        pcall(function() setfflag('DFIntDebugFRMMinQualityLevel', origRenderQuality) end)
        origRenderQuality = nil
    end
    if flagOk('FFlagNewLightAttenuation') and origLightAttenuation then
        pcall(function() setfflag('FFlagNewLightAttenuation', origLightAttenuation) end)
        origLightAttenuation = nil
    end
    if flagOk('DFIntTextureCompositorActiveTexturesBudget') and origTextureBudget then
        pcall(function() setfflag('DFIntTextureCompositorActiveTexturesBudget', origTextureBudget) end)
        origTextureBudget = nil
    end
end

-- Re-apply tweaks after respawn
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    if Toggles.PassiveLagEnabled    and Toggles.PassiveLagEnabled.Value    then applyPassiveLag()      end
    if Toggles.PhysicsTweaksEnabled and Toggles.PhysicsTweaksEnabled.Value then applyPhysicsTweaks()   end
    if Toggles.AnimThrottleEnabled  and Toggles.AnimThrottleEnabled.Value  then applyAnimThrottle()    end
    if Toggles.RenderTweaksEnabled  and Toggles.RenderTweaksEnabled.Value  then applyRenderTweaks()    end
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
        if FORCED_REPLICATION_STATES[newState] then forceSyncServerPos() end
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
            serverLbl.Text = 'SERVER (synced)'; clientLbl.Text = 'CLIENT'
        end
    end)
    connectCharacterStateTracking(LocalPlayer.Character)
end

local function stopViz()
    if vizConn then vizConn:Disconnect(); vizConn = nil end
    clientPart.Parent = nil; serverPart.Parent = nil
end

-- ================================================================
--  DELAYED DESYNC BURST LOOP
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
    burstWindowOpen   = false
    delayedLoopActive = false
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
    if not flagOk('NextGenReplicatorEnabledWrite4') then
        Library:Notify('Desync fflag not compatible with this executor!')
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
    if not flagOk('NextGenReplicatorEnabledWrite4') then
        Library:Notify('NextGenReplicatorEnabledWrite4 not compatible — run Compat Check first'); return
    end
    if desyncInitialized then Library:Notify('Already initialized — use the Enable toggle'); return end
    if not getLocalHRP() then Library:Notify('No character — spawn in first'); return end
    desyncInitialized = true
    State.desyncHbConn = RunService.Heartbeat:Connect(function()
        if not State.desyncActive then return end
        if replicatorIsOwned() then return end
        setReplicator(false)
    end)
    Library:Notify('Desync ready — use the Enable Desync toggle')
end

-- ================================================================
--  UI — MISC TAB
-- ================================================================
local CompatGrp     = Tabs.Misc:AddLeftGroupbox('FFlag Compatibility')
local DesyncGrp     = Tabs.Misc:AddLeftGroupbox('Desync')
local PassiveLagGrp = Tabs.Misc:AddLeftGroupbox('Passive Lag')
local FlagFeatGrp   = Tabs.Misc:AddLeftGroupbox('FFlag Features')
local SpinGrp       = Tabs.Misc:AddLeftGroupbox('SpinBot')
local MiscGrp       = Tabs.Misc:AddRightGroupbox('Misc')

-- ── Compatibility Check ───────────────────────────────────────────
CompatGrp:AddLabel('Run this before using any fflag features.')

CompatGrp:AddButton({ Text = 'Run Compatibility Check', Func = function()
    Library:Notify('Running fflag compatibility check...')

    local results = runCompatCheck()

    -- Count per feature
    local featurePass = {}
    local featureFail = {}
    for _, r in ipairs(results) do
        if r.compat then
            featurePass[r.feature] = (featurePass[r.feature] or 0) + 1
        else
            featureFail[r.feature] = (featureFail[r.feature] or 0) + 1
        end
    end

    -- Build summary string
    local lines = {}
    local seen  = {}
    for _, r in ipairs(results) do
        if not seen[r.feature] then
            seen[r.feature] = true
            local pass = featurePass[r.feature] or 0
            local fail = featureFail[r.feature] or 0
            local total = pass + fail
            local status = (pass == total) and '✓' or (pass > 0) and '~' or '✗'
            table.insert(lines, status .. ' ' .. r.feature .. ' (' .. pass .. '/' .. total .. ' flags)')
        end
    end

    local summary = table.concat(lines, '\n')
    Library:Notify('Compat results:\n' .. summary)

    -- Also print per-flag detail to console for full info
    for _, r in ipairs(results) do
        local status = r.compat and '[OK]' or '[NO]'
        print(status .. ' ' .. r.name .. ' | ' .. r.feature .. ' | ' .. r.reason)
    end

    -- Update label
    local totalPass = 0
    for _, r in ipairs(results) do if r.compat then totalPass = totalPass + 1 end end
    Library:Notify(totalPass .. '/' .. #results .. ' fflags compatible with your executor — see console for details')
end })

-- ── Desync ────────────────────────────────────────────────────────
DesyncGrp:AddButton({ Text = 'Initialize Desync', Func = initDesync })
DesyncGrp:AddLabel('Run compat check first. Initialize, then toggle.')

DesyncGrp:AddDropdown('DesyncMode', {
    Text    = 'Desync Mode',
    Default = 'Instant',
    Values  = { 'Instant', 'Delayed (Lag Mimic)' },
    Callback = function(v)
        State.desyncMode = (v == 'Instant') and 'instant' or 'delayed'
        if State.desyncActive then
            if State.desyncMode == 'instant' then
                stopDelayedLoop(); lastFlagState = nil; setReplicator(false)
                Library:Notify('Switched → Instant Desync')
            else
                burstWindowOpen = false; lastFlagState = nil; startDelayedLoop()
                local iv = Options.DelayedDesyncInterval and Options.DelayedDesyncInterval.Value or 5
                Library:Notify(('Switched → Lag Mimic (~%.0fs bursts)'):format(iv))
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

-- ── Passive Lag ───────────────────────────────────────────────────
PassiveLagGrp:AddToggle('PassiveLagEnabled', {
    Text = 'Enable Passive Lag', Default = false,
    Callback = function(v)
        if v then
            if not flagOk('DFIntS2PhysicsSendRate') and not flagOk('DFIntDataSenderMaxBandwidthBps') then
                Library:Notify('Passive Lag flags not compatible — run Compat Check')
                task.defer(function() Toggles.PassiveLagEnabled:SetValue(false) end); return
            end
            applyPassiveLag()
            Library:Notify('Passive Lag ON')
        else
            removePassiveLag()
            Library:Notify('Passive Lag OFF — fflags restored')
        end
    end,
})

PassiveLagGrp:AddSlider('PassiveLagSendRate', {
    Text = 'Physics Send Rate (hz)', Default = 3, Min = 1, Max = 20, Rounding = 0,
    Callback = function() refreshPassiveLag() end,
})

PassiveLagGrp:AddSlider('PassiveLagBandwidth', {
    Text = 'Max Bandwidth (bytes/s)', Default = 8000, Min = 1000, Max = 50000, Rounding = 0,
    Callback = function() refreshPassiveLag() end,
})

PassiveLagGrp:AddLabel('Stacks with Desync. Lower = more lag.')

-- ── FFlag Features ────────────────────────────────────────────────
-- Physics Tweaks
FlagFeatGrp:AddToggle('PhysicsTweaksEnabled', {
    Text = 'Physics Tweaks (Anti Rubber-Band)', Default = false,
    Callback = function(v)
        if v then
            local anyOk = flagOk('DFIntMaxMissedWorldStepsRemembered')
                       or flagOk('DFIntPhysicsSimPingAdaptive')
                       or flagOk('DFIntPhysicsReceiveNumReplicators')
            if not anyOk then
                Library:Notify('Physics flags not compatible — run Compat Check')
                task.defer(function() Toggles.PhysicsTweaksEnabled:SetValue(false) end); return
            end
            applyPhysicsTweaks()
        else
            removePhysicsTweaks()
        end
    end,
})
FlagFeatGrp:AddLabel('Zeros missed-step catchup + disables ping\nadaptive correction. Pairs well with desync.')

-- Animation Throttle
FlagFeatGrp:AddToggle('AnimThrottleEnabled', {
    Text = 'Animation Throttle', Default = false,
    Callback = function(v)
        if v then
            if not flagOk('DFIntReplicatorAnimationTrackLodBps') then
                Library:Notify('AnimTrackLodBps not compatible — run Compat Check')
                task.defer(function() Toggles.AnimThrottleEnabled:SetValue(false) end); return
            end
            applyAnimThrottle()
            Library:Notify('Animation throttle ON')
        else
            removeAnimThrottle()
            Library:Notify('Animation throttle OFF')
        end
    end,
})

FlagFeatGrp:AddSlider('AnimThrottleBps', {
    Text = 'Anim Bandwidth (bytes/s)', Default = 100, Min = 10, Max = 2000, Rounding = 0,
    Callback = function() refreshAnimThrottle() end,
})
FlagFeatGrp:AddLabel('Low = your animations barely replicate.\nYou appear to glide/stand still to others.')

-- Render Tweaks
FlagFeatGrp:AddToggle('RenderTweaksEnabled', {
    Text = 'Render Tweaks (FPS Boost)', Default = false,
    Callback = function(v)
        if v then
            local anyOk = flagOk('FIntRenderShadowIntensity')
                       or flagOk('DFIntDebugFRMMinQualityLevel')
                       or flagOk('FFlagNewLightAttenuation')
                       or flagOk('DFIntTextureCompositorActiveTexturesBudget')
            if not anyOk then
                Library:Notify('Render flags not compatible — run Compat Check')
                task.defer(function() Toggles.RenderTweaksEnabled:SetValue(false) end); return
            end
            applyRenderTweaks()
            Library:Notify('Render tweaks ON')
        else
            removeRenderTweaks()
            Library:Notify('Render tweaks OFF — restored')
        end
    end,
})

FlagFeatGrp:AddSlider('RenderQualityLevel', {
    Text = 'Min Render Quality (1=lowest)', Default = 1, Min = 1, Max = 21, Rounding = 0,
})
FlagFeatGrp:AddSlider('TextureBudget', {
    Text = 'Texture Budget (lower=faster)', Default = 8, Min = 1, Max = 64, Rounding = 0,
})
FlagFeatGrp:AddLabel('Kills shadows, reverts lighting model,\ndrops texture budget. Big FPS gains.')

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
