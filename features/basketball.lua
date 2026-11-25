-- ================================================================
--  features/basketball.lua
--  Contest Meter | Guard Speed | Guard Assist
--  Loaded by main.lua only when game.PlaceId or game.GameId is
--  80681221431821.
--
--  Everything here is generic Roblox character math; it reads no
--  game-specific remotes or modules. Values that depend on this
--  game's code are in GAME below and start unset (nil): features
--  that need them say so in the UI instead of guessing.
--
--  Auto Release / Auto Timing are not in this file yet: they need the
--  game's shooting code (shot meter script + shoot remote) from a
--  universal dump of a match server.
-- ================================================================

-- >>> PURE (no Roblox or executor globals until <<< PURE)

local Pure = {}

-- Contest estimate 0..1 for one defender.
--   dist       studs between shooter and defender (flat)
--   range      studs at which contest reaches 0 (UI setting)
--   facingDot  dot(defender look, unit dir defender->shooter), -1..1
--   between    0..1, how much the defender sits on the shooter->hoop
--              line; pass nil when no hoop is known
-- Closeness dominates; a defender looking away contests less; a
-- defender between shooter and hoop contests more.
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

-- 2D helpers on the XZ plane; vectors are {x, z} tables so this is
-- testable without Roblox.
function Pure.flatDist(ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    return math.sqrt(dx * dx + dz * dz)
end

function Pure.unit(x, z)
    local m = math.sqrt(x * x + z * z)
    if m < 1e-6 then return 0, 0 end
    return x / m, z / m
end

-- How much point D lies on segment S->H, 0..1: 1 when D is on the
-- segment, falling to 0 at `width` studs off it or outside its ends.
function Pure.betweenFactor(sx, sz, hx, hz, dx, dz, width)
    local vx, vz = hx - sx, hz - sz
    local len2 = vx * vx + vz * vz
    if len2 < 1e-6 then return 0 end
    local t = ((dx - sx) * vx + (dz - sz) * vz) / len2
    if t < 0 or t > 1 then return 0 end
    local px, pz = sx + vx * t, sz + vz * t
    local off = Pure.flatDist(px, pz, dx, dz)
    return math.clamp(1 - off / width, 0, 1)
end

-- Where a defender should stand: `dist` studs from the target toward
-- the anchor (the hoop when known, otherwise the defender's own spot).
function Pure.guardPoint(tx, tz, ax, az, dist)
    local ux, uz = Pure.unit(ax - tx, az - tz)
    if ux == 0 and uz == 0 then return tx, tz end
    return tx + ux * dist, tz + uz * dist
end

-- Speed to apply while guarding. If the game changed WalkSpeed since
-- our last write, that new value becomes the base.
function Pure.nextWalkSpeed(current, lastSet, base, mult)
    if lastSet == nil or math.abs(current - lastSet) > 1e-3 then base = current end
    return base * mult, base
end

-- <<< PURE

return function(State, Tabs, Services, Library)

local Tab = Tabs.Basketball
if not Tab then return end

local RunService       = Services.RunService
local Players          = Services.Players
local UserInputService = Services.UserInputService
local LocalPlayer      = Services.LocalPlayer

-- ================================================================
--  GAME VALUES (unset until confirmed from a dump of a match server)
-- ================================================================

local GAME = {
    -- Hoop rims to measure "between shooter and hoop". Each entry is an
    -- instance path from game, e.g. { 'Workspace', 'Court', 'HoopA', 'Rim' }.
    -- Source: none yet. Unset = contest uses distance and facing only,
    -- and Guard Assist anchors on your own position.
    HoopPaths = nil,
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

local function finiteVec(v)
    return v and v.X == v.X and v.Y == v.Y and v.Z == v.Z
        and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

local function rootOf(player)
    local char = player and player.Character
    if not char then return nil, nil end
    local root = char:FindFirstChild('HumanoidRootPart')
    local hum = char:FindFirstChildOfClass('Humanoid')
    if not root or not hum or hum.Health <= 0 or not finiteVec(root.Position) then return nil, nil end
    return root, hum
end

local function isOpponent(player)
    if player == LocalPlayer then return false end
    if on('BB_IgnoreTeam') and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then return false end
    return true
end

local hoopCache, hoopCacheAt = nil, 0
local function hoops()
    if not GAME.HoopPaths then return nil end
    if hoopCache and os.clock() - hoopCacheAt < 2 then return hoopCache end
    local list = {}
    for _, path in ipairs(GAME.HoopPaths) do
        local node = game
        for _, name in ipairs(path) do
            node = node and node:FindFirstChild(name)
        end
        if node and node:IsA('BasePart') then list[#list + 1] = node end
    end
    hoopCache, hoopCacheAt = list, os.clock()
    return #list > 0 and list or nil
end

-- Nearest known hoop to a position, or nil.
local function nearestHoop(pos)
    local list = hoops()
    if not list then return nil end
    local best, bestD = nil, math.huge
    for _, h in ipairs(list) do
        local d = Pure.flatDist(pos.X, pos.Z, h.Position.X, h.Position.Z)
        if d < bestD then best, bestD = h, d end
    end
    return best and best.Position or nil
end

-- ================================================================
--  CONTEST METER
--  Estimate only: this game's own contest formula is not known.
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
    frame.Size = UDim2.fromOffset(260, 34)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local c1 = Instance.new('UICorner'); c1.CornerRadius = UDim.new(0, 8); c1.Parent = frame

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

    local text = Instance.new('TextLabel')
    text.BackgroundTransparency = 1
    text.Position = UDim2.fromOffset(8, 3)
    text.Size = UDim2.new(1, -16, 0, 16)
    text.Font = Enum.Font.GothamMedium
    text.TextSize = 13
    text.TextColor3 = Color3.fromRGB(235, 235, 245)
    text.TextXAlignment = Enum.TextXAlignment.Left
    text.Text = 'OPEN'
    text.Parent = frame

    gui.Parent = parent
    meter.gui, meter.fill, meter.text = gui, fill, text
end

local function destroyMeter()
    if meter.gui then pcall(function() meter.gui:Destroy() end) end
    meter = {}
end
onCleanup(destroyMeter)

local GREEN, YELLOW, RED = Color3.fromRGB(80, 220, 120), Color3.fromRGB(240, 200, 70), Color3.fromRGB(240, 80, 80)

local function readContest()
    local myRoot = rootOf(LocalPlayer)
    if not myRoot then return 0, nil, nil end
    local range = opt('BB_ContestRange', 10)
    local my = myRoot.Position
    local hoop = nearestHoop(my)
    local best, bestPlayer, bestDist = 0, nil, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if isOpponent(p) then
            local root = rootOf(p)
            if root then
                local d = root.Position
                local dist = Pure.flatDist(my.X, my.Z, d.X, d.Z)
                if dist < range then
                    local ux, uz = Pure.unit(my.X - d.X, my.Z - d.Z)
                    local look = root.CFrame.LookVector
                    local lx, lz = Pure.unit(look.X, look.Z)
                    local facingDot = lx * ux + lz * uz
                    local between = hoop and Pure.betweenFactor(my.X, my.Z, hoop.X, hoop.Z, d.X, d.Z, 4) or nil
                    local s = Pure.contestScore(dist, range, facingDot, between)
                    if s > best then best, bestPlayer, bestDist = s, p, dist end
                end
            end
        end
    end
    return best, bestPlayer, bestDist
end

local lastMeterUpdate = 0
connect(RunService.RenderStepped, function()
    if not on('BB_ContestMeter') then
        if meter.gui then meter.gui.Enabled = false end
        return
    end
    local now = os.clock()
    if now - lastMeterUpdate < 1 / 30 then return end
    lastMeterUpdate = now
    buildMeter()
    if not meter.gui then return end
    meter.gui.Enabled = true
    local ok, score, who, dist = pcall(readContest)
    if not ok then return end
    local pct = math.floor(score * 100 + 0.5)
    meter.fill.Size = UDim2.fromScale(score, 1)
    meter.fill.BackgroundColor3 = score < 0.34 and GREEN or (score < 0.67 and YELLOW or RED)
    if who then
        meter.text.Text = string.format('CONTEST %d%%  %s  %.1f studs', pct, who.DisplayName, dist)
    else
        meter.text.Text = 'OPEN'
    end
end)

-- ================================================================
--  GUARD SPEED (WalkSpeed multiplier while the guard key is held)
-- ================================================================

local speed = { active = false, base = nil, lastSet = nil, hum = nil }

local function stopSpeed()
    if speed.active and speed.hum and speed.hum.Parent and speed.base then
        -- Only restore if nothing else changed WalkSpeed since our write.
        if speed.lastSet and math.abs(speed.hum.WalkSpeed - speed.lastSet) < 1e-3 then
            speed.hum.WalkSpeed = speed.base
        end
    end
    speed.active, speed.base, speed.lastSet, speed.hum = false, nil, nil, nil
end
onCleanup(stopSpeed)

-- ================================================================
--  GUARD ASSIST (moves you to stay in front of the nearest opponent)
-- ================================================================

local assist = { active = false, target = nil, hum = nil, autoRotate = nil }

local function stopAssist()
    if assist.hum and assist.hum.Parent then
        pcall(function() assist.hum:Move(Vector3.zero, false) end)
        if assist.autoRotate ~= nil then assist.hum.AutoRotate = assist.autoRotate end
    end
    assist.active, assist.target, assist.hum, assist.autoRotate = false, nil, nil, nil
end
onCleanup(stopAssist)

local function pickTarget(myPos, range)
    local best, bestD = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if isOpponent(p) then
            local root = rootOf(p)
            if root then
                local d = Pure.flatDist(myPos.X, myPos.Z, root.Position.X, root.Position.Z)
                if d < range and d < bestD then best, bestD = p, d end
            end
        end
    end
    return best
end

local windowFocused = true
connect(UserInputService.WindowFocusReleased, function()
    windowFocused = false
    stopAssist()
    stopSpeed()
end)
connect(UserInputService.WindowFocused, function() windowFocused = true end)

connect(RunService.Heartbeat, function()
    local guarding = windowFocused and keyHeld('BB_GuardKey')
    local myRoot, myHum = rootOf(LocalPlayer)

    -- speed
    if guarding and on('BB_GuardSpeed') and myHum then
        if speed.hum ~= myHum then
            stopSpeed()
            speed.hum = myHum
        end
        speed.active = true
        local nextSpeed, base = Pure.nextWalkSpeed(myHum.WalkSpeed, speed.lastSet, speed.base or myHum.WalkSpeed, opt('BB_SpeedMult', 1.15))
        speed.base = base
        myHum.WalkSpeed = nextSpeed
        speed.lastSet = nextSpeed
    elseif speed.active then
        stopSpeed()
    end

    -- assist
    if not (guarding and on('BB_GuardAssist') and myRoot and myHum) then
        if assist.active then stopAssist() end
        return
    end
    if assist.hum ~= myHum then
        stopAssist()
        assist.hum = myHum
    end
    assist.active = true

    local my = myRoot.Position
    local range = opt('BB_AssistRange', 25)
    local tRoot = assist.target and rootOf(assist.target)
    if not tRoot or not isOpponent(assist.target)
        or Pure.flatDist(my.X, my.Z, tRoot.Position.X, tRoot.Position.Z) > range then
        assist.target = pickTarget(my, range)
        tRoot = assist.target and rootOf(assist.target)
    end
    if not tRoot then
        myHum:Move(Vector3.zero, false)
        return
    end

    local t = tRoot.Position
    local anchor = nearestHoop(t) or my
    local gx, gz = Pure.guardPoint(t.X, t.Z, anchor.X, anchor.Z, opt('BB_GuardDistance', 4))
    local off = Pure.flatDist(my.X, my.Z, gx, gz)
    if off > 0.6 then
        local ux, uz = Pure.unit(gx - my.X, gz - my.Z)
        local strength = math.clamp(off / 3, 0.35, 1)
        myHum:Move(Vector3.new(ux * strength, 0, uz * strength), false)
    else
        myHum:Move(Vector3.zero, false)
    end

    if on('BB_FaceTarget') then
        if assist.autoRotate == nil then assist.autoRotate = myHum.AutoRotate end
        myHum.AutoRotate = false
        local lookAt = Vector3.new(t.X, my.Y, t.Z)
        if Pure.flatDist(my.X, my.Z, t.X, t.Z) > 0.1 then
            myRoot.CFrame = CFrame.lookAt(my, lookAt)
        end
    elseif assist.autoRotate ~= nil then
        myHum.AutoRotate = assist.autoRotate
        assist.autoRotate = nil
    end
end)

-- ================================================================
--  UI
-- ================================================================

local Left  = Tab:AddLeftGroupbox('Defense')
Left:AddLabel('Guard Key'):AddKeyPicker('BB_GuardKey', { Default = 'Q', Text = 'Guard Key', Mode = 'Hold' })
Left:AddToggle('BB_GuardSpeed', { Text = 'Guard Speed (while key held)', Default = false })
Left:AddSlider('BB_SpeedMult', { Text = 'Speed Multiplier', Default = 1.15, Min = 1, Max = 2, Rounding = 2 })
Left:AddDivider()
Left:AddToggle('BB_GuardAssist', { Text = 'Guard Assist (while key held)', Default = false })
Left:AddToggle('BB_FaceTarget', { Text = 'Face Target', Default = true })
Left:AddSlider('BB_GuardDistance', { Text = 'Guard Distance (studs)', Default = 4, Min = 1.5, Max = 10, Rounding = 1 })
Left:AddSlider('BB_AssistRange', { Text = 'Target Range (studs)', Default = 25, Min = 5, Max = 80, Rounding = 0 })
Left:AddToggle('BB_IgnoreTeam', { Text = 'Ignore Teammates (Team property)', Default = true })

local Right = Tab:AddRightGroupbox('Offense')
Right:AddToggle('BB_ContestMeter', { Text = 'Contest Meter (estimate)', Default = false })
Right:AddSlider('BB_ContestRange', { Text = 'Contest Range (studs)', Default = 10, Min = 3, Max = 30, Rounding = 0 })
Right:AddLabel(GAME.HoopPaths and 'Hoops: configured' or 'Hoops: unset (meter uses distance + facing only)', true)
Right:AddDivider()
Right:AddLabel('Auto Release / Auto Timing: needs this game\'s shot code. Run a Universal Dump inside a match and send the .txt.', true)

end -- return function
