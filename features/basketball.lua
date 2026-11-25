-- ================================================================
--  features/basketball.lua
--  Auto Release | Auto Timing | Contest Meter | Guard Assist
--
--  Loaded by main.lua for PlaceId 80681221431821 / 119587547774646
--  or GameId 7529591378. Every game value below comes from the dump
--  Universal_119587547774646_1795566014.txt (PlaceVersion 484); see
--  GAME for where each one was read.
-- ================================================================

-- >>> PURE (no Roblox or executor globals until <<< PURE)

local Pure = {}

-- Grade index sent by InterfaceService.ShowFeedback (3rd argument),
-- table copied from Modules.UI.Character.ShotFeedback.
Pure.GRADES = { 'Very Early', 'Early', 'Slightly Early', 'Good', 'Perfect', 'Slightly Late', 'Late', 'Very Late' }

-- Signed correction in calibration steps for a grade index: positive
-- means "release later next time". Perfect and unknown give 0.
local GRADE_STEPS = { 3, 2, 1, 0.5, 0, -1, -2, -3 }
function Pure.gradeCorrection(index)
    return GRADE_STEPS[index] or 0
end

-- New release target after a graded shot. releasedAt is the meter
-- progress seen when the server marked the shot released.
function Pure.nextTarget(releasedAt, gradeIndex, step)
    return math.max(0, releasedAt + Pure.gradeCorrection(gradeIndex) * step)
end

-- Fire the release when progress plus the distance the meter will
-- travel during `lead` seconds reaches the target.
function Pure.shouldRelease(progress, rate, lead, target)
    if target == nil or progress ~= progress then return false end
    local ahead = progress + math.max(rate, 0) * math.max(lead, 0)
    return ahead >= target
end

-- Smoothed rate of change; dt <= 0 keeps the old rate.
function Pure.updateRate(oldRate, prevValue, value, dt, smoothing)
    if dt <= 0 or prevValue == nil then return oldRate end
    local instant = (value - prevValue) / dt
    if oldRate == nil then return instant end
    return oldRate + (instant - oldRate) * smoothing
end

-- Contest estimate 0..1 for one defender (same as before, see thread):
-- closeness first, reduced when the defender looks away, raised when
-- the defender stands on the shooter->hoop line.
function Pure.contestScore(dist, range, facingDot, between)
    if range <= 0 or dist ~= dist or dist >= range then return 0 end
    local closeness = 1 - math.max(dist, 0) / range
    local facing = 0.35 + 0.65 * math.clamp((facingDot + 1) / 2, 0, 1)
    local score = closeness * facing
    if between ~= nil then
        score = score * (0.6 + 0.4 * math.clamp(between, 0, 1))
    end
    return math.clamp(score, 0, 1)
end

function Pure.flatDist(ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    return math.sqrt(dx * dx + dz * dz)
end

function Pure.unit(x, z)
    local m = math.sqrt(x * x + z * z)
    if m < 1e-6 then return 0, 0 end
    return x / m, z / m
end

function Pure.betweenFactor(sx, sz, hx, hz, dx, dz, width)
    local vx, vz = hx - sx, hz - sz
    local len2 = vx * vx + vz * vz
    if len2 < 1e-6 then return 0 end
    local t = ((dx - sx) * vx + (dz - sz) * vz) / len2
    if t < 0 or t > 1 then return 0 end
    local px, pz = sx + vx * t, sz + vz * t
    return math.clamp(1 - Pure.flatDist(px, pz, dx, dz) / width, 0, 1)
end

-- Team rule copied from Controllers.Characters.Character.Animations
-- ("Opposite" filter): a player is a teammate only when both share a
-- team number and that number is not 0.
function Pure.isOpponentTeam(myTeam, theirTeam)
    return not (theirTeam == myTeam and myTeam ~= 0)
end

-- The game's own mobile guard assist (Movement.ApplyGuardAssist):
-- stand `dist` studs from the handler toward the handler's goal, and
-- blend that direction into the input with weight
-- clamp(offset / 5, 0, 1) * strength. Returns a unit {x, z}.
function Pure.guardAssistDir(ix, iz, mx, mz, hx, hz, gx, gz, dist, strength)
    local ux, uz = Pure.unit(gx - hx, gz - hz)
    local px, pz = hx + ux * dist - mx, hz + uz * dist - mz
    local off = math.sqrt(px * px + pz * pz)
    if off < 1e-6 then return Pure.unit(ix, iz) end
    local w = math.clamp(off / 5, 0, 1) * strength
    return Pure.unit(ix * (1 - w) + px / off * w, iz * (1 - w) + pz / off * w)
end

-- The game turns the ControlModule move vector m into a world
-- direction with Movement.calculateRawMoveVector, using camera matrix
-- entries c = R22, s = R02 (s replaced by -R01*sign(R12) when
-- |R12| >= 1). These two are that map and its inverse.
function Pure.rawFromMove(c, s, mx, mz)
    local n = math.sqrt(c * c + s * s)
    if n < 1e-9 then return 0, 0 end
    return (c * mx + s * mz) / n, (c * mz - s * mx) / n
end

function Pure.moveFromRaw(c, s, dx, dz)
    local n = math.sqrt(c * c + s * s)
    if n < 1e-9 then return 0, 0 end
    return (c * dx - s * dz) / n, (s * dx + c * dz) / n
end

-- <<< PURE

return function(State, Tabs, Services, Library)

local Tab = Tabs.Basketball
if not Tab then return end

local RunService        = Services.RunService
local Players           = Services.Players
local UserInputService  = Services.UserInputService
local LocalPlayer       = Services.LocalPlayer

-- ================================================================
--  GAME VALUES  (source: dump of PlaceId 119587547774646, PlaceVersion 484)
-- ================================================================

local GAME = {
    -- workspace.Characters[<player name>] Models; Controllers.Attributes registers them.
    CharactersFolder = { 'Workspace', 'Characters' },
    -- Aero remotes. InputService.Shoot is fired with { Shoot = true, Input = 'E' } on
    -- press and { Shoot = false } on release (Modules.Components.Input.Keyboard L231-L308).
    ShootRemote    = { 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InputService', 'Shoot' },
    -- OnClientEvent(characterModel, contestPercentString, gradeIndexString)
    -- (Modules.UI.Character.ShotFeedback L17-L24).
    FeedbackRemote = { 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InterfaceService', 'ShowFeedback' },
    -- Character attributes read here (instance attributes or Attributes/<name> values):
    --   meterOffset (Vector2, server-driven meter fill; Controllers.Meter L90)
    --   Action ('Shooting' while shooting), ReleasedShot (bool), BaseAnimation,
    --   Team (number), Basketball (truthy when holding), HoldingG (game's guard key),
    --   Goal (ObjectValue -> Workspace.Hoops._HoopN.Goal, the hoop that player attacks)
    ShootingAction = 'Shooting',
    -- Animations.Types.Guard reacts to a shooter within 12 studs; used only as
    -- the default contest range of the estimate.
    GuardReactRange = 12,
    -- Movement.ApplyGuardAssist constants (the game's mobile assist).
    AssistDistance = 3.25,
    AssistStrength = 0.425,
}

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
--  HELPERS
-- ================================================================

local function opt(name, fallback)
    local o = Options and Options[name]
    if o and o.Value ~= nil then return o.Value end
    return fallback
end

local function on(name)
    return Toggles and Toggles[name] and Toggles[name].Value == true
end

local function keyHeld(name)
    local o = Options and Options[name]
    if not o or type(o.GetState) ~= 'function' then return false end
    local ok, state = pcall(o.GetState, o)
    return ok and state == true
end

local function resolve(path)
    local node = game
    for i, name in ipairs(path) do
        if i == 1 then
            local ok, svc = pcall(game.GetService, game, name)
            node = ok and svc or nil
        else
            node = node and node:FindFirstChild(name)
        end
        if not node then return nil end
    end
    return node
end

local function finiteVec(v)
    return v ~= nil and v.X == v.X and v.Y == v.Y and v.Z == v.Z
        and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

-- Instance attribute first, then the Attributes folder value object.
local function attr(model, name)
    local ok, v = pcall(model.GetAttribute, model, name)
    if ok and v ~= nil then return v end
    local folder = model:FindFirstChild('Attributes')
    local obj = folder and folder:FindFirstChild(name)
    if obj and obj:IsA('ValueBase') then return obj.Value end
    return nil
end

local function charactersFolder()
    return resolve(GAME.CharactersFolder)
end

local function modelOf(player)
    local folder = charactersFolder()
    return folder and folder:FindFirstChild(player.Name) or nil
end

local function rootOfModel(model)
    local root = model and model:FindFirstChild('HumanoidRootPart')
    if root and root:IsA('BasePart') and finiteVec(root.Position) then return root end
    return nil
end

local function goalPos(model)
    local g = model and attr(model, 'Goal')
    if typeof(g) == 'Instance' and g:IsA('BasePart') and finiteVec(g.Position) then return g.Position end
    return nil
end

local function isOpponent(player, myModel)
    if player == LocalPlayer then return false end
    local theirs = modelOf(player)
    if not theirs then return false end
    local myTeam = tonumber(myModel and attr(myModel, 'Team')) or 0
    local theirTeam = tonumber(attr(theirs, 'Team')) or 0
    return Pure.isOpponentTeam(myTeam, theirTeam), theirs
end

-- ================================================================
--  AUTO RELEASE + AUTO TIMING
--  Progress = magnitude of the server-driven meterOffset attribute on
--  your character. Targets are learned per BaseAnimation from the
--  game's own release grades; nothing about the green window is
--  assumed.
-- ================================================================

local ShootRemote    = resolve(GAME.ShootRemote)
local FeedbackRemote = resolve(GAME.FeedbackRemote)

local shot = {
    active = false, released = false, key = nil,
    progress = 0, prevProgress = nil, prevAt = nil, rate = nil,
    releasedAt = nil, autoFired = false,
}
local targets = {}      -- [BaseAnimation] = progress to release at
local lastFeedback = nil -- { grade, contest, key, releasedAt, auto }

local function progressOf(model)
    local v = attr(model, 'meterOffset')
    if typeof(v) == 'Vector2' and v.X == v.X and v.Y == v.Y then return v.Magnitude end
    return nil
end

local function resetShot()
    shot.active, shot.released, shot.key = false, false, nil
    shot.progress, shot.prevProgress, shot.prevAt, shot.rate = 0, nil, nil, nil
    shot.releasedAt, shot.autoFired = nil, false
end

local function fireRelease()
    if not ShootRemote then return false end
    local ok = pcall(function() ShootRemote:FireServer({ Shoot = false }) end)
    return ok
end

local function oneWayPing()
    local ok, rtt = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(rtt) == 'number' and rtt == rtt and rtt >= 0 and rtt < 2 then return rtt end
    return 0
end

if FeedbackRemote then
    connect(FeedbackRemote.OnClientEvent, function(model, contest, grade)
        local myModel = modelOf(LocalPlayer)
        if not myModel or model ~= myModel then return end
        local gi = tonumber(grade)
        local key = shot.key or (attr(myModel, 'BaseAnimation') and tostring(attr(myModel, 'BaseAnimation'))) or '?'
        lastFeedback = {
            grade = gi and Pure.GRADES[gi] or tostring(grade),
            contest = tonumber(contest), key = key,
            releasedAt = shot.releasedAt, auto = shot.autoFired,
        }
        if on('BB_AutoTiming') and gi and shot.releasedAt then
            targets[key] = Pure.nextTarget(shot.releasedAt, gi, opt('BB_CalStep', 0.03))
        end
    end)
end

local function stepShot(myModel)
    local action = attr(myModel, 'Action')
    local shooting = action == GAME.ShootingAction
    if shooting and not shot.active then
        resetShot()
        shot.active = true
        local base = attr(myModel, 'BaseAnimation')
        shot.key = base and tostring(base) or '?'
    elseif not shooting and shot.active then
        shot.active = false
    end
    if not shot.active then return end

    local p = progressOf(myModel)
    if p then
        local now = os.clock()
        if shot.prevProgress ~= p then
            shot.rate = Pure.updateRate(shot.rate, shot.prevProgress, p, shot.prevAt and now - shot.prevAt or 0, 0.5)
            shot.prevProgress, shot.prevAt = p, now
        end
        shot.progress = p
    end

    if attr(myModel, 'ReleasedShot') == true and not shot.released then
        shot.released = true
        shot.releasedAt = shot.progress
        return
    end

    if shot.released or shot.autoFired or not on('BB_AutoRelease') then return end
    local target = targets[shot.key]
    local lead = on('BB_PingComp') and oneWayPing() / 2 or 0
    lead = lead + opt('BB_ExtraLeadMs', 0) / 1000
    if Pure.shouldRelease(shot.progress, shot.rate or 0, lead, target) then
        if fireRelease() then shot.autoFired = true end
    end
end

-- ================================================================
--  CONTEST METER  (live estimate + the game's real number after a shot)
-- ================================================================

local meter = {}

local function buildMeter()
    if meter.gui then return end
    local parent
    if type(gethui) == 'function' then
        local ok, h = pcall(gethui)
        if ok then parent = h end
    end
    parent = parent or LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not parent then return end

    local gui = Instance.new('ScreenGui')
    gui.Name = 'YazuContestMeter'
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 1000

    local frame = Instance.new('Frame')
    frame.AnchorPoint = Vector2.new(0.5, 1)
    frame.Position = UDim2.new(0.5, 0, 1, -140)
    frame.Size = UDim2.fromOffset(300, 52)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local c1 = Instance.new('UICorner'); c1.CornerRadius = UDim.new(0, 8); c1.Parent = frame

    local function text(y, size, color)
        local t = Instance.new('TextLabel')
        t.BackgroundTransparency = 1
        t.Position = UDim2.fromOffset(8, y)
        t.Size = UDim2.new(1, -16, 0, 16)
        t.Font = Enum.Font.GothamMedium
        t.TextSize = size
        t.TextColor3 = color
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.TextTruncate = Enum.TextTruncate.AtEnd
        t.Text = ''
        t.Parent = frame
        return t
    end
    local live = text(3, 13, Color3.fromRGB(235, 235, 245))
    local last = text(34, 12, Color3.fromRGB(160, 160, 180))

    local barBg = Instance.new('Frame')
    barBg.Position = UDim2.fromOffset(8, 22)
    barBg.Size = UDim2.new(1, -16, 0, 6)
    barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    barBg.BorderSizePixel = 0
    barBg.Parent = frame
    local c2 = Instance.new('UICorner'); c2.CornerRadius = UDim.new(0, 3); c2.Parent = barBg
    local fill = Instance.new('Frame')
    fill.Size = UDim2.fromScale(0, 1)
    fill.BorderSizePixel = 0
    fill.Parent = barBg
    local c3 = Instance.new('UICorner'); c3.CornerRadius = UDim.new(0, 3); c3.Parent = fill

    gui.Parent = parent
    meter.gui, meter.fill, meter.live, meter.last = gui, fill, live, last
end

local function destroyMeter()
    if meter.gui then pcall(function() meter.gui:Destroy() end) end
    meter = {}
end
onCleanup(destroyMeter)

local GREEN, YELLOW, RED = Color3.fromRGB(80, 220, 120), Color3.fromRGB(240, 200, 70), Color3.fromRGB(240, 80, 80)

local function readContest(myModel)
    local myRoot = rootOfModel(myModel)
    if not myRoot then return 0, nil, nil end
    local range = opt('BB_ContestRange', GAME.GuardReactRange)
    local my = myRoot.Position
    local hoop = goalPos(myModel)
    local best, bestPlayer, bestDist = 0, nil, nil
    for _, p in ipairs(Players:GetPlayers()) do
        local opp, model = isOpponent(p, myModel)
        local root = opp and rootOfModel(model)
        if root then
            local d = root.Position
            local dist = Pure.flatDist(my.X, my.Z, d.X, d.Z)
            if dist < range then
                local ux, uz = Pure.unit(my.X - d.X, my.Z - d.Z)
                local look = root.CFrame.LookVector
                local lx, lz = Pure.unit(look.X, look.Z)
                local between = hoop and Pure.betweenFactor(my.X, my.Z, hoop.X, hoop.Z, d.X, d.Z, 4) or nil
                local s = Pure.contestScore(dist, range, lx * ux + lz * uz, between)
                if s > best then best, bestPlayer, bestDist = s, p, dist end
            end
        end
    end
    return best, bestPlayer, bestDist
end

local function drawMeter(myModel)
    if not on('BB_ContestMeter') then
        if meter.gui then meter.gui.Enabled = false end
        return
    end
    buildMeter()
    if not meter.gui then return end
    meter.gui.Enabled = true
    local score, who, dist = readContest(myModel)
    meter.fill.Size = UDim2.fromScale(score, 1)
    meter.fill.BackgroundColor3 = score < 0.34 and GREEN or (score < 0.67 and YELLOW or RED)
    if who then
        meter.live.Text = string.format('EST. CONTEST %d%%  %s  %.1f studs', math.floor(score * 100 + 0.5), who.DisplayName, dist)
    else
        meter.live.Text = 'OPEN'
    end
    if lastFeedback then
        meter.last.Text = string.format('last shot: %s%% contested, %s%s', lastFeedback.contest and tostring(math.floor(lastFeedback.contest + 0.5)) or '?',
            tostring(lastFeedback.grade), lastFeedback.auto and ' (auto)' or '')
    else
        meter.last.Text = 'last shot: none yet'
    end
end

-- ================================================================
--  GUARD ASSIST
--  The game reads movement from PlayerModule's ControlModule
--  (Movement.UpdateMoveDirection: u5:GetControls():GetMoveVector()).
--  While active, GetMoveVector on that instance returns your input
--  blended toward the guard spot, converted back to the camera space
--  calculateRawMoveVector expects, so client prediction and the
--  MoveDirection sent to the server agree.
-- ================================================================

local assist = { controls = nil, original = nil, hadRaw = false, target = nil, active = false, dir = nil }

local function getControls()
    local scripts = LocalPlayer:FindFirstChild('PlayerScripts')
    local pm = scripts and scripts:FindFirstChild('PlayerModule')
    if not pm then return nil, 'PlayerScripts.PlayerModule not found' end
    local ok, mod = pcall(require, pm)
    if not ok or type(mod) ~= 'table' or type(mod.GetControls) ~= 'function' then return nil, 'PlayerModule require failed' end
    local okC, controls = pcall(mod.GetControls, mod)
    if not okC or type(controls) ~= 'table' or type(controls.GetMoveVector) ~= 'function' then return nil, 'ControlModule.GetMoveVector missing' end
    return controls
end

local function cameraBasis()
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local _, _, _, _, r01, r02, _, _, r12, _, _, r22 = cam.CFrame:GetComponents()
    local s = r02
    if r12 >= 1 or r12 <= -1 then s = -r01 * math.sign(r12) end
    return r22, s
end

local function installMoveHook()
    if assist.controls then return true end
    local controls, err = getControls()
    if not controls then
        Library:Notify('Guard Assist: ' .. tostring(err), 6)
        return false
    end
    assist.hadRaw = rawget(controls, 'GetMoveVector') ~= nil
    assist.original = assist.hadRaw and rawget(controls, 'GetMoveVector') or controls.GetMoveVector
    local original = assist.original
    controls.GetMoveVector = function(self, ...)
        local v = original(self, ...)
        local d = assist.active and assist.dir
        if not d or typeof(v) ~= 'Vector3' then return v end
        local c, s = cameraBasis()
        if not c then return v end
        local wx, wz = Pure.rawFromMove(c, s, v.X, v.Z)
        local ox, oz = Pure.guardAssistDir(wx, wz, d.mx, d.mz, d.hx, d.hz, d.gx, d.gz, d.dist, d.strength)
        if ox == 0 and oz == 0 then return v end
        local mx, mz = Pure.moveFromRaw(c, s, ox, oz)
        return Vector3.new(mx, 0, mz)
    end
    assist.controls = controls
    return true
end

local function removeMoveHook()
    local controls = assist.controls
    if not controls then return end
    if assist.hadRaw then
        controls.GetMoveVector = assist.original
    else
        controls.GetMoveVector = nil
    end
    assist.controls, assist.original, assist.hadRaw = nil, nil, false
end
onCleanup(function()
    assist.active, assist.dir = false, nil
    removeMoveHook()
end)

local windowFocused = true
connect(UserInputService.WindowFocusReleased, function()
    windowFocused = false
    assist.active, assist.dir = false, nil
end)
connect(UserInputService.WindowFocused, function() windowFocused = true end)

local function pickHandler(myModel, myPos, range)
    local best, bestD, bestHasBall = nil, math.huge, false
    for _, p in ipairs(Players:GetPlayers()) do
        local opp, model = isOpponent(p, myModel)
        local root = opp and rootOfModel(model)
        if root then
            local d = Pure.flatDist(myPos.X, myPos.Z, root.Position.X, root.Position.Z)
            local hasBall = attr(model, 'Basketball') and true or false
            if d < range and ((hasBall and not bestHasBall) or (hasBall == bestHasBall and d < bestD)) then
                best, bestD, bestHasBall = model, d, hasBall
            end
        end
    end
    return best
end

local function stepAssist(myModel)
    local wanted = on('BB_GuardAssist') and windowFocused
        and (keyHeld('BB_GuardKey') or (on('BB_AssistOnGameGuard') and attr(myModel, 'HoldingG') == true))
    if not wanted then
        assist.active, assist.dir, assist.target = false, nil, nil
        return
    end
    if not installMoveHook() then
        if Toggles.BB_GuardAssist then Toggles.BB_GuardAssist:SetValue(false) end
        return
    end
    local myRoot = rootOfModel(myModel)
    if not myRoot then
        assist.active, assist.dir = false, nil
        return
    end
    local my = myRoot.Position
    local range = opt('BB_AssistRange', 25)
    local target = assist.target
    local tRoot = target and target.Parent and rootOfModel(target)
    if not tRoot or Pure.flatDist(my.X, my.Z, tRoot.Position.X, tRoot.Position.Z) > range then
        target = pickHandler(myModel, my, range)
        tRoot = target and rootOfModel(target)
    end
    assist.target = target
    -- The handler's goal; without it the assist has no direction to defend.
    local goal = target and goalPos(target)
    if not tRoot or not goal then
        assist.active, assist.dir = false, nil
        return
    end
    local h = tRoot.Position
    assist.dir = { mx = my.X, mz = my.Z, hx = h.X, hz = h.Z, gx = goal.X, gz = goal.Z,
        dist = opt('BB_GuardDistance', GAME.AssistDistance), strength = opt('BB_AssistStrength', GAME.AssistStrength) }
    assist.active = true
end

-- ================================================================
--  MAIN LOOP
-- ================================================================

connect(RunService.Heartbeat, function()
    local myModel = modelOf(LocalPlayer)
    if not myModel then
        if shot.active then resetShot() end
        assist.active, assist.dir = false, nil
        return
    end
    pcall(stepShot, myModel)
    pcall(stepAssist, myModel)
end)

local lastDraw = 0
connect(RunService.RenderStepped, function()
    local now = os.clock()
    if now - lastDraw < 1 / 30 then return end
    lastDraw = now
    local myModel = modelOf(LocalPlayer)
    if myModel then pcall(drawMeter, myModel) elseif meter.gui then meter.gui.Enabled = false end
end)

-- ================================================================
--  UI
-- ================================================================

local Shoot = Tab:AddLeftGroupbox('Shooting')
Shoot:AddToggle('BB_AutoRelease', { Text = 'Auto Release', Default = false })
Shoot:AddToggle('BB_AutoTiming', { Text = 'Auto Timing (learn from release grades)', Default = true })
Shoot:AddToggle('BB_PingComp', { Text = 'Ping Compensation', Default = true })
Shoot:AddSlider('BB_ExtraLeadMs', { Text = 'Extra Lead (ms)', Default = 0, Min = -100, Max = 150, Rounding = 0 })
Shoot:AddSlider('BB_CalStep', { Text = 'Learning Step (uncalibrated)', Default = 0.03, Min = 0.005, Max = 0.2, Rounding = 3 })
Shoot:AddButton({ Text = 'Show Learned Targets', Func = function()
    local parts = {}
    for k, v in pairs(targets) do parts[#parts + 1] = string.format('%s=%.3f', k, v) end
    table.sort(parts)
    Library:Notify(#parts > 0 and table.concat(parts, '  ') or 'No targets yet: take a few shots with Auto Timing on', 8)
end })
Shoot:AddButton({ Text = 'Reset Learned Targets', Func = function()
    targets = {}
    Library:Notify('Learned targets cleared')
end })
Shoot:AddLabel('Auto Release needs a learned target: shoot normally a few times with Auto Timing on, then enable it.', true)
if not ShootRemote then Shoot:AddLabel('!! InputService.Shoot remote not found; Auto Release is off', true) end
if not FeedbackRemote then Shoot:AddLabel('!! InterfaceService.ShowFeedback not found; Auto Timing cannot learn', true) end

local Defense = Tab:AddRightGroupbox('Defense')
Defense:AddToggle('BB_GuardAssist', { Text = 'Guard Assist', Default = false })
Defense:AddLabel('Assist Key'):AddKeyPicker('BB_GuardKey', { Default = 'None', Text = 'Guard Assist Key', Mode = 'Hold' })
Defense:AddToggle('BB_AssistOnGameGuard', { Text = 'Also while holding game guard (G)', Default = true })
Defense:AddSlider('BB_AssistStrength', { Text = 'Assist Strength', Default = GAME.AssistStrength, Min = 0.1, Max = 1, Rounding = 3 })
Defense:AddSlider('BB_GuardDistance', { Text = 'Guard Distance (studs)', Default = GAME.AssistDistance, Min = 1.5, Max = 8, Rounding = 2 })
Defense:AddSlider('BB_AssistRange', { Text = 'Target Range (studs)', Default = 25, Min = 5, Max = 80, Rounding = 0 })

local Info = Tab:AddRightGroupbox('Contest')
Info:AddToggle('BB_ContestMeter', { Text = 'Contest Meter', Default = false })
Info:AddSlider('BB_ContestRange', { Text = 'Estimate Range (studs)', Default = GAME.GuardReactRange, Min = 4, Max = 30, Rounding = 0 })
Info:AddLabel('Top line is an estimate; "last shot" is the game\'s real contest % and grade.', true)

end -- return function
