-- ================================================================
--  features/bloodlines.lua
--  Rebuilt against the user's dump (Game_Dump.txt, 2026-11-22 21:29:49,
--  PlaceId 10266164381, PlaceVersion 1669). Every game-specific value
--  lives in BUILD below with its source; anything marked UNVERIFIED was
--  copied from decompiled client code and has not been run in game.
-- ================================================================

local Pure = {}

function Pure.isFinite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

function Pure.nameMatches(name, filter)
    if filter == nil or filter == '' then return true end
    return string.find(string.lower(name), string.lower(filter), 1, true) ~= nil
end

-- candidates: array of { x = number, y = number, z = number, ... }
function Pure.pickNearest(candidates, ox, oy, oz)
    local best, bestSq
    for _, c in ipairs(candidates) do
        if Pure.isFinite(c.x) and Pure.isFinite(c.y) and Pure.isFinite(c.z) then
            local dx, dy, dz = c.x - ox, c.y - oy, c.z - oz
            local sq = dx * dx + dy * dy + dz * dz
            if not bestSq or sq < bestSq then
                best, bestSq = c, sq
            end
        end
    end
    if not best then return nil, nil end
    return best, math.sqrt(bestSq)
end

-- Position `distance` studs from the target along the line target -> origin
-- (planar), plus a vertical offset. Falls back to +Z when origin sits on target.
function Pure.standPosition(tx, ty, tz, ox, oz, distance, height)
    local dx, dz = ox - tx, oz - tz
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.1 then
        dx, dz, len = 0, 1, 1
    end
    return tx + dx / len * distance, ty + height, tz + dz / len * distance
end

return function(State, Tabs, Services, Library)

State.BloodlinesPure = Pure

local Players          = Services.Players
local RunService       = Services.RunService
local UserInputService = Services.UserInputService
local ReplicatedStorage = Services.ReplicatedStorage
local LocalPlayer      = Services.LocalPlayer
local Lighting         = game:GetService('Lighting')
local CoreGui          = game:GetService('CoreGui')

-- ================================================================
--  BUILD CONFIG
--  Source for every entry: user dump unless stated. Instance names and
--  string arguments only; this game exposes no addresses to a Lua client.
-- ================================================================

local BUILD = {
    PlaceId      = 10266164381,   -- dump header; also old MAIN_PLACE_ID
    PlaceVersion = 1669,          -- dump header; informational check only

    EventsFolder = 'Events',      -- ReplicatedStorage.Events (dump remotes section)
    DataEvent    = 'DataEvent',   -- RemoteEvent (dump remotes section)

    NPCValueName = 'NPC',         -- StringValue child of every NPC model (dump mobs section)
    NPCCombat    = 'Combat',      -- seen on Barbarit The Rose and Lavarossa
    NPCDialog    = 'Dialog',      -- seen on town NPCs

    ChakraPoints  = 'ChakraPoints',  -- Workspace Model, 24 children (dump oldrefs); PointName StringValue per child (old file, UNVERIFIED)
    MissionBoards = 'Mission Boards',-- Workspace folder; Mission Board model has Mission.ClickDetector (dump interactables)
    KillBrickNames = { 'LavarossaVoid', 'Void' }, -- Workspace parts, FOUND in dump oldrefs

    BanMeAction      = 'banme',      -- DataEvent:FireServer("BanMe", reason); client anti-cheat, call sites L9731 L13643 L18476 L19711 L19897 L21789
    FallDamageAction = 'takedamage', -- DataEvent:FireServer("TakeDamage", amount); client-reported, call site L7462

    WalkSpeedBanThreshold = 110,     -- client reports BanMe "Offense 1C" at WalkSpeed >= 110 (call site L18475)

    -- Melee call as it appears at call sites L7869 and L7950:
    --   DataEvent:FireServer("CheckMeleeHit", nil, "NormalAttack", v.Running, 4)
    -- UNVERIFIED in game. The meaning of the trailing 4 and whether the server
    -- also needs an equipped weapon or animation is unknown.
    MeleeAction = 'CheckMeleeHit',
    MeleeType   = 'NormalAttack',
    MeleeTrailing = 4,
}

local MAX_SPEED = BUILD.WalkSpeedBanThreshold - 10

-- ================================================================
--  PLACE AND REMOTE VALIDATION
-- ================================================================

if game.PlaceId ~= BUILD.PlaceId then return end

if game.PlaceVersion ~= BUILD.PlaceVersion then
    Library:Notify('Bloodlines: built for PlaceVersion ' .. BUILD.PlaceVersion .. ', this server is ' .. tostring(game.PlaceVersion) .. '. Re-run the dumper if features misbehave.', 8)
end

local Tab = Tabs.bloodlines
if not Tab then
    warn('[Yazu] bloodlines tab missing')
    return
end

local function resolveDataEvent()
    local folder = ReplicatedStorage:FindFirstChild(BUILD.EventsFolder)
    local remote = folder and folder:FindFirstChild(BUILD.DataEvent)
    if remote and remote:IsA('RemoteEvent') then return remote end
    return nil
end

local DataEvent = resolveDataEvent()
if not DataEvent then
    Library:Notify('Bloodlines: ReplicatedStorage.Events.DataEvent not found; remote features are disabled', 8)
end

-- ================================================================
--  CLEANUP REGISTRY (one path for failed init and Unload)
-- ================================================================

local cleanups = {}
local function onCleanup(fn) cleanups[#cleanups + 1] = fn end
local function runCleanups()
    for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
    cleanups = {}
end
if type(Library.OnUnload) == 'function' then
    Library:OnUnload(runCleanups)
end

local function connect(signal, fn)
    local conn = signal:Connect(fn)
    onCleanup(function() conn:Disconnect() end)
    return conn
end

-- ================================================================
--  NAMECALL HOOK (BanMe and fall damage gates)
--  State lives in getgenv so a re-run reuses the one installed hook.
-- ================================================================

local genv = (type(getgenv) == 'function' and getgenv()) or _G
local hook = genv.__YazuBloodlinesHook
if not hook then
    hook = { installed = false, blockBan = false, blockFall = false, blockedBans = 0, remote = nil }
    genv.__YazuBloodlinesHook = hook
end
hook.remote = DataEvent

local function installHook()
    if hook.installed then return true end
    if not DataEvent then return false end
    if type(hookmetamethod) ~= 'function' or type(getnamecallmethod) ~= 'function' then
        Library:Notify('Bloodlines: hookmetamethod/getnamecallmethod missing; BanMe block unavailable', 6)
        return false
    end
    local oldNamecall
    local handler = function(self, ...)
        local method = getnamecallmethod()
        if self == hook.remote and (method == 'FireServer' or method == 'fireServer') then
            local action = ...
            if type(action) == 'string' then
                local lowered = string.lower(action)
                if lowered == BUILD.BanMeAction and hook.blockBan then
                    hook.blockedBans = hook.blockedBans + 1
                    return nil
                end
                if lowered == BUILD.FallDamageAction and hook.blockFall then
                    return nil
                end
            end
        end
        return oldNamecall(self, ...)
    end
    if type(newcclosure) == 'function' then handler = newcclosure(handler) end
    local ok, result = pcall(hookmetamethod, game, '__namecall', handler)
    if not ok or not result then
        Library:Notify('Bloodlines: namecall hook failed: ' .. tostring(result), 6)
        return false
    end
    oldNamecall = result
    hook.installed = true
    return true
end

onCleanup(function()
    hook.blockBan, hook.blockFall = false, false
end)

-- ================================================================
--  CHARACTER AND WORLD HELPERS
-- ================================================================

local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return nil end
    local hum  = char:FindFirstChildOfClass('Humanoid')
    local root = char:FindFirstChild('HumanoidRootPart')
    if hum and root and hum.Health > 0 then return char, hum, root end
    return nil
end

local function zeroVelocity(root)
    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

local function pivotOf(inst)
    if inst:IsA('BasePart') then return inst.CFrame end
    if inst:IsA('Model') then return inst:GetPivot() end
    local part = inst:FindFirstChildWhichIsA('BasePart', true)
    if part then return part.CFrame end
    return nil
end

local function teleportTo(cf)
    local char, hum, root = getCharacter()
    if not char or not cf then return false end
    local p = cf.Position
    if not (Pure.isFinite(p.X) and Pure.isFinite(p.Y) and Pure.isFinite(p.Z)) then return false end
    root.CFrame = cf + Vector3.new(0, 3, 0)
    zeroVelocity(root)
    return true
end

local function npcKind(model)
    local value = model:FindFirstChild(BUILD.NPCValueName)
    if value and value:IsA('StringValue') then return value.Value end
    return nil
end

local function eachNpc(fn)
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA('Model') then
            local kind = npcKind(child)
            if kind then fn(child, kind) end
        end
    end
end

local function collectTargets(filter)
    local list = {}
    eachNpc(function(model, kind)
        if kind ~= BUILD.NPCCombat or not Pure.nameMatches(model.Name, filter) then return end
        local hum  = model:FindFirstChildOfClass('Humanoid')
        local root = model:FindFirstChild('HumanoidRootPart')
        if not hum or not root or hum.Health <= 0 then return end
        local p = root.Position
        list[#list + 1] = { model = model, hum = hum, root = root, x = p.X, y = p.Y, z = p.Z }
    end)
    return list
end

local function sendMelee()
    if not DataEvent then return false end
    DataEvent:FireServer(BUILD.MeleeAction, nil, BUILD.MeleeType, false, BUILD.MeleeTrailing)
    return true
end

-- ================================================================
--  UI GROUPS
-- ================================================================

local FarmGrp   = Tab:AddLeftGroupbox('Combat & Farm')
local LocalGrp  = Tab:AddLeftGroupbox('Local Cheats')
local VisualGrp = Tab:AddLeftGroupbox('Visual Cheats')
local EspGrp    = Tab:AddRightGroupbox('NPC ESP')
local TpGrp     = Tab:AddRightGroupbox('Teleport Cheats')
local SafeGrp   = Tab:AddRightGroupbox('Safety')

-- ================================================================
--  SAFETY: BanMe gate, fall damage, instant log
-- ================================================================

local inDanger = false
if DataEvent then
    -- Event names 'InDanger' / 'OutOfDanger' come from the old bloodlines.lua; UNVERIFIED on this build.
    connect(DataEvent.OnClientEvent, function(eventType)
        if eventType == 'InDanger' then inDanger = true
        elseif eventType == 'OutOfDanger' then inDanger = false end
    end)
end

SafeGrp:AddToggle('BL_BlockBan', {
    Text = 'Block BanMe Reports', Default = true,
    Tooltip = 'Drops DataEvent:FireServer("BanMe", ...) from the client anti-cheat. Server-side checks are not visible from the client.',
    Callback = function(state)
        if state and not installHook() then
            if Toggles.BL_BlockBan then Toggles.BL_BlockBan:SetValue(false) end
            return
        end
        hook.blockBan = state
    end,
})
SafeGrp:AddToggle('BL_NoFall', {
    Text = 'No Fall Damage', Default = false,
    Tooltip = 'Drops the client-reported TakeDamage call.',
    Callback = function(state)
        if state and not installHook() then
            if Toggles.BL_NoFall then Toggles.BL_NoFall:SetValue(false) end
            return
        end
        hook.blockFall = state
    end,
})
SafeGrp:AddButton({ Text = 'Print Blocked BanMe Count', Func = function()
    Library:Notify('Blocked BanMe reports: ' .. tostring(hook.blockedBans))
end })
SafeGrp:AddButton({ Text = 'Reset Character', Func = function()
    LocalPlayer:Kick('')
    task.wait(2.5)
    game:Shutdown()
end })
SafeGrp:AddButton({ Text = 'Instant Log', Func = function()
    if inDanger then
        Library:Notify('In danger: not logging out')
        return
    end
    LocalPlayer:Kick('')
    task.wait(2.5)
    game:Shutdown()
end })

task.defer(function()
    if Toggles.BL_BlockBan.Value then
        if installHook() then hook.blockBan = true end
    end
end)

-- ================================================================
--  LOCAL: speed, fly, noclip, kill bricks
-- ================================================================

LocalGrp:AddToggle('BL_Speed', { Text = 'Speed', Default = false })
LocalGrp:AddSlider('BL_SpeedValue', {
    Text = 'Move Speed', Default = 50, Min = 16, Max = MAX_SPEED, Rounding = 0,
    Tooltip = 'Capped below ' .. BUILD.WalkSpeedBanThreshold .. ': the client reports BanMe at WalkSpeed >= ' .. BUILD.WalkSpeedBanThreshold .. '.',
})
do
    local saved
    local function restore()
        local _, hum = getCharacter()
        if hum and saved then hum.WalkSpeed = saved end
        saved = nil
    end
    connect(RunService.Heartbeat, function()
        if not Toggles.BL_Speed.Value then return end
        local _, hum = getCharacter()
        if not hum then return end
        if not saved then saved = hum.WalkSpeed end
        hum.WalkSpeed = math.min(Options.BL_SpeedValue.Value, MAX_SPEED)
    end)
    Toggles.BL_Speed:OnChanged(function()
        if not Toggles.BL_Speed.Value then restore() end
    end)
    onCleanup(restore)
end

LocalGrp:AddToggle('BL_Fly', { Text = 'Fly', Default = false,
    Tooltip = 'CFrame movement; no BodyMovers (the client reports BanMe when one is added).' })
LocalGrp:AddSlider('BL_FlySpeed', { Text = 'Fly Speed', Default = 60, Min = 10, Max = 200, Rounding = 0 })
connect(RunService.RenderStepped, function(dt)
    if not Toggles.BL_Fly.Value then return end
    if UserInputService:GetFocusedTextBox() then return end
    local char, hum, root = getCharacter()
    if not char then return end
    local cam = workspace.CurrentCamera
    local move = Vector3.new(0, 0, 0)
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then move = move + cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then move = move - cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then move = move + cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then move = move - cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end
    if move.Magnitude > 0 then
        root.CFrame = root.CFrame + move.Unit * Options.BL_FlySpeed.Value * dt
    end
    zeroVelocity(root)
end)

LocalGrp:AddToggle('BL_Noclip', { Text = 'No Clip', Default = false })
do
    local original = setmetatable({}, { __mode = 'k' })
    local function restore()
        for part, value in pairs(original) do
            if part.Parent then part.CanCollide = value end
            original[part] = nil
        end
    end
    connect(RunService.Stepped, function()
        if not Toggles.BL_Noclip.Value then return end
        local char = LocalPlayer.Character
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA('BasePart') then
                if original[part] == nil then original[part] = part.CanCollide end
                part.CanCollide = false
            end
        end
    end)
    Toggles.BL_Noclip:OnChanged(function()
        if not Toggles.BL_Noclip.Value then restore() end
    end)
    onCleanup(restore)
end

LocalGrp:AddToggle('BL_NoKillBricks', { Text = 'No Kill Bricks', Default = false,
    Tooltip = 'Disables touch events on parts named ' .. table.concat(BUILD.KillBrickNames, ', ') .. ' (client side).' })
do
    local original = setmetatable({}, { __mode = 'k' })
    local isBrick = {}
    for _, name in ipairs(BUILD.KillBrickNames) do isBrick[name] = true end
    local function apply(inst)
        if isBrick[inst.Name] and inst:IsA('BasePart') then
            if original[inst] == nil then original[inst] = inst.CanTouch end
            inst.CanTouch = false
        end
    end
    local function restore()
        for part, value in pairs(original) do
            if part.Parent then part.CanTouch = value end
            original[part] = nil
        end
    end
    connect(workspace.ChildAdded, function(inst)
        if Toggles.BL_NoKillBricks.Value then apply(inst) end
    end)
    Toggles.BL_NoKillBricks:OnChanged(function()
        if Toggles.BL_NoKillBricks.Value then
            for _, inst in ipairs(workspace:GetChildren()) do apply(inst) end
        else
            restore()
        end
    end)
    onCleanup(restore)
end

-- ================================================================
--  COMBAT AND FARM (melee call UNVERIFIED in game; timings uncalibrated)
-- ================================================================

FarmGrp:AddLabel('Targets: Workspace models whose NPC value is Combat.')
FarmGrp:AddInput('BL_TargetFilter', { Default = '', Text = 'Target name contains', Placeholder = 'empty = any Combat NPC' })
FarmGrp:AddSlider('BL_AttackInterval', { Text = 'Attack Interval (s) - uncalibrated', Default = 0.4, Min = 0.1, Max = 2, Rounding = 2 })
FarmGrp:AddSlider('BL_StandDistance', { Text = 'Stand Distance (studs) - uncalibrated', Default = 5, Min = 2, Max = 15, Rounding = 1 })
FarmGrp:AddSlider('BL_StandHeight', { Text = 'Stand Height Offset', Default = 0, Min = -5, Max = 10, Rounding = 1 })
FarmGrp:AddSlider('BL_FarmStopHP', { Text = 'Stop Farm Below HP %', Default = 40, Min = 0, Max = 100, Rounding = 0 })

FarmGrp:AddToggle('BL_AutoAttack', { Text = 'Auto Attack (no movement)', Default = false })
FarmGrp:AddToggle('BL_AutoFarm', { Text = 'Auto Farm (nearest Combat NPC)', Default = false,
    Tooltip = 'Teleports next to the nearest living Combat NPC and swings. Untested in game.' })

local attackRun, farmRun = 0, 0

Toggles.BL_AutoAttack:OnChanged(function()
    attackRun = attackRun + 1
    local mine = attackRun
    if not Toggles.BL_AutoAttack.Value then return end
    if not DataEvent then
        Library:Notify('Auto Attack unavailable: DataEvent missing')
        Toggles.BL_AutoAttack:SetValue(false)
        return
    end
    task.spawn(function()
        while attackRun == mine and Toggles.BL_AutoAttack.Value do
            if getCharacter() then sendMelee() end
            task.wait(Options.BL_AttackInterval.Value)
        end
    end)
end)

Toggles.BL_AutoFarm:OnChanged(function()
    farmRun = farmRun + 1
    local mine = farmRun
    if not Toggles.BL_AutoFarm.Value then return end
    if not DataEvent then
        Library:Notify('Auto Farm unavailable: DataEvent missing')
        Toggles.BL_AutoFarm:SetValue(false)
        return
    end
    task.spawn(function()
        local target
        local warnedEmpty = false
        while farmRun == mine and Toggles.BL_AutoFarm.Value do
            local char, hum, root = getCharacter()
            if not char then
                task.wait(0.5)
            elseif hum.MaxHealth > 0 and hum.Health / hum.MaxHealth * 100 < Options.BL_FarmStopHP.Value then
                Library:Notify('Auto Farm stopped: health below ' .. tostring(Options.BL_FarmStopHP.Value) .. '%')
                Toggles.BL_AutoFarm:SetValue(false)
            else
                if target and (not target.model.Parent or target.hum.Health <= 0) then target = nil end
                if not target then
                    local origin = root.Position
                    target = Pure.pickNearest(collectTargets(Options.BL_TargetFilter.Value), origin.X, origin.Y, origin.Z)
                    if not target and not warnedEmpty then
                        warnedEmpty = true
                        Library:Notify('Auto Farm: no living Combat NPC is loaded; move toward a mob area (StreamingEnabled is on)')
                    end
                end
                if target then
                    warnedEmpty = false
                    local tp, op = target.root.Position, root.Position
                    local sx, sy, sz = Pure.standPosition(tp.X, tp.Y, tp.Z, op.X, op.Z,
                        Options.BL_StandDistance.Value, Options.BL_StandHeight.Value)
                    local dest = Vector3.new(sx, sy, sz)
                    root.CFrame = CFrame.new(dest, Vector3.new(tp.X, dest.Y, tp.Z))
                    zeroVelocity(root)
                    sendMelee()
                end
                task.wait(Options.BL_AttackInterval.Value)
            end
        end
    end)
end)

onCleanup(function()
    attackRun, farmRun = attackRun + 1, farmRun + 1
end)

-- ================================================================
--  VISUALS
-- ================================================================

local lightingOriginal = {
    Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
    Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, GlobalShadows = Lighting.GlobalShadows,
}
local atmosphereOriginal = setmetatable({}, { __mode = 'k' })
local TIME_OF_DAY = { Morning = 8, Afternoon = 14, Evening = 18, Night = 0 } -- chosen clock hours

VisualGrp:AddToggle('BL_NoFog', { Text = 'No Fog', Default = false })
VisualGrp:AddToggle('BL_FullBright', { Text = 'Full Bright', Default = false })
VisualGrp:AddSlider('BL_Brightness', { Text = 'Brightness Level', Default = 5, Min = 1, Max = 10, Rounding = 0 })
VisualGrp:AddToggle('BL_ForceTime', { Text = 'Force Time Of Day', Default = false })
VisualGrp:AddDropdown('BL_TimeOfDay', { Text = 'Time Of Day', Default = 1, Values = { 'Morning', 'Afternoon', 'Evening', 'Night' } })

local LIGHTING_KEYS = {
    fog    = { 'FogEnd' },
    bright = { 'Brightness', 'Ambient', 'OutdoorAmbient', 'GlobalShadows' },
    time   = { 'ClockTime' },
}

local function restoreLighting(group)
    for _, key in ipairs(LIGHTING_KEYS[group]) do Lighting[key] = lightingOriginal[key] end
    if group == 'fog' then
        for atmo, density in pairs(atmosphereOriginal) do
            if atmo.Parent then atmo.Density = density end
            atmosphereOriginal[atmo] = nil
        end
    end
end

connect(RunService.RenderStepped, function()
    if Toggles.BL_NoFog.Value then
        Lighting.FogEnd = 1e9
        for _, child in ipairs(Lighting:GetChildren()) do
            if child:IsA('Atmosphere') then
                if atmosphereOriginal[child] == nil then atmosphereOriginal[child] = child.Density end
                child.Density = 0
            end
        end
    end
    if Toggles.BL_FullBright.Value then
        Lighting.Brightness = Options.BL_Brightness.Value
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.GlobalShadows = false
    end
    if Toggles.BL_ForceTime.Value then
        Lighting.ClockTime = TIME_OF_DAY[Options.BL_TimeOfDay.Value] or Lighting.ClockTime
    end
end)

Toggles.BL_NoFog:OnChanged(function()
    if not Toggles.BL_NoFog.Value then restoreLighting('fog') end
end)
Toggles.BL_FullBright:OnChanged(function()
    if not Toggles.BL_FullBright.Value then restoreLighting('bright') end
end)
Toggles.BL_ForceTime:OnChanged(function()
    if not Toggles.BL_ForceTime.Value then restoreLighting('time') end
end)
onCleanup(function()
    restoreLighting('fog'); restoreLighting('bright'); restoreLighting('time')
end)

-- ================================================================
--  NPC ESP
-- ================================================================

EspGrp:AddToggle('BL_EspCombat', { Text = 'Combat NPCs', Default = false })
EspGrp:AddLabel('Combat Color'):AddColorPicker('BL_EspCombatColor', { Default = Color3.fromRGB(255, 70, 70) })
EspGrp:AddToggle('BL_EspDialog', { Text = 'Dialog NPCs', Default = false })
EspGrp:AddLabel('Dialog Color'):AddColorPicker('BL_EspDialogColor', { Default = Color3.fromRGB(90, 255, 140) })
EspGrp:AddSlider('BL_EspDistance', { Text = 'Max Distance', Default = 1000, Min = 100, Max = 5000, Rounding = 0 })

do
    local folder = Instance.new('Folder')
    folder.Name = 'YazuBL'
    folder.Parent = (type(gethui) == 'function' and gethui()) or CoreGui
    onCleanup(function() folder:Destroy() end)

    local entries = {}
    local function removeEntry(model)
        local e = entries[model]
        if not e then return end
        e.highlight:Destroy()
        e.billboard:Destroy()
        entries[model] = nil
    end

    local function makeEntry(model, root)
        local highlight = Instance.new('Highlight')
        highlight.Adornee = model
        highlight.FillTransparency = 0.7
        highlight.Parent = folder
        local billboard = Instance.new('BillboardGui')
        billboard.Adornee = root
        billboard.AlwaysOnTop = true
        billboard.Size = UDim2.new(0, 200, 0, 40)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.Parent = folder
        local label = Instance.new('TextLabel')
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 1, 0)
        label.TextSize = 14
        label.TextStrokeTransparency = 0.5
        label.Parent = billboard
        entries[model] = { highlight = highlight, billboard = billboard, label = label }
        return entries[model]
    end

    local accumulator = 0
    connect(RunService.Heartbeat, function(dt)
        accumulator = accumulator + dt
        if accumulator < 0.1 then return end
        accumulator = 0
        local _, _, myRoot = getCharacter()
        local seen = {}
        if myRoot and (Toggles.BL_EspCombat.Value or Toggles.BL_EspDialog.Value) then
            eachNpc(function(model, kind)
                local wanted = (kind == BUILD.NPCCombat and Toggles.BL_EspCombat.Value)
                    or (kind == BUILD.NPCDialog and Toggles.BL_EspDialog.Value)
                if not wanted then return end
                local root = model:FindFirstChild('HumanoidRootPart')
                if not root then return end
                local distance = (root.Position - myRoot.Position).Magnitude
                if distance > Options.BL_EspDistance.Value then return end
                seen[model] = true
                local e = entries[model] or makeEntry(model, root)
                local color = kind == BUILD.NPCCombat and Options.BL_EspCombatColor.Value or Options.BL_EspDialogColor.Value
                e.highlight.FillColor, e.highlight.OutlineColor, e.label.TextColor3 = color, color, color
                local hum = model:FindFirstChildOfClass('Humanoid')
                local hp = hum and string.format('%d/%d  ', math.floor(hum.Health), math.floor(hum.MaxHealth)) or ''
                e.label.Text = string.format('%s\n%s%dm', model.Name, hp, math.floor(distance))
            end)
        end
        for model in pairs(entries) do
            if not seen[model] then removeEntry(model) end
        end
    end)
end

-- ================================================================
--  TELEPORTS
-- ================================================================

TpGrp:AddDropdown('BL_ChakraPoint', { Text = 'Chakra Point', Values = {} })
TpGrp:AddButton({ Text = 'Teleport To Chakra Point', Func = function()
    local key = Options.BL_ChakraPoint.Value
    local point = key and State.BL_ChakraMap and State.BL_ChakraMap[key]
    if not (point and point.Parent and teleportTo(pivotOf(point))) then
        Library:Notify('Chakra point not available (press Refresh Lists)')
    end
end })
TpGrp:AddDropdown('BL_Npc', { Text = 'Dialog NPC', Values = {} })
TpGrp:AddButton({ Text = 'Teleport To NPC', Func = function()
    local model = State.BL_NpcMap and State.BL_NpcMap[Options.BL_Npc.Value]
    if not (model and model.Parent and teleportTo(pivotOf(model))) then
        Library:Notify('NPC not loaded (press Refresh Lists; StreamingEnabled hides far NPCs)')
    end
end })
TpGrp:AddDropdown('BL_Player', { Text = 'Player', Values = {} })
TpGrp:AddButton({ Text = 'Teleport To Player', Func = function()
    local player = Players:FindFirstChild(Options.BL_Player.Value or '')
    local char = player and player.Character
    if not (char and teleportTo(pivotOf(char))) then
        Library:Notify('Player not available')
    end
end })

local function nearestMissionBoard()
    local folder = workspace:FindFirstChild(BUILD.MissionBoards)
    local _, _, root = getCharacter()
    if not (folder and root) then return nil end
    local candidates = {}
    for _, board in ipairs(folder:GetChildren()) do
        local cf = pivotOf(board)
        if cf then
            local p = cf.Position
            candidates[#candidates + 1] = { board = board, cf = cf, x = p.X, y = p.Y, z = p.Z }
        end
    end
    local origin = root.Position
    return (Pure.pickNearest(candidates, origin.X, origin.Y, origin.Z))
end

TpGrp:AddButton({ Text = 'Teleport To Nearest Mission Board', Func = function()
    local pick = nearestMissionBoard()
    if not (pick and teleportTo(pick.cf)) then Library:Notify('No mission board loaded') end
end })
TpGrp:AddButton({ Text = 'Click Nearest Mission Board', Func = function()
    local pick = nearestMissionBoard()
    local mission = pick and pick.board:FindFirstChild('Mission')
    local detector = mission and mission:FindFirstChildOfClass('ClickDetector')
    if not detector then Library:Notify('No mission board ClickDetector loaded') return end
    if type(fireclickdetector) ~= 'function' then Library:Notify('fireclickdetector missing on this executor') return end
    fireclickdetector(detector)
end })

local function refreshLists()
    local chakraMap, chakraNames = {}, {}
    local points = workspace:FindFirstChild(BUILD.ChakraPoints)
    if points then
        for index, child in ipairs(points:GetChildren()) do
            local label = child:FindFirstChild('PointName')
            local name = (label and label:IsA('StringValue') and label.Value ~= '' and label.Value) or child.Name
            if chakraMap[name] then name = name .. ' #' .. index end
            chakraMap[name] = child
            chakraNames[#chakraNames + 1] = name
        end
    end
    table.sort(chakraNames)
    State.BL_ChakraMap = chakraMap
    Options.BL_ChakraPoint:SetValues(chakraNames)

    local npcMap, npcNames = {}, {}
    eachNpc(function(model, kind)
        if kind == BUILD.NPCDialog and not npcMap[model.Name] then
            npcMap[model.Name] = model
            npcNames[#npcNames + 1] = model.Name
        end
    end)
    table.sort(npcNames)
    State.BL_NpcMap = npcMap
    Options.BL_Npc:SetValues(npcNames)

    local playerNames = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then playerNames[#playerNames + 1] = player.Name end
    end
    table.sort(playerNames)
    Options.BL_Player:SetValues(playerNames)
end

TpGrp:AddButton({ Text = 'Refresh Lists', Func = refreshLists })
task.defer(refreshLists)

end
