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

    -- Block remotes, call sites L9275 and L1643/L11002 (dump 2). UNVERIFIED: the meaning of the 3,
    -- the timing of the perfect-block window, and what the server needs besides this call.
    DataFunction   = 'DataFunction',   -- RemoteFunction (dump remotes section)
    BlockAction    = 'Block',          -- DataFunction:InvokeServer("Block", 3) == true when a block starts
    BlockArg       = 3,
    EndBlockAction = 'EndBlock',       -- DataFunction:InvokeServer("EndBlock")

    -- Replicated per-NPC state (dump 2 tree): Workspace NPC model -> Settings folder.
    SettingsFolder        = 'Settings',
    SettingsMeleeCooldown = 'MeleeCooldown',   -- BoolValue
    SettingsCurrentSkill  = 'CurrentSkill',    -- StringValue
    SettingsStatusFlags   = { 'Stunned', 'Blocking', 'Knocked', 'Invincible', 'HyperArmour', 'canPerfectBlock', 'ParryStun' }, -- BoolValues

    ItemDetectorName = 'ItemDetector', -- ClickDetector on Workspace.Gloweed (x1) and Workspace.Seaweed (x4), MaxActivationDistance 12 (dump 2 interactables)
    MissionModelName = 'Mission',      -- Mission Boards.<board>.Mission, attributes Mission and Village (dump 2 tree)
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

local function resolveDataFunction()
    local folder = ReplicatedStorage:FindFirstChild(BUILD.EventsFolder)
    local remote = folder and folder:FindFirstChild(BUILD.DataFunction)
    if remote and remote:IsA('RemoteFunction') then return remote end
    return nil
end

local DataFunction = resolveDataFunction()
if not DataFunction then
    Library:Notify('Bloodlines: ReplicatedStorage.Events.DataFunction not found; Auto Parry is disabled', 8)
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
local ParryGrp  = Tab:AddLeftGroupbox('Auto Parry')
local EspGrp    = Tab:AddRightGroupbox('ESP')
local UtilGrp   = Tab:AddRightGroupbox('Harvest & Utility')
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
--  AUTO PARRY
--  Trigger: an enemy Combat NPC within range flips Settings.MeleeCooldown
--  to true or sets a non-empty Settings.CurrentSkill. Whether either marks
--  the start of a hit is UNVERIFIED; the log toggle records both against my
--  own Block calls so the delay can be calibrated from a real fight.
-- ================================================================

ParryGrp:AddLabel('Needs Combat NPC Settings values; players are not detected.')
ParryGrp:AddToggle('BL_AutoParry', { Text = 'Auto Parry', Default = false,
    Tooltip = 'Calls Block when a nearby Combat NPC signals an attack, then EndBlock. Untested in game.' })
ParryGrp:AddToggle('BL_ParryOnMelee', { Text = 'Trigger: enemy MeleeCooldown on', Default = true })
ParryGrp:AddToggle('BL_ParryOnSkill', { Text = 'Trigger: enemy CurrentSkill set', Default = true })
ParryGrp:AddSlider('BL_ParryRange', { Text = 'Trigger Range (studs)', Default = 18, Min = 5, Max = 60, Rounding = 0 })
ParryGrp:AddSlider('BL_ParryDelay', { Text = 'Delay After Trigger (s) - uncalibrated', Default = 0, Min = 0, Max = 1, Rounding = 2 })
ParryGrp:AddSlider('BL_ParryHold', { Text = 'Hold Block (s) - uncalibrated', Default = 0.35, Min = 0.1, Max = 1.5, Rounding = 2 })
ParryGrp:AddToggle('BL_ParryLog', { Text = 'Log enemy events and my blocks', Default = false })

local parry = { blocking = false, watched = {}, log = {} }

local function logParry(text)
    if not Toggles.BL_ParryLog.Value then return end
    local log = parry.log
    log[#log + 1] = string.format('%.3f %s', os.clock(), text)
    if #log > 5000 then table.remove(log, 1) end
end

local function endBlock()
    parry.blocking = false
    if not DataFunction then return end
    local ok, result = pcall(function() return DataFunction:InvokeServer(BUILD.EndBlockAction) end)
    logParry('EndBlock -> ' .. tostring(ok) .. ' ' .. tostring(result))
end

local function startBlock(holdTime)
    if parry.blocking or not DataFunction or not getCharacter() then return end
    parry.blocking = true
    task.spawn(function()
        local ok, result = pcall(function() return DataFunction:InvokeServer(BUILD.BlockAction, BUILD.BlockArg) end)
        logParry('Block -> ' .. tostring(ok) .. ' ' .. tostring(result))
        if ok and result == true then
            task.wait(holdTime)
            endBlock()
        else
            parry.blocking = false
        end
    end)
end

local function onEnemyEvent(model, what, actionable)
    local _, _, myRoot = getCharacter()
    local root = model:FindFirstChild('HumanoidRootPart')
    if not myRoot or not root then return end
    local distance = (root.Position - myRoot.Position).Magnitude
    logParry(string.format('enemy %s: %s (%dm)%s', model.Name, what, math.floor(distance), actionable and '' or ' [trigger off]'))
    if not actionable or not Toggles.BL_AutoParry.Value then return end
    if distance > Options.BL_ParryRange.Value then return end
    task.delay(Options.BL_ParryDelay.Value, function()
        if Toggles.BL_AutoParry.Value then startBlock(Options.BL_ParryHold.Value) end
    end)
end

local function unwatchNpc(model)
    local entry = parry.watched[model]
    if not entry then return end
    for _, conn in ipairs(entry) do conn:Disconnect() end
    parry.watched[model] = nil
end

local function watchNpc(model)
    if parry.watched[model] then return end
    local entry = {}
    parry.watched[model] = entry
    entry[#entry + 1] = model.AncestryChanged:Connect(function(_, parent)
        if not parent then unwatchNpc(model) end
    end)
    task.spawn(function()
        local settings = model:WaitForChild(BUILD.SettingsFolder, 10)
        if not settings or parry.watched[model] ~= entry then return end
        local melee = settings:FindFirstChild(BUILD.SettingsMeleeCooldown)
        local skill = settings:FindFirstChild(BUILD.SettingsCurrentSkill)
        if melee and melee:IsA('BoolValue') then
            entry[#entry + 1] = melee:GetPropertyChangedSignal('Value'):Connect(function()
                if melee.Value == true then onEnemyEvent(model, 'MeleeCooldown=true', Toggles.BL_ParryOnMelee.Value) end
            end)
        end
        if skill and skill:IsA('StringValue') then
            entry[#entry + 1] = skill:GetPropertyChangedSignal('Value'):Connect(function()
                if skill.Value ~= '' then onEnemyEvent(model, 'CurrentSkill=' .. skill.Value, Toggles.BL_ParryOnSkill.Value) end
            end)
        end
        local hum = model:FindFirstChildOfClass('Humanoid')
        local animator = hum and hum:FindFirstChildOfClass('Animator')
        if animator then
            entry[#entry + 1] = animator.AnimationPlayed:Connect(function(track)
                if Toggles.BL_ParryLog.Value then
                    local anim = track.Animation
                    logParry(string.format('enemy %s: anim %s id=%s length=%s', model.Name, tostring(track.Name),
                        tostring(anim and anim.AnimationId), tostring(track.Length)))
                end
            end)
        end
    end)
end

local function watchIfCombat(model)
    if not model:IsA('Model') then return end
    task.spawn(function()
        local value = model:WaitForChild(BUILD.NPCValueName, 5)
        if value and value:IsA('StringValue') and value.Value == BUILD.NPCCombat then watchNpc(model) end
    end)
end

local function refreshParryWatch()
    if Toggles.BL_AutoParry.Value or Toggles.BL_ParryLog.Value then
        for _, child in ipairs(workspace:GetChildren()) do watchIfCombat(child) end
    else
        for model in pairs(parry.watched) do unwatchNpc(model) end
    end
end

connect(workspace.ChildAdded, function(child)
    if Toggles.BL_AutoParry.Value or Toggles.BL_ParryLog.Value then watchIfCombat(child) end
end)
Toggles.BL_AutoParry:OnChanged(function()
    if Toggles.BL_AutoParry.Value and not DataFunction then
        Library:Notify('Auto Parry unavailable: DataFunction missing')
        Toggles.BL_AutoParry:SetValue(false)
        return
    end
    refreshParryWatch()
end)
Toggles.BL_ParryLog:OnChanged(refreshParryWatch)

ParryGrp:AddButton({ Text = 'Save Parry Log', Func = function()
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('writefile/makefolder missing on this executor')
        return
    end
    local folder = 'YazuDumper'
    pcall(function() if type(isfolder) ~= 'function' or not isfolder(folder) then makefolder(folder) end end)
    local path = folder .. '/BL_ParryLog_' .. tostring(os.time()) .. '.txt'
    local ok, err = pcall(writefile, path, table.concat(parry.log, '\n'))
    Library:Notify(ok and ('Saved ' .. path .. ' (' .. #parry.log .. ' lines)') or ('Write error: ' .. tostring(err)))
end })
ParryGrp:AddButton({ Text = 'Force End Block', Func = function() task.spawn(endBlock) end })

onCleanup(function()
    for model in pairs(parry.watched) do unwatchNpc(model) end
    if parry.blocking then task.spawn(endBlock) end
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
--  ESP: players, NPCs (with status), harvest items, mission boards,
--  chakra points. One reconcile loop at 10 Hz; Highlights only on
--  players and Combat NPCs (the engine renders a limited number).
-- ================================================================

local ESP_CATEGORIES = {
    { toggle = 'BL_EspPlayers',  color = 'BL_EspPlayersColor',  label = 'Players',        default = Color3.fromRGB(255, 255, 255) },
    { toggle = 'BL_EspCombat',   color = 'BL_EspCombatColor',   label = 'Combat NPCs',    default = Color3.fromRGB(255, 70, 70) },
    { toggle = 'BL_EspDialog',   color = 'BL_EspDialogColor',   label = 'Dialog NPCs',    default = Color3.fromRGB(90, 255, 140) },
    { toggle = 'BL_EspItems',    color = 'BL_EspItemsColor',    label = 'Harvest Items',  default = Color3.fromRGB(255, 220, 80) },
    { toggle = 'BL_EspMissions', color = 'BL_EspMissionsColor', label = 'Mission Boards', default = Color3.fromRGB(80, 200, 255) },
    { toggle = 'BL_EspChakra',   color = 'BL_EspChakraColor',   label = 'Chakra Points',  default = Color3.fromRGB(190, 120, 255) },
}
for _, cat in ipairs(ESP_CATEGORIES) do
    EspGrp:AddToggle(cat.toggle, { Text = cat.label, Default = false })
    EspGrp:AddLabel(cat.label .. ' Color'):AddColorPicker(cat.color, { Default = cat.default })
end
EspGrp:AddToggle('BL_EspStatus', { Text = 'NPC Status (stun, block, skill)', Default = true })
EspGrp:AddSlider('BL_EspDistance', { Text = 'Max Distance', Default = 1000, Min = 100, Max = 5000, Rounding = 0 })

local function adorneeOf(inst)
    if not inst then return nil end
    if inst:IsA('BasePart') then return inst end
    return inst:FindFirstChildWhichIsA('BasePart', true)
end

-- Registry of ItemDetector ClickDetectors; the scan only starts when first needed.
local itemDetectors = {}
local itemScanStarted = false
local function registerItem(inst)
    if inst.Name == BUILD.ItemDetectorName and inst:IsA('ClickDetector') then itemDetectors[inst] = true end
end
local function ensureItemScan()
    if itemScanStarted then return end
    itemScanStarted = true
    connect(workspace.DescendantAdded, registerItem)
    connect(workspace.DescendantRemoving, function(inst) itemDetectors[inst] = nil end)
    task.spawn(function()
        local count = 0
        for _, inst in ipairs(workspace:GetDescendants()) do
            registerItem(inst)
            count = count + 1
            if count % 500 == 0 then RunService.Heartbeat:Wait() end
        end
    end)
end

local function npcStatusText(model)
    local settings = model:FindFirstChild(BUILD.SettingsFolder)
    if not settings then return '' end
    local parts = {}
    for _, flag in ipairs(BUILD.SettingsStatusFlags) do
        local v = settings:FindFirstChild(flag)
        if v and v:IsA('BoolValue') and v.Value then parts[#parts + 1] = flag end
    end
    local skill = settings:FindFirstChild(BUILD.SettingsCurrentSkill)
    if skill and skill:IsA('StringValue') and skill.Value ~= '' then parts[#parts + 1] = 'skill: ' .. skill.Value end
    if #parts == 0 then return '' end
    return '\n[' .. table.concat(parts, ', ') .. ']'
end

local function healthText(hum)
    if not hum then return '' end
    return string.format('  %d/%d', math.floor(hum.Health), math.floor(hum.MaxHealth))
end

-- add(key, adornee, highlightTarget or nil, text, colorOptionName)
local function collectMarkers(add)
    if Toggles.BL_EspPlayers.Value then
        for _, player in ipairs(Players:GetPlayers()) do
            local char = player ~= LocalPlayer and player.Character
            local root = char and char:FindFirstChild('HumanoidRootPart')
            if root then
                add(char, root, char, player.Name .. healthText(char:FindFirstChildOfClass('Humanoid')), 'BL_EspPlayersColor')
            end
        end
    end
    if Toggles.BL_EspCombat.Value or Toggles.BL_EspDialog.Value then
        eachNpc(function(model, kind)
            local combat = kind == BUILD.NPCCombat
            if not ((combat and Toggles.BL_EspCombat.Value) or (kind == BUILD.NPCDialog and Toggles.BL_EspDialog.Value)) then return end
            local root = model:FindFirstChild('HumanoidRootPart')
            if not root then return end
            local text = model.Name .. healthText(model:FindFirstChildOfClass('Humanoid'))
            if combat and Toggles.BL_EspStatus.Value then text = text .. npcStatusText(model) end
            add(model, root, combat and model or nil, text, combat and 'BL_EspCombatColor' or 'BL_EspDialogColor')
        end)
    end
    if Toggles.BL_EspItems.Value then
        ensureItemScan()
        for detector in pairs(itemDetectors) do
            local owner = detector.Parent
            local part = adorneeOf(owner)
            if part then add(detector, part, nil, owner.Name, 'BL_EspItemsColor') end
        end
    end
    if Toggles.BL_EspMissions.Value then
        local boards = workspace:FindFirstChild(BUILD.MissionBoards)
        if boards then
            for _, board in ipairs(boards:GetChildren()) do
                local mission = board:FindFirstChild(BUILD.MissionModelName)
                local part = adorneeOf(board)
                if part then
                    local name = mission and mission:GetAttribute('Mission') or 'Mission'
                    local village = (mission and mission:GetAttribute('Village')) or board:GetAttribute('Village') or '?'
                    add(board, part, nil, tostring(name) .. ' (' .. tostring(village) .. ')', 'BL_EspMissionsColor')
                end
            end
        end
    end
    if Toggles.BL_EspChakra.Value then
        local points = workspace:FindFirstChild(BUILD.ChakraPoints)
        if points then
            for _, point in ipairs(points:GetChildren()) do
                local part = adorneeOf(point)
                if part then
                    local label = point:FindFirstChild('PointName')
                    add(point, part, nil, (label and label:IsA('StringValue') and label.Value ~= '' and label.Value) or point.Name, 'BL_EspChakraColor')
                end
            end
        end
    end
end

do
    local folder = Instance.new('Folder')
    folder.Name = 'YazuBL'
    folder.Parent = (type(gethui) == 'function' and gethui()) or CoreGui
    onCleanup(function() folder:Destroy() end)

    local entries = {}
    local function removeEntry(key)
        local e = entries[key]
        if not e then return end
        if e.highlight then e.highlight:Destroy() end
        e.billboard:Destroy()
        entries[key] = nil
    end

    local function makeEntry(key, adornee, target)
        local highlight
        if target then
            highlight = Instance.new('Highlight')
            highlight.Adornee = target
            highlight.FillTransparency = 0.7
            highlight.Parent = folder
        end
        local billboard = Instance.new('BillboardGui')
        billboard.Adornee = adornee
        billboard.AlwaysOnTop = true
        billboard.Size = UDim2.new(0, 220, 0, 56)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.Parent = folder
        local label = Instance.new('TextLabel')
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 1, 0)
        label.TextSize = 14
        label.TextStrokeTransparency = 0.5
        label.Parent = billboard
        entries[key] = { highlight = highlight, billboard = billboard, label = label, adornee = adornee }
        return entries[key]
    end

    local accumulator = 0
    connect(RunService.Heartbeat, function(dt)
        accumulator = accumulator + dt
        if accumulator < 0.1 then return end
        accumulator = 0
        local _, _, myRoot = getCharacter()
        local seen = {}
        if myRoot then
            local maxDistance = Options.BL_EspDistance.Value
            collectMarkers(function(key, adornee, target, text, colorName)
                if not adornee.Parent then return end
                local distance = (adornee.Position - myRoot.Position).Magnitude
                if distance > maxDistance then return end
                seen[key] = true
                local e = entries[key]
                if e and e.adornee ~= adornee then removeEntry(key) e = nil end
                e = e or makeEntry(key, adornee, target)
                local color = Options[colorName].Value
                if e.highlight then e.highlight.FillColor, e.highlight.OutlineColor = color, color end
                e.label.TextColor3 = color
                e.label.Text = text .. '\n' .. math.floor(distance) .. 'm'
            end)
        end
        for key in pairs(entries) do
            if not seen[key] then removeEntry(key) end
        end
    end)
end

-- ================================================================
--  HARVEST AND UTILITY
--  Harvest = teleport next to the nearest ItemDetector and fire its
--  ClickDetector. UNVERIFIED: whether the server accepts a synthetic
--  click, and how fast items respawn (cooldown below is a guess).
-- ================================================================

UtilGrp:AddSlider('BL_HarvestInterval', { Text = 'Harvest Interval (s) - uncalibrated', Default = 1.5, Min = 0.5, Max = 5, Rounding = 1 })
UtilGrp:AddSlider('BL_HarvestSkip', { Text = 'Skip Clicked Item For (s) - uncalibrated', Default = 30, Min = 0, Max = 300, Rounding = 0 })

local harvestedAt = setmetatable({}, { __mode = 'k' })

local function nearestHarvestable(skipSeconds)
    ensureItemScan()
    local _, _, root = getCharacter()
    if not root then return nil end
    local candidates, now = {}, os.clock()
    for detector in pairs(itemDetectors) do
        local part = adorneeOf(detector.Parent)
        local last = harvestedAt[detector]
        if part and not (last and now - last < skipSeconds) then
            local p = part.Position
            candidates[#candidates + 1] = { detector = detector, part = part, x = p.X, y = p.Y, z = p.Z }
        end
    end
    local origin = root.Position
    return (Pure.pickNearest(candidates, origin.X, origin.Y, origin.Z))
end

local function harvestOnce()
    if type(fireclickdetector) ~= 'function' then
        Library:Notify('fireclickdetector missing on this executor')
        return false
    end
    local pick = nearestHarvestable(Options.BL_HarvestSkip.Value)
    if not pick then return false end
    if not teleportTo(pick.part.CFrame) then return false end
    harvestedAt[pick.detector] = os.clock()
    fireclickdetector(pick.detector)
    return true
end

UtilGrp:AddButton({ Text = 'Harvest Nearest Item', Func = function()
    if not harvestOnce() then Library:Notify('No harvestable item loaded (StreamingEnabled hides far ones)') end
end })
UtilGrp:AddToggle('BL_AutoHarvest', { Text = 'Auto Harvest', Default = false,
    Tooltip = 'Repeats Harvest Nearest Item. Untested in game.' })

local harvestRun = 0
Toggles.BL_AutoHarvest:OnChanged(function()
    harvestRun = harvestRun + 1
    local mine = harvestRun
    if not Toggles.BL_AutoHarvest.Value then return end
    task.spawn(function()
        local warned = false
        while harvestRun == mine and Toggles.BL_AutoHarvest.Value do
            if getCharacter() then
                if harvestOnce() then
                    warned = false
                elseif not warned then
                    warned = true
                    Library:Notify('Auto Harvest: nothing harvestable loaded; move toward resources')
                end
            end
            task.wait(Options.BL_HarvestInterval.Value)
        end
    end)
end)
onCleanup(function() harvestRun = harvestRun + 1 end)

UtilGrp:AddToggle('BL_AntiAfk', { Text = 'Anti AFK', Default = false })
do
    local ok, virtualUser = pcall(game.GetService, game, 'VirtualUser')
    if ok and virtualUser then
        connect(LocalPlayer.Idled, function()
            if not Toggles.BL_AntiAfk.Value then return end
            virtualUser:CaptureController()
            virtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end
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
