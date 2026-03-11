-- ================================================================
--  features/aimbot.lua
--  Contains: FOV circle, target selection, aim methods,
--            silent aim hook, triggerbot, main loop, and all UI.
--
--  Called from main.lua as:
--    load('features/aimbot.lua')(State, Tabs, Services, Library)
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService       = Services.RunService
local TweenService     = Services.TweenService
local UserInputService = Services.UserInputService
local Players          = Services.Players
local LocalPlayer      = Services.LocalPlayer

-- ── Helpers ────────────────────────────────────────────────────
local function getLocalHRP()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild('HumanoidRootPart')
end

local function GetPlayerName(str)
    if type(str) ~= 'string' or #str == 0 then return '' end
    local low = string.lower(str)
    for _, p in next, Players:GetPlayers() do
        if string.sub(string.lower(p.Name), 1, #low) == low then return p.Name end
    end
    return ''
end

local MathHandler = {}
function MathHandler:CalculateChance(pct)
    return type(pct) == 'number'
        and math.round(math.clamp(pct, 1, 100)) / 100 >= math.round(Random.new():NextNumber() * 100) / 100
        or false
end
function MathHandler:Abbreviate(n)
    if type(n) ~= 'number' then return tostring(n) end
    local abbr = { K=1e3, M=1e6, B=1e9, T=1e12 }
    local sel, res = 0, tostring(math.round(n))
    for k, v in next, abbr do
        if math.abs(n) >= v and v > sel then
            sel = v; res = tostring(math.round(n/v)) .. k
        end
    end
    return res
end

-- ================================================================
--  FOV CIRCLE
-- ================================================================
local AimCircle        = Drawing.new('Circle')
AimCircle.Transparency = 1
AimCircle.Visible      = false
AimCircle.Color        = Color3.fromRGB(255, 255, 255)
AimCircle.Radius       = 150
AimCircle.Thickness    = 1
AimCircle.NumSides     = 64

local CirclePosConn   = nil
local RainbowCircConn = nil

local function showCircle(v)
    AimCircle.Visible = v
    if CirclePosConn then CirclePosConn:Disconnect(); CirclePosConn = nil end
    if not v then return end
    CirclePosConn = RunService.Heartbeat:Connect(function()
        if Toggles.CircleCenter and Toggles.CircleCenter.Value then
            local vp = workspace.CurrentCamera.ViewportSize
            AimCircle.Position = Vector2.new(vp.X / 2, vp.Y / 2)
        else
            AimCircle.Position = UserInputService:GetMouseLocation()
        end
    end)
end

local function setRainbowCircle(v)
    if RainbowCircConn then RainbowCircConn:Disconnect(); RainbowCircConn = nil end
    if not v then
        if Options.CircleColor then AimCircle.Color = Options.CircleColor.Value end
        return
    end
    RainbowCircConn = RunService.RenderStepped:Connect(function()
        AimCircle.Color = Color3.fromHSV(tick() % 5 / 5, 1, 1)
    end)
end

-- ================================================================
--  TARGET SELECTION
-- ================================================================
local function getAimbotTarget()
    local cam = workspace.CurrentCamera; if not cam then return nil end
    local mousePos = UserInputService:GetMouseLocation()

    local useFOV   = Toggles.AimbotUseFOV      and Toggles.AimbotUseFOV.Value
    local fov      = Options.AimbotFOV          and Options.AimbotFOV.Value          or 150
    local maxDist  = Options.MaxAimbotDist      and Options.MaxAimbotDist.Value      or 0
    local priority = Options.AimbotPriority     and Options.AimbotPriority.Value     or 'Closest to Crosshair'
    local partName = Options.AimPart            and Options.AimPart.Value            or 'Head'

    local doTeam     = Toggles.AimbotTeamCheck     and Toggles.AimbotTeamCheck.Value
    local doAlive    = Toggles.AliveCheck          and Toggles.AliveCheck.Value
    local doGod      = Toggles.GodCheck            and Toggles.GodCheck.Value
    local doFriend   = Toggles.FriendCheck         and Toggles.FriendCheck.Value
    local doFollow   = Toggles.FollowCheck         and Toggles.FollowCheck.Value
    local doVerified = Toggles.VerifiedBadgeCheck  and Toggles.VerifiedBadgeCheck.Value
    local doWall     = Toggles.WallCheck           and Toggles.WallCheck.Value
    local doWater    = Toggles.WaterCheck          and Toggles.WaterCheck.Value
    local doVis      = Toggles.AimbotVisCheck      and Toggles.AimbotVisCheck.Value
    local doMag      = Toggles.MagnitudeCheck      and Toggles.MagnitudeCheck.Value
    local magDist    = Options.TriggerMagnitude    and Options.TriggerMagnitude.Value or 500
    local doTrans    = Toggles.TransparencyCheck   and Toggles.TransparencyCheck.Value
    local transT     = Options.IgnoredTransparency and Options.IgnoredTransparency.Value or 0.5
    local doWGrp     = Toggles.WhitelistGroupCheck and Toggles.WhitelistGroupCheck.Value
    local wGrpId     = Options.WhitelistGroupId    and tonumber(Options.WhitelistGroupId.Value) or 0
    local doBGrp     = Toggles.BlacklistGroupCheck and Toggles.BlacklistGroupCheck.Value
    local bGrpId     = Options.BlacklistGroupId    and tonumber(Options.BlacklistGroupId.Value) or 0
    local doIgnored  = Toggles.IgnoredPlayersCheck and Toggles.IgnoredPlayersCheck.Value
    local doTarget   = Toggles.TargetPlayersCheck  and Toggles.TargetPlayersCheck.Value

    local myHRP = getLocalHRP()
    local best  = {}

    for _, p in next, Players:GetPlayers() do
        if p == LocalPlayer then continue end
        if table.find(State.whitelistedIds, p.UserId) then continue end
        if doTeam and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then continue end
        if doFriend then
            local ok, isFriend = pcall(function() return p:IsFriendsWith(LocalPlayer.UserId) end)
            if ok and isFriend then continue end
        end
        if doFollow   and p.FollowUserId == LocalPlayer.UserId then continue end
        if doVerified and p.HasVerifiedBadge then continue end
        if doIgnored  and State.ignoredPlayers[p.Name] then continue end
        if doTarget   and not State.targetPlayers[p.Name] then continue end
        if doWGrp and wGrpId > 0 then
            local ok, inGroup = pcall(function() return p:IsInGroup(wGrpId) end)
            if ok and inGroup then continue end
        end
        if doBGrp and bGrpId > 0 then
            local ok, inGroup = pcall(function() return p:IsInGroup(bGrpId) end)
            if ok and not inGroup then continue end
        end

        local char = p.Character
        local part = char and (char:FindFirstChild(partName) or char:FindFirstChild('Head'))
        local head = char and char:FindFirstChild('Head')
        local hrp  = char and char:FindFirstChild('HumanoidRootPart')
        local hum  = char and char:FindFirstChildWhichIsA('Humanoid')
        if not (char and part and hrp and hum) then continue end
        if hum.Health <= 0 then continue end
        if doAlive and hum.Health <= 0 then continue end
        if doGod and (hum.Health >= 1e36 or char:FindFirstChildWhichIsA('ForceField')) then continue end
        if doTrans and head and head:IsA('BasePart') and head.Transparency >= transT then continue end

        if doWall and myHRP then
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { LocalPlayer.Character }
            params.IgnoreWater = not doWater
            local dir = part.Position - myHRP.Position
            local result = workspace:Raycast(myHRP.Position, dir, params)
            if result and result.Instance and not result.Instance:FindFirstAncestor(p.Name) then continue end
        elseif doVis then
            local origin = cam.CFrame.Position
            local ray = Ray.new(origin, (part.Position - origin).Unit * 5000)
            local hit = workspace:FindPartOnRayWithIgnoreList(ray, { LocalPlayer.Character })
            if hit and not hit:IsDescendantOf(char) then continue end
        end

        local sp, onScreen = cam:WorldToViewportPoint(part.Position)
        if not onScreen then continue end

        local d2D = (Vector2.new(sp.X, sp.Y) - mousePos).Magnitude
        local d3D = (cam.CFrame.Position - hrp.Position).Magnitude

        if useFOV and d2D > fov then continue end
        if maxDist > 0 and d3D > maxDist then continue end
        if doMag and myHRP and (part.Position - myHRP.Position).Magnitude > magDist then continue end

        table.insert(best, { char = char, d2D = d2D, d3D = d3D, hp = hum.Health })
    end

    if #best == 0 then return nil end
    if     priority == 'Closest Distance' then table.sort(best, function(a,b) return a.d3D < b.d3D end)
    elseif priority == 'Lowest Health'    then table.sort(best, function(a,b) return a.hp  < b.hp  end)
    else                                       table.sort(best, function(a,b) return a.d2D < b.d2D end)
    end
    return best[1].char
end

-- ================================================================
--  AIM POSITION  (offset + noise + prediction)
-- ================================================================
local function getAimPos(char)
    local partName = Options.AimPart and Options.AimPart.Value or 'Head'
    local part = char:FindFirstChild(partName) or char:FindFirstChild('Head')
    if not part or not part:IsA('BasePart') then return nil end

    local hum   = char:FindFirstChildWhichIsA('Humanoid')
    local myHRP = getLocalHRP()
    local pred  = Options.AimbotPrediction and Options.AimbotPrediction.Value or 0

    local offset = Vector3.zero
    if Toggles.UseOffset and Toggles.UseOffset.Value then
        local otype  = Options.OffsetType          and Options.OffsetType.Value          or 'Static'
        local sInc   = Options.StaticOffsetIncr    and Options.StaticOffsetIncr.Value    or 10
        local dInc   = Options.DynamicOffsetIncr   and Options.DynamicOffsetIncr.Value   or 10
        local isAuto = Toggles.AutoOffset          and Toggles.AutoOffset.Value
        local maxA   = Options.MaxAutoOffset       and Options.MaxAutoOffset.Value       or 50
        if isAuto and myHRP then
            local dist = (part.Position - myHRP.Position).Magnitude
            local yAuto = math.min(part.Position.Y * sInc * dist / 1000, maxA)
            local dyn   = hum and hum.MoveDirection * dInc / 10 or Vector3.zero
            offset = Vector3.new(0, yAuto, 0) + dyn
        elseif otype == 'Static' then
            offset = Vector3.new(0, part.Position.Y * sInc / 10, 0)
        elseif otype == 'Dynamic' and hum then
            offset = hum.MoveDirection * dInc / 10
        elseif otype == 'Static & Dynamic' and hum then
            offset = Vector3.new(0, part.Position.Y * sInc / 10, 0) + hum.MoveDirection * dInc / 10
        end
    else
        local y = Options.AimOffsetY and Options.AimOffsetY.Value or 0
        offset = Vector3.new(0, y, 0)
    end

    local noise = Vector3.zero
    if Toggles.UseNoise and Toggles.UseNoise.Value then
        local f = (Options.NoiseFrequency and Options.NoiseFrequency.Value or 50) / 100
        noise = Vector3.new(
            Random.new():NextNumber(-f, f),
            Random.new():NextNumber(-f, f),
            Random.new():NextNumber(-f, f)
        )
    end

    local base = part.Position + offset + noise
    if pred > 0 then base = base + part.AssemblyLinearVelocity * (pred / 100) end
    return base
end

-- ================================================================
--  AIM METHODS
-- ================================================================
local function resetCameraAim()
    if State.activeTween then State.activeTween:Cancel(); State.activeTween = nil end
    if State.savedMouseSens ~= nil then
        UserInputService.MouseDeltaSensitivity = State.savedMouseSens
        State.savedMouseSens = nil
    end
end

local function doMouseAim(char)
    local cam = workspace.CurrentCamera; if not cam then return end
    local pos = getAimPos(char);         if not pos then return end
    local sp, vis = cam:WorldToViewportPoint(pos); if not vis then return end
    local smooth
    if Toggles.UseSensitivity and Toggles.UseSensitivity.Value then
        smooth = math.max((Options.Sensitivity and Options.Sensitivity.Value or 50) / 5, 1)
    else
        smooth = math.max(Options.AimbotSmoothing and Options.AimbotSmoothing.Value or 5, 1)
    end
    local delta = (Vector2.new(sp.X, sp.Y) - UserInputService:GetMouseLocation()) / smooth
    mousemoverel(delta.X, delta.Y)
end

local function doCameraAim(char)
    local cam = workspace.CurrentCamera; if not cam then return end
    local pos = getAimPos(char);         if not pos then return end
    if Toggles.UseSensitivity and Toggles.UseSensitivity.Value then
        local sens = math.clamp(Options.Sensitivity and Options.Sensitivity.Value or 50, 9, 99) / 100
        if State.savedMouseSens == nil then
            State.savedMouseSens = UserInputService.MouseDeltaSensitivity
            UserInputService.MouseDeltaSensitivity = 0
        end
        if State.activeTween then State.activeTween:Cancel() end
        State.activeTween = TweenService:Create(cam,
            TweenInfo.new(sens, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
            { CFrame = CFrame.new(cam.CFrame.Position, pos) })
        State.activeTween:Play()
    else
        local smooth = math.max(Options.AimbotSmoothing and Options.AimbotSmoothing.Value or 5, 1)
        cam.CFrame = cam.CFrame:Lerp(CFrame.new(cam.CFrame.Position, pos), 1 / smooth)
    end
end

-- ================================================================
--  SPINBOT
-- ================================================================
local function handleSpinBot()
    if not State.Spinning then return end
    local char = LocalPlayer.Character; if not char then return end
    local pName = Options.SpinPart and Options.SpinPart.Value or 'HumanoidRootPart'
    local part  = char:FindFirstChild(pName)
    if part and part:IsA('BasePart') then
        local vel = Options.SpinVelocity and Options.SpinVelocity.Value or 50
        part.CFrame = part.CFrame * CFrame.fromEulerAnglesXYZ(0, math.rad(vel), 0)
    end
end

-- ================================================================
--  TRIGGERBOT
-- ================================================================
local function handleTriggerBot()
    if not State.Triggering then return end
    local fn = rawget(getfenv and getfenv() or {}, 'mouse1click') or mouse1click
    if not fn then return end
    if Toggles.SmartTriggerBot and Toggles.SmartTriggerBot.Value and not State.currentTarget then return end
    local mouse = LocalPlayer:GetMouse()
    if not mouse.Target then return end
    local model = mouse.Target:FindFirstAncestorWhichIsA('Model')
    if not model then return end
    if not Players:GetPlayerFromCharacter(model) then return end
    local chance = Options.TriggerChance and Options.TriggerChance.Value or 100
    if MathHandler:CalculateChance(chance) then fn() end
end

-- ================================================================
--  SILENT AIM HOOK
-- ================================================================
do
    local env  = getfenv and getfenv() or {}
    local hm   = rawget(env, 'hookmetamethod')
    local nc   = rawget(env, 'newcclosure')
    local chk  = rawget(env, 'checkcaller')
    local gnm  = rawget(env, 'getnamecallmethod')
    if hm and nc and chk and gnm then
        local mouse = LocalPlayer:GetMouse()
        local function silentActive()
            return Options.AimbotMode and Options.AimbotMode.Value == 'Silent' and State.currentTarget ~= nil
        end
        local function getVP()
            if not State.currentTarget then return nil end
            local cam = workspace.CurrentCamera; if not cam then return nil end
            local pn  = Options.AimPart and Options.AimPart.Value or 'Head'
            local p   = State.currentTarget:FindFirstChild(pn) or State.currentTarget:FindFirstChild('Head')
            if not p then return nil end
            local pos = getAimPos(State.currentTarget) or p.Position
            local sp, vis = cam:WorldToViewportPoint(pos)
            return vis and Vector2.new(sp.X, sp.Y) or nil
        end
        local function getWP()
            if not State.currentTarget then return nil end
            local pn = Options.AimPart and Options.AimPart.Value or 'Head'
            local p  = State.currentTarget:FindFirstChild(pn) or State.currentTarget:FindFirstChild('Head')
            if not p then return nil end
            return getAimPos(State.currentTarget) or p.Position
        end
        local OldIdx; OldIdx = hm(game, '__index', nc(function(self, idx)
            if not chk() and silentActive() then
                if self == mouse then
                    local vp, wp = getVP(), getWP()
                    if idx == 'Hit' or idx == 'hit' then
                        local pn = Options.AimPart and Options.AimPart.Value or 'Head'
                        local p  = State.currentTarget and (State.currentTarget:FindFirstChild(pn) or State.currentTarget:FindFirstChild('Head'))
                        if p then return p.CFrame end
                    elseif idx == 'Target' or idx == 'target' then
                        local pn = Options.AimPart and Options.AimPart.Value or 'Head'
                        return State.currentTarget and (State.currentTarget:FindFirstChild(pn) or State.currentTarget:FindFirstChild('Head'))
                    elseif vp and (idx == 'X' or idx == 'x') then return vp.X
                    elseif vp and (idx == 'Y' or idx == 'y') then return vp.Y
                    end
                end
            end
            return OldIdx(self, idx)
        end))
        local OldNC; OldNC = hm(game, '__namecall', nc(function(...)
            local method = gnm()
            local args = { ... }
            if not chk() and silentActive() then
                local self = args[1]
                local wp = getWP()
                if wp then
                    if self == UserInputService and (method == 'GetMouseLocation' or method == 'getMouseLocation') then
                        local vp = getVP(); if vp then return vp end
                    elseif self == workspace and method == 'Raycast' and type(args[2]) == 'userdata' then
                        args[3] = (wp - args[2]).Unit * (wp - args[2]).Magnitude
                        return OldNC(table.unpack(args))
                    elseif self == workspace and (method == 'FindPartOnRay' or method == 'FindPartOnRayWithIgnoreList' or method == 'FindPartOnRayWithWhitelist') and type(args[2]) == 'userdata' then
                        local orig = args[2].Origin
                        args[2] = Ray.new(orig, (wp - orig).Unit * (wp - orig).Magnitude)
                        return OldNC(table.unpack(args))
                    end
                end
            end
            return OldNC(...)
        end))
    end
end

-- ================================================================
--  AIMBOT ACTIVE CHECK + MAIN LOOP
-- ================================================================
local function isAimbotActive()
    if Toggles.AimbotEnabled and Toggles.AimbotEnabled.Value then return true end
    if Toggles.OnePressAimingMode and Toggles.OnePressAimingMode.Value then
        return State.aimOnePressActive
    end
    local keyHeld = Options.AimbotKey and Options.AimbotKey:GetState()
    return keyHeld and true or false
end

local AimbotLoopConn = nil
local function startAimbotLoop()
    if AimbotLoopConn then AimbotLoopConn:Disconnect() end
    AimbotLoopConn = RunService.RenderStepped:Connect(function()
        -- SpinBot state
        if Toggles.SpinBotEnabled and Toggles.SpinBotEnabled.Value then
            local noKey = not Options.SpinKey or Options.SpinKey.Value == 'None'
            if Toggles.OnePressSpinningMode and Toggles.OnePressSpinningMode.Value then
                local cur = Options.SpinKey and Options.SpinKey:GetState() or false
                if cur and not State.spinKeyLastState then State.Spinning = not State.Spinning end
                State.spinKeyLastState = cur
            else
                State.Spinning = noKey or (Options.SpinKey and Options.SpinKey:GetState() or false)
                State.spinKeyLastState = false
            end
        else
            State.Spinning = false; State.spinKeyLastState = false
        end

        -- TriggerBot state
        if Toggles.TriggerBotEnabled and Toggles.TriggerBotEnabled.Value then
            local noKey = not Options.TriggerKey or Options.TriggerKey.Value == 'None'
            if Toggles.OnePressTriggering and Toggles.OnePressTriggering.Value then
                local cur = Options.TriggerKey and Options.TriggerKey:GetState() or false
                if cur and not State.trigKeyLastState then State.Triggering = not State.Triggering end
                State.trigKeyLastState = cur
            else
                State.Triggering = noKey or (Options.TriggerKey and Options.TriggerKey:GetState() or false)
                State.trigKeyLastState = false
            end
        else
            State.Triggering = false; State.trigKeyLastState = false
        end

        handleSpinBot()
        handleTriggerBot()

        -- One-press edge detect
        if Toggles.OnePressAimingMode and Toggles.OnePressAimingMode.Value then
            local cur = Options.AimbotKey and Options.AimbotKey:GetState() or false
            if cur and not State.aimKeyLastState then
                State.aimOnePressActive = not State.aimOnePressActive
                if not State.aimOnePressActive then resetCameraAim() end
            end
            State.aimKeyLastState = cur
        else
            State.aimKeyLastState = false
        end

        if not isAimbotActive() then
            if State.currentTarget then State.currentTarget = nil; resetCameraAim() end
            return
        end

        local hc = Options.AimbotHitchance and Options.AimbotHitchance.Value or 100
        if math.random(1, 100) > hc then return end

        local stickyOn = Toggles.StickyAimbot and Toggles.StickyAimbot.Value
        if not stickyOn and State.stickyTarget then State.stickyTarget = nil end
        if State.stickyTarget then
            local sHum = State.stickyTarget:FindFirstChildWhichIsA('Humanoid')
            if not State.stickyTarget.Parent or not sHum or sHum.Health <= 0 then
                State.stickyTarget = nil
            end
        end

        local char
        if stickyOn then
            if not State.stickyTarget then State.stickyTarget = getAimbotTarget() end
            char = State.stickyTarget
        else
            char = getAimbotTarget()
        end

        if not char then State.currentTarget = nil; return end

        if Toggles.OffAimbotAfterKill and Toggles.OffAimbotAfterKill.Value then
            local hum = char:FindFirstChildWhichIsA('Humanoid')
            if hum and hum.Health <= 0 then
                State.currentTarget = nil; State.stickyTarget = nil; State.aimOnePressActive = false
                resetCameraAim(); return
            end
        end

        State.currentTarget = char
        local mode = Options.AimbotMode and Options.AimbotMode.Value or 'Third Person (Mouse)'
        if     mode == 'First Person (Camera)' then doCameraAim(char)
        elseif mode == 'Silent'                then -- hook handles redirect
        else                                        doMouseAim(char)
        end
    end)
end

-- ================================================================
--  THIRD PERSON CAMERA
-- ================================================================
local ThirdPersonConn = nil
local function applyThirdPerson(v)
    if ThirdPersonConn then ThirdPersonConn:Disconnect(); ThirdPersonConn = nil end
    local cam = workspace.CurrentCamera; if not cam then return end
    if not v then cam.CameraType = Enum.CameraType.Custom; return end
    cam.CameraType = Enum.CameraType.Scriptable
    ThirdPersonConn = RunService.RenderStepped:Connect(function()
        if not Toggles.ThirdPerson or not Toggles.ThirdPerson.Value then return end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild('HumanoidRootPart')
        if not root then return end
        local dist   = Options.ThirdPersonDist and Options.ThirdPersonDist.Value or 8
        local behind = root.CFrame * CFrame.new(0, 2, dist)
        cam.CFrame   = CFrame.new(behind.Position, root.Position + Vector3.new(0, 1.5, 0))
    end)
end

-- ================================================================
--  UI — AIMBOT TAB
-- ================================================================
local AimbotGrp  = Tabs.Aimbot:AddLeftGroupbox('Aimbot')
local AimCfgGrp  = Tabs.Aimbot:AddRightGroupbox('Config')
local ChecksGrp  = Tabs.Aimbot:AddLeftGroupbox('Checks')
local PlayersGrp = Tabs.Aimbot:AddLeftGroupbox('Player Lists')
local TriggerGrp = Tabs.Aimbot:AddRightGroupbox('TriggerBot')

-- Core
AimbotGrp:AddToggle('AimbotEnabled',      { Text = 'Always-On Aimbot',     Default = false })
AimbotGrp:AddLabel('Aim Key'):AddKeyPicker('AimbotKey', { Default = 'None', Text = 'Aim Key', Mode = 'Hold' })
AimbotGrp:AddToggle('OnePressAimingMode', { Text = 'One-Press Mode',        Default = false })
AimbotGrp:AddDropdown('AimbotMode', {
    Text = 'Aim Mode', Default = 1,
    Values = { 'Third Person (Mouse)', 'First Person (Camera)', 'Silent' },
})
AimbotGrp:AddDropdown('AimbotPriority', {
    Text = 'Target Priority', Default = 1,
    Values = { 'Closest to Crosshair', 'Closest Distance', 'Lowest Health' },
})

-- Aim Part
AimbotGrp:AddDropdown('AimPart', { Text = 'Aim Part', Default = 1, Values = State.aimPartValues })
AimbotGrp:AddInput('AddAimPartInput',    { Default = '', Text = 'Add Aim Part',    Placeholder = 'Part name...' })
AimbotGrp:AddButton({ Text = 'Add Aim Part', Func = function()
    local v = Options.AddAimPartInput and Options.AddAimPartInput.Value or ''
    if #v > 0 and not table.find(State.aimPartValues, v) then
        table.insert(State.aimPartValues, v)
        Options.AimPart:SetValues(State.aimPartValues)
        Options.AimPart:SetValue(v)
    end
end })
AimbotGrp:AddInput('RemoveAimPartInput', { Default = '', Text = 'Remove Aim Part', Placeholder = 'Part name...' })
AimbotGrp:AddButton({ Text = 'Remove Aim Part', Func = function()
    local v = Options.RemoveAimPartInput and Options.RemoveAimPartInput.Value or ''
    local i = table.find(State.aimPartValues, v)
    if i then table.remove(State.aimPartValues, i); Options.AimPart:SetValues(State.aimPartValues) end
end })
AimbotGrp:AddToggle('RandomAimPart',      { Text = 'Random Aim Part (1s)',  Default = false })
AimbotGrp:AddToggle('OffAimbotAfterKill', { Text = 'Off After Kill',         Default = false })
AimbotGrp:AddToggle('StickyAimbot',       { Text = 'Sticky Target',          Default = false })

-- Camera
AimbotGrp:AddLabel('── Camera ──')
AimbotGrp:AddToggle('ThirdPerson',    { Text = 'Third Person',      Default = false, Callback = applyThirdPerson })
AimbotGrp:AddSlider('ThirdPersonDist',{ Text = 'Camera Distance',   Default = 8,   Min = 3,  Max = 30,  Rounding = 0 })
AimbotGrp:AddToggle('LockFirstPerson',{
    Text = 'Force First Person', Default = false,
    Callback = function(v)
        LocalPlayer.CameraMaxZoomDistance = v and 0.5 or 128
        LocalPlayer.CameraMinZoomDistance = 0.5
    end,
})
AimbotGrp:AddSlider('CameraFOV',{
    Text = 'Camera FOV', Default = 70, Min = 30, Max = 120, Rounding = 0,
    Callback = function(v) workspace.CurrentCamera.FieldOfView = v end,
})

-- Whitelist
AimbotGrp:AddLabel('── Whitelist ──')
local function refreshWhitelistDropdown()
    if not Options.AimbotWhitelistPlayers then return end
    local names = {}
    for _, p in next, Players:GetPlayers() do
        if p ~= LocalPlayer then table.insert(names, p.Name) end
    end
    Options.AimbotWhitelistPlayers:SetValues(#names > 0 and names or { '(none)' })
end
AimbotGrp:AddDropdown('AimbotWhitelistPlayers', { Text = 'Player', Default = 1, Values = { '(none)' } })
AimbotGrp:AddButton({ Text = 'Refresh',      Func = refreshWhitelistDropdown })
AimbotGrp:AddButton({ Text = 'Add Selected', Func = function()
    local name = Options.AimbotWhitelistPlayers.Value
    if not name or name == '(none)' then return end
    local p = Players:FindFirstChild(name)
    if p and not table.find(State.whitelistedIds, p.UserId) then
        table.insert(State.whitelistedIds, p.UserId); Library:Notify('Whitelisted: ' .. name)
    end
end })
AimbotGrp:AddInput('AimbotWhitelistBox', { Default = '', Numeric = true, Text = 'Add by UserId', Placeholder = 'UserId...' })
AimbotGrp:AddButton({ Text = 'Add UserId', Func = function()
    local id = tonumber(Options.AimbotWhitelistBox and Options.AimbotWhitelistBox.Value)
    if not id then Library:Notify('Invalid UserId'); return end
    if not table.find(State.whitelistedIds, id) then table.insert(State.whitelistedIds, id); Library:Notify('Whitelisted: ' .. id) end
end })
AimbotGrp:AddButton({ Text = 'Clear Whitelist', Func = function() table.clear(State.whitelistedIds); Library:Notify('Whitelist cleared') end })

Players.PlayerAdded:Connect(refreshWhitelistDropdown)
Players.PlayerRemoving:Connect(refreshWhitelistDropdown)
refreshWhitelistDropdown()

-- Checks
ChecksGrp:AddToggle('AimbotTeamCheck',    { Text = 'Team Check',              Default = true  })
ChecksGrp:AddToggle('AliveCheck',         { Text = 'Alive Check',             Default = false })
ChecksGrp:AddToggle('GodCheck',           { Text = 'God Check (ForceField)',   Default = false })
ChecksGrp:AddToggle('FriendCheck',        { Text = 'Friend Check',            Default = false })
ChecksGrp:AddToggle('FollowCheck',        { Text = 'Follow Check',            Default = false })
ChecksGrp:AddToggle('VerifiedBadgeCheck', { Text = 'Verified Badge Check',    Default = false })
ChecksGrp:AddLabel('── Wall / Visibility ──')
ChecksGrp:AddToggle('WallCheck',      { Text = 'Wall Check (Raycast)',       Default = false })
ChecksGrp:AddToggle('WaterCheck',     { Text = 'Ignore Water in Wall Check', Default = false })
ChecksGrp:AddToggle('AimbotVisCheck', { Text = 'Legacy Visibility Check',    Default = false })
ChecksGrp:AddLabel('── Advanced ──')
ChecksGrp:AddToggle('MagnitudeCheck',     { Text = 'Magnitude Check',       Default = false })
ChecksGrp:AddSlider('TriggerMagnitude',   { Text = 'Max Magnitude (studs)', Default = 500, Min = 10, Max = 1000, Rounding = 1 })
ChecksGrp:AddToggle('TransparencyCheck',  { Text = 'Transparency Check',    Default = false })
ChecksGrp:AddSlider('IgnoredTransparency',{ Text = 'Max Transparency',      Default = 0.5,  Min = 0.1, Max = 1, Rounding = 1 })
ChecksGrp:AddLabel('── Group Checks ──')
ChecksGrp:AddToggle('WhitelistGroupCheck', { Text = 'Skip players in Group',     Default = false })
ChecksGrp:AddInput('WhitelistGroupId',     { Default = '0', Numeric = true, Text = 'Whitelist Group ID', Placeholder = 'Group ID...' })
ChecksGrp:AddToggle('BlacklistGroupCheck', { Text = 'Only target outside Group', Default = false })
ChecksGrp:AddInput('BlacklistGroupId',     { Default = '0', Numeric = true, Text = 'Blacklist Group ID', Placeholder = 'Group ID...' })

-- Player Lists
PlayersGrp:AddToggle('IgnoredPlayersCheck', { Text = 'Ignored Players Check', Default = false })
PlayersGrp:AddInput('AddIgnoredInput',      { Default = '', Text = 'Add Ignored Player',    Placeholder = 'Name / @Name...' })
PlayersGrp:AddButton({ Text = 'Add Ignored Player', Func = function()
    local raw  = Options.AddIgnoredInput and Options.AddIgnoredInput.Value or ''
    local name = #GetPlayerName(raw) > 0 and GetPlayerName(raw) or raw
    if #name > 0 then State.ignoredPlayers[name] = true; Library:Notify('Ignored: ' .. name) end
end })
PlayersGrp:AddInput('RemoveIgnoredInput',   { Default = '', Text = 'Remove Ignored Player', Placeholder = 'Name...' })
PlayersGrp:AddButton({ Text = 'Remove Ignored Player', Func = function()
    local name = Options.RemoveIgnoredInput and Options.RemoveIgnoredInput.Value or ''
    State.ignoredPlayers[name] = nil; Library:Notify('Unignored: ' .. name)
end })
PlayersGrp:AddButton({ Text = 'Clear Ignored List', Func = function()
    State.ignoredPlayers = {}; Library:Notify('Ignored list cleared')
end })

PlayersGrp:AddLabel('── Target Players (only aim at these) ──')
PlayersGrp:AddToggle('TargetPlayersCheck',  { Text = 'Target Players Check', Default = false })
PlayersGrp:AddInput('AddTargetInput',       { Default = '', Text = 'Add Target Player',    Placeholder = 'Name / @Name...' })
PlayersGrp:AddButton({ Text = 'Add Target Player', Func = function()
    local raw  = Options.AddTargetInput and Options.AddTargetInput.Value or ''
    local name = #GetPlayerName(raw) > 0 and GetPlayerName(raw) or raw
    if #name > 0 then State.targetPlayers[name] = true; Library:Notify('Targeted: ' .. name) end
end })
PlayersGrp:AddInput('RemoveTargetInput',    { Default = '', Text = 'Remove Target Player', Placeholder = 'Name...' })
PlayersGrp:AddButton({ Text = 'Remove Target Player', Func = function()
    local name = Options.RemoveTargetInput and Options.RemoveTargetInput.Value or ''
    State.targetPlayers[name] = nil; Library:Notify('Removed from targets: ' .. name)
end })
PlayersGrp:AddButton({ Text = 'Clear Target List', Func = function()
    State.targetPlayers = {}; Library:Notify('Target list cleared')
end })

-- Config (right column)
AimCfgGrp:AddToggle('AimbotUseFOV', { Text = 'Use FOV Filter', Default = true })
AimCfgGrp:AddSlider('AimbotFOV',{
    Text = 'FOV Radius (px)', Default = 150, Min = 10, Max = 800, Rounding = 0,
    Callback = function(v) AimCircle.Radius = v end,
})
AimCfgGrp:AddSlider('MaxAimbotDist',   { Text = 'Max Range (studs)', Default = 0,   Min = 0,   Max = 3000, Rounding = 0 })
AimCfgGrp:AddSlider('AimbotSmoothing', { Text = 'Smoothing',         Default = 5,   Min = 1,   Max = 100,  Rounding = 0 })
AimCfgGrp:AddSlider('AimbotPrediction',{ Text = 'Prediction',        Default = 0,   Min = 0,   Max = 100,  Rounding = 0 })
AimCfgGrp:AddSlider('AimbotHitchance', { Text = 'Hit Chance (%)',     Default = 100, Min = 1,   Max = 100,  Rounding = 0 })
AimCfgGrp:AddSlider('AimOffsetY',      { Text = 'Vertical Offset',   Default = 0,   Min = -5,  Max = 5,    Rounding = 1 })
AimCfgGrp:AddLabel('── Sensitivity & Noise ──')
AimCfgGrp:AddToggle('UseSensitivity', { Text = 'Use Sensitivity',      Default = false })
AimCfgGrp:AddSlider('Sensitivity',    { Text = 'Sensitivity',           Default = 50, Min = 1, Max = 100, Rounding = 1 })
AimCfgGrp:AddToggle('UseNoise',       { Text = 'Camera Shake (Noise)', Default = false })
AimCfgGrp:AddSlider('NoiseFrequency', { Text = 'Noise Frequency',      Default = 50, Min = 1, Max = 100, Rounding = 1 })
AimCfgGrp:AddLabel('── Aim Offset ──')
AimCfgGrp:AddToggle('UseOffset',         { Text = 'Use Aim Offset', Default = false })
AimCfgGrp:AddDropdown('OffsetType',      { Text = 'Offset Type', Default = 1, Values = { 'Static', 'Dynamic', 'Static & Dynamic' } })
AimCfgGrp:AddSlider('StaticOffsetIncr',  { Text = 'Static Increment',  Default = 10, Min = 1, Max = 50, Rounding = 1 })
AimCfgGrp:AddSlider('DynamicOffsetIncr', { Text = 'Dynamic Increment', Default = 10, Min = 1, Max = 50, Rounding = 1 })
AimCfgGrp:AddToggle('AutoOffset',        { Text = 'Auto Offset',       Default = false })
AimCfgGrp:AddSlider('MaxAutoOffset',     { Text = 'Max Auto Offset',   Default = 50, Min = 1, Max = 200, Rounding = 1 })
AimCfgGrp:AddLabel('── FOV Circle ──')
AimCfgGrp:AddToggle('ShowCircle',   { Text = 'Show FOV Circle',       Default = true,  Callback = showCircle })
AimCfgGrp:AddToggle('CircleCenter', { Text = 'Lock to Screen Center', Default = false })
AimCfgGrp:AddLabel('Circle Color'):AddColorPicker('CircleColor', {
    Default = Color3.fromRGB(255,255,255), Title = 'Circle Color',
    Callback = function(v) if not (Toggles.RainbowCircle and Toggles.RainbowCircle.Value) then AimCircle.Color = v end end,
})
AimCfgGrp:AddToggle('RainbowCircle',   { Text = 'Rainbow Circle', Default = false, Callback = setRainbowCircle })
AimCfgGrp:AddToggle('FillCircle',      { Text = 'Fill Circle',    Default = false, Callback = function(v) AimCircle.Filled = v end })
AimCfgGrp:AddSlider('CircleThickness', { Text = 'Thickness', Default = 1,   Min = 1,  Max = 20,  Rounding = 0, Callback = function(v) AimCircle.Thickness  = v end })
AimCfgGrp:AddSlider('CircleOpacity',   { Text = 'Opacity',   Default = 100, Min = 0,  Max = 100, Rounding = 0, Callback = function(v) AimCircle.Transparency = v/100 end })
AimCfgGrp:AddSlider('CircleNumSides',  { Text = 'Smoothness',Default = 64,  Min = 4,  Max = 256, Rounding = 0, Callback = function(v) AimCircle.NumSides = v end })

-- TriggerBot
TriggerGrp:AddToggle('TriggerBotEnabled', { Text = 'Enable TriggerBot', Default = false })
TriggerGrp:AddLabel('Trigger Key'):AddKeyPicker('TriggerKey', { Default = 'None', Text = 'Trigger Key', Mode = 'Hold' })
TriggerGrp:AddToggle('OnePressTriggering',{ Text = 'One-Press Mode',               Default = false })
TriggerGrp:AddToggle('SmartTriggerBot',   { Text = 'Smart Mode (only while aiming)', Default = false })
TriggerGrp:AddSlider('TriggerChance',     { Text = 'Trigger Chance (%)', Default = 100, Min = 1, Max = 100, Rounding = 1 })

startAimbotLoop()

end -- return function
