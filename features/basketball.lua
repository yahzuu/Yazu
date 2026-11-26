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
-- halfFrame (seconds, optional): also fire when the target is less than
-- half a frame away, so the release lands on the nearest frame.
function Pure.shouldRelease(progress, rate, lead, target, halfFrame)
    if target == nil or progress ~= progress then return false end
    local ahead = progress + math.max(rate, 0) * (math.max(lead, 0) + math.max(halfFrame or 0, 0))
    return ahead >= target
end

-- Learning per shot key from one graded release at effective progress x.
--   perfects: last 5 Perfect releases -> target is their mean
--   early / late: tightest bounds seen on each side -> midpoint
--   otherwise: step from x by the grade's correction
-- A new bound drops perfects and bounds that contradict it (network
-- jitter can grade the same point differently).
function Pure.learn(st, x, gi, step)
    st = st or {}
    local perfects = st.perfects or {}
    local early, late = st.early, st.late
    local corr = Pure.gradeCorrection(gi)
    if gi == 5 then
        perfects[#perfects + 1] = x
        while #perfects > 5 do table.remove(perfects, 1) end
        if early and early >= x then early = nil end
        if late and late <= x then late = nil end
    elseif corr ~= 0 then
        local kept = {}
        if corr > 0 then
            early = math.max(early or -math.huge, x)
            if late and late <= early then late = nil end
            for _, p in ipairs(perfects) do if p > x then kept[#kept + 1] = p end end
        else
            late = math.min(late or math.huge, x)
            if early and early >= late then early = nil end
            for _, p in ipairs(perfects) do if p < x then kept[#kept + 1] = p end end
        end
        perfects = kept
    end
    local target
    if #perfects > 0 then
        local sum = 0
        for _, p in ipairs(perfects) do sum = sum + p end
        target = sum / #perfects
    elseif early and late then
        target = (early + late) / 2
    else
        target = x + corr * step
    end
    return { target = math.max(0, target), early = early, late = late, perfects = perfects }
end

-- Where the server's meter is when our release arrives, as a fraction of
-- the meter's top (1.0 = top). Measured from 25 user shot traces
-- (PlaceVersion 484): the grade follows the server's meter, which runs
-- ahead of ours by about one-way ping. Perfect releases landed at
-- 1.000 .. 1.039, the closest Good on the early side at 0.999, Goods on
-- the late side at 1.06+ (so "Good" means close, either side).
--   u      : our visible meter / meter top
--   rateU  : meter speed in tops per second
--   lead   : seconds until the server gets the release (one-way ping)
function Pure.serverProgress(u, rateU, lead)
    return u + math.max(rateU, 0) * math.max(lead, 0)
end

-- "Good" (grade 4) has no direction: decide from where we released
-- relative to the current aim. Returns a directional grade for learning
-- (3 = slightly early, 6 = slightly late) and a step factor.
function Pure.directionalGrade(gi, x, aim)
    if gi ~= 4 then return gi, 1 end
    if aim and x >= aim then return 6, 0.5 end
    return 3, 0.5
end

-- The meter is a ping-pong: meterOffset rises to a peak and falls back
-- (shot traces from PlaceVersion 484: ~0.25 -> ~1.48 in ~0.39 s, then
-- back down). Effective progress keeps counting up past the peak by
-- mirroring the falling side, so "later" is always a bigger number.
function Pure.effectiveProgress(progress, peakValue, peaked)
    if peaked then return 2 * peakValue - progress end
    return progress
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
-- deadzone (studs, optional): no pull while you are this close to the spot,
-- so you are not glued perfectly in front of the handler.
function Pure.guardAssistDir(ix, iz, mx, mz, hx, hz, gx, gz, dist, strength, deadzone)
    local ux, uz = Pure.unit(gx - hx, gz - hz)
    local px, pz = hx + ux * dist - mx, hz + uz * dist - mz
    local off = math.sqrt(px * px + pz * pz)
    if off < 1e-6 then return Pure.unit(ix, iz) end
    local w = math.clamp((off - (deadzone or 0)) / 5, 0, 1) * strength
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

-- "Z, ZX ,c" -> { 'Z', 'ZX', 'C' }; only the keyboard dribble letters
-- (Z X C V H, Keyboard L39-L61 and L215) are kept.
function Pure.splitCombos(text)
    local out = {}
    for part in tostring(text or ''):gmatch('[^,]+') do
        local combo = part:upper():gsub('[^ZXCVH]', '')
        if combo ~= '' and #out < 8 then out[#out + 1] = combo end
    end
    return out
end

-- Best release point from recent graded shots (history = { {x=, g=}, ... },
-- oldest first, x in server-progress units). Assumed grade bands around the
-- best point c, from the trace spread: Perfect |x-c| <= w, Good w..W either
-- side, Early-type grades x < c - w, Late-type x > c + w. Every candidate c
-- is scored by how far each shot is from agreeing with it (recent shots
-- weigh more); returns the middle of the best-scoring candidates.
function Pure.fitCenter(history, w, W, lo, hi, prior)
    if #history == 0 then return nil end
    lo, hi = lo or 0.8, hi or 1.3
    local best, bestCs = math.huge, {}
    local c = lo
    while c <= hi + 1e-9 do
        local pen, wt = 0, 1
        for i = #history, 1, -1 do
            local h = history[i]
            local d = h.x - c
            local ad = math.abs(d)
            local v = 0
            if h.g == 5 then
                v = math.max(ad - w, 0)
            elseif h.g == 4 then
                v = (ad < w and (w - ad) or 0) + math.max(ad - W, 0)
            elseif h.g >= 1 and h.g <= 3 then
                v = math.max(d + w, 0)
            elseif h.g >= 6 and h.g <= 8 then
                v = math.max(w - d, 0)
            end
            pen = pen + v * wt
            wt = wt * 0.9
        end
        if pen < best - 1e-9 then
            best, bestCs = pen, { c }
        elseif math.abs(pen - best) <= 1e-9 then
            bestCs[#bestCs + 1] = c
        end
        c = c + 0.002
    end
    -- Equal scores can form separate ranges (a lone "Good" fits either side):
    -- take the range nearest the prior aim, the earlier one on a tie, and the
    -- next grade settles which side was right.
    local ranges, startC = {}, bestCs[1]
    for i = 2, #bestCs + 1 do
        if i > #bestCs or bestCs[i] - bestCs[i - 1] > 0.003 then
            ranges[#ranges + 1] = (startC + bestCs[i - 1]) / 2
            startC = bestCs[i]
        end
    end
    local pick, pickD = ranges[1], math.huge
    for _, mid in ipairs(ranges) do
        local d = math.abs(mid - (prior or mid))
        if d < pickD - 0.004 then pick, pickD = mid, d end
    end
    return pick
end

-- Least-squares line through points {t=, p=}: returns a, b with p = a + b*t.
-- The meter rises in a straight line, so this gives its speed far more
-- steadily than frame-to-frame differences (those swung 2.1 .. 3.9 within
-- single shots in the traces because sample arrival times jitter).
function Pure.linearFit(pts)
    local n = #pts
    if n < 2 then return nil end
    local st, sp, stt, stp = 0, 0, 0, 0
    for _, q in ipairs(pts) do
        st, sp, stt, stp = st + q.t, sp + q.p, stt + q.t * q.t, stp + q.t * q.p
    end
    local den = n * stt - st * st
    if math.abs(den) < 1e-12 then return nil end
    local b = (n * stp - st * sp) / den
    return (sp - b * st) / n, b
end

-- Flat distance between shooter and defender after `t` seconds if both
-- keep their current velocity (closing speed matters as much as distance).
function Pure.predictDist(mx, mz, mvx, mvz, dx, dz, dvx, dvz, t)
    local px, pz = (dx + dvx * t) - (mx + mvx * t), (dz + dvz * t) - (mz + mvz * t)
    return math.sqrt(px * px + pz * pz)
end

-- Moving / fade jumpers (animation names seen in your save file:
-- FadeAway1R, CloseFade1L, StepPostFade1R, MovingShotLeft1R).
function Pure.isMovingShot(name)
    local b = tostring(name or ''):lower()
    return b:find('fade', 1, true) ~= nil or b:find('moving', 1, true) ~= nil
end

-- Auto dribble decision from the closest defender (all flat, studs and
-- studs/s). Returns nil, or a move kind and the side to go:
--   'cross', side  : defender drifting sideways ("biting") faster than
--                    biteSpeed -> cross the other way (side = -1 left / 1 right
--                    of the line from you to the defender)
--   'stepback'     : defender closing in fast and already close
-- Soul Snatcher (Config.Enum): defenders stumble more "when biting the
-- wrong way", which is what 'cross' waits for.
function Pure.dribbleDecision(mx, mz, dx, dz, dvx, dvz, range, biteSpeed, closeSpeed, closeDist)
    local rx, rz = dx - mx, dz - mz
    local dist = math.sqrt(rx * rx + rz * rz)
    if dist < 1e-3 or dist > range then return nil end
    local ux, uz = rx / dist, rz / dist
    local px, pz = -uz, ux -- right-hand side of you->defender
    local lateral = dvx * px + dvz * pz
    local closing = -(dvx * ux + dvz * uz)
    if closing > closeSpeed and dist < closeDist then return 'stepback', 0, dist end
    if math.abs(lateral) > biteSpeed then return 'cross', lateral > 0 and -1 or 1, dist end
    return nil
end

-- Is a flat point inside any of the court's bound boxes
-- (workspace.Assets.CourtBounds, the same check as
-- Characters.Character:IsInCourtBounds L698-L720, ignoring height)?
-- boxes = { {cx=, cz=, rx=, rz=, hx=, hz=} } with r = unit right axis.
function Pure.insideBoxes(x, z, boxes)
    if #boxes == 0 then return true end
    for _, b in ipairs(boxes) do
        local ox, oz = x - b.cx, z - b.cz
        local lx = ox * b.rx + oz * b.rz
        local lz = -ox * b.rz + oz * b.rx
        if math.abs(lx) <= b.hx and math.abs(lz) <= b.hz then return true end
    end
    return false
end

-- Exponential smoothing factor for a time step: 0 = no change, 1 = jump.
function Pure.smoothAlpha(dt, tau)
    if tau <= 0 then return 1 end
    return 1 - math.exp(-math.max(dt, 0) / tau)
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
    -- Highest meterOffset magnitude seen per meter type in the user's shot
    -- traces (PlaceVersion 484, Jumpshot1 + Jumpshot5). Used to turn the
    -- meter into 0..1 "of the top" so every meter shares one timing.
    MeterPeaks = { Funnel = 0.982, Funnel2 = 0.982, Pill = 0.982, Bat = 0.982, Hoop = 0.982,
        Arrow = 0.953, None = 0.943, Tube = 0.913, Diamond = 0.913, Roblox = 0.913, Rocket = 0.914,
        Vertical = 1.467 },
    -- One aim for every shot, in server-progress units: the point that
    -- covers the most Perfects (37 of 48 within +-0.02) across 13 animations
    -- in the user's traces and save file (jumpers, fades, layups, close
    -- shots). No training needed. Optional per-animation learning can
    -- still refine it (Auto Timing, off by default).
    DefaultAim = 1.035,
    -- Grade bands around the best point, in server-progress units, from the
    -- same traces: Perfects spread over ~0.04, Goods reached ~0.06 out.
    PerfectHalfWidth = 0.02, GoodHalfWidth = 0.06,
    -- Releases measured outside this range are not learned from.
    LearnMin = 0.75, LearnMax = 1.35,
    -- Normalised meter speed was 2.15 .. 2.7 tops/s in every trace; outside
    -- this a frame hitch spoiled the measurement and 2.5 is used.
    RateMin = 1.5, RateMax = 4, RateFallback = 2.5,
    -- Actions that can carry a release meter. 'ContactLayup' / 'ClutchLayup'
    -- come from Camera.Types.FirstPerson L23 and Character.Movement L174.
    -- Whether each one shows a meter is NOT confirmed: any other action is
    -- picked up by the moving-meter fallback (BB_AnyMeter).
    ShotActions = { Shooting = true, ContactLayup = true, ClutchLayup = true },
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
--  your character (meter-type independent; the ping-pong shape was
--  confirmed from shot traces). Learning is kept per BaseAnimation
--  AND meter type, from the game's own release grades.
-- ================================================================

local ShootRemote    = resolve(GAME.ShootRemote)
local FeedbackRemote = resolve(GAME.FeedbackRemote)

local shot = {
    active = false, released = false, key = nil,
    progress = 0, prevProgress = nil, prevAt = nil, rate = nil,
    releasedAt = nil, autoFired = false,
}
local learn = {}        -- [jumpshot animation] = { target, hist = last 15 graded {x, g}, perfects } (server-progress units)
local peaks = {}        -- [meter type] = meterOffset magnitude at the top of the meter
local lastFeedback = nil
local contestScale = 1   -- learned: real contest / estimate at release
local meterInfo = { meterType = nil, green = nil }
local diag = { fired = 0, lastFire = 'none', lastError = nil, shots = 0, dt = 1 / 60 }
local trace = { current = nil, last = nil }

-- Timing is learned per jumpshot/layup animation (BaseAnimation): the
-- animation decides when the release lands; the meter type only changes
-- the meter's scale, which peakFor() removes.
local serverProgressNow -- defined next to stepShot
local function shotKey(model)
    local base = model and attr(model, 'BaseAnimation')
    return base and tostring(base) or '?'
end

local function aimFor(key)
    -- Moving/fade shots adjust themselves from every graded auto shot
    -- (misses included), no training needed.
    if on('BB_AutoMoving') and Pure.isMovingShot(key) then
        local st = learn[key]
        return st and st.target or GAME.DefaultAim
    end
    if not on('BB_AutoTiming') then return GAME.DefaultAim end
    local st = learn[key]
    if on('BB_PerfectOnly') then return st and st.targetPerf or GAME.DefaultAim end
    return st and st.target or GAME.DefaultAim
end

-- Recompute both aims from the history: all grades, and Perfects only.
local function refit(st)
    st.perfects = 0
    local perf = {}
    for _, h in ipairs(st.hist) do
        if h.g == 5 then st.perfects = st.perfects + 1; perf[#perf + 1] = h end
    end
    st.target = Pure.fitCenter(st.hist, GAME.PerfectHalfWidth, GAME.GoodHalfWidth, nil, nil, GAME.DefaultAim)
    st.targetPerf = Pure.fitCenter(perf, GAME.PerfectHalfWidth, GAME.GoodHalfWidth, nil, nil, GAME.DefaultAim)
    return st
end

local function peakFor(meterType)
    if meterType == nil then return nil end
    return peaks[meterType] or GAME.MeterPeaks[meterType]
end

-- ---------------- learned state survives rejoins ----------------
local HttpService = game:GetService('HttpService')
local TARGETS_FILE = 'YazuDumper/basketball_targets.json'

local function saveTargets()
    if type(writefile) ~= 'function' then return end
    pcall(function()
        if type(isfolder) == 'function' and type(makefolder) == 'function' and not isfolder('YazuDumper') then
            makefolder('YazuDumper')
        end
        writefile(TARGETS_FILE, HttpService:JSONEncode({
            version = 3, placeVersion = game.PlaceVersion, contestScale = contestScale, learn = learn, peaks = peaks,
        }))
    end)
end

local function finiteNum(v, lo, hi)
    return type(v) == 'number' and v == v and v >= lo and v <= hi
end

local function loadTargets()
    if type(readfile) ~= 'function' or type(isfile) ~= 'function' then return end
    local ok, data = pcall(function()
        if not isfile(TARGETS_FILE) then return nil end
        return HttpService:JSONDecode(readfile(TARGETS_FILE))
    end)
    if not ok or type(data) ~= 'table' or data.version ~= 3 then return end
    if type(data.learn) == 'table' then
        for k, st in pairs(data.learn) do
            if type(k) == 'string' and type(st) == 'table' then
                local clean = { hist = {}, perfects = 0 }
                if type(st.hist) == 'table' then
                    for _, h in ipairs(st.hist) do
                        if type(h) == 'table' and finiteNum(h.x, GAME.LearnMin, GAME.LearnMax) and finiteNum(h.g, 1, 8) and #clean.hist < 15 then
                            clean.hist[#clean.hist + 1] = { x = h.x, g = math.floor(h.g) }
                        end
                    end
                end
                if #clean.hist > 0 then learn[k] = refit(clean) end
            end
        end
    end
    if type(data.peaks) == 'table' then
        for k, v in pairs(data.peaks) do
            if type(k) == 'string' and not GAME.MeterPeaks[k] and finiteNum(v, 0.01, 100) then peaks[k] = v end
        end
    end
    if finiteNum(data.contestScale, 0.1, 10) then contestScale = data.contestScale end
end
loadTargets()

-- ---------------- shot trace (what the game did, frame by frame) --
local function traceEvent(kind, fields)
    local t = trace.current or trace.last
    if not t then return end
    local e = { t = os.clock() - t.startedAt, kind = kind }
    for k, v in pairs(fields or {}) do e[k] = v end
    if #t.events < 200 then t.events[#t.events + 1] = e end
end

local function traceText(t)
    if not t then return nil end
    local out = {
        '-- Yazu basketball shot trace',
        'placeId=' .. tostring(game.PlaceId) .. ' placeVersion=' .. tostring(game.PlaceVersion),
        'key=' .. tostring(t.key) .. ' target=' .. tostring(t.target)
            .. ' meterType=' .. tostring(t.meterType) .. ' green=' .. tostring(t.green),
        'action=' .. tostring(t.action) .. ' autoRelease=' .. tostring(t.auto) .. ' ping=' .. string.format('%.3f', t.ping or 0),
        '',
        '-- samples: t(s) action progress meterOffset released',
    }
    for _, smp in ipairs(t.samples) do
        out[#out + 1] = string.format('%.3f  %s  %.4f  %s  %s', smp.t, tostring(smp.action), smp.progress or -1, tostring(smp.raw), tostring(smp.released))
    end
    out[#out + 1] = ''
    out[#out + 1] = '-- events'
    for _, e in ipairs(t.events) do
        local parts = {}
        for k, v in pairs(e) do if k ~= 't' and k ~= 'kind' then parts[#parts + 1] = k .. '=' .. tostring(v) end end
        table.sort(parts)
        out[#out + 1] = string.format('%.3f  %s  %s', e.t, e.kind, table.concat(parts, ' '))
    end
    return table.concat(out, '\n')
end

local function saveTrace(t)
    local text = traceText(t)
    if not text then return nil, 'no shot recorded yet' end
    if type(writefile) ~= 'function' then return nil, 'writefile missing' end
    local path = 'YazuDumper/bb_shot_' .. tostring(os.time()) .. '_' .. tostring(diag.shots) .. '.txt'
    local ok, err = pcall(function()
        if type(isfolder) == 'function' and type(makefolder) == 'function' and not isfolder('YazuDumper') then
            makefolder('YazuDumper')
        end
        writefile(path, text)
    end)
    if not ok then return nil, tostring(err) end
    return path
end

local function progressOf(model)
    local v = attr(model, 'meterOffset')
    if typeof(v) == 'Vector2' and v.X == v.X and v.Y == v.Y then return v.Magnitude end
    return nil
end

local function resetShot()
    shot.active, shot.released, shot.key = false, false, nil
    shot.progress, shot.prevProgress, shot.prevAt, shot.rate = 0, nil, nil, nil
    shot.releasedAt, shot.autoFired, shot.estAtRelease, shot.firedAt, shot.fireMode = nil, false, nil, nil, nil
    shot.manualAt, shot.jelly = nil, nil
    shot.maxProgress, shot.peaked = 0, false
    shot.pts, shot.t0, shot.fitA, shot.fitB = {}, nil, nil, nil
end

local function fireRelease()
    if not ShootRemote then return false end
    local ok = pcall(function() ShootRemote:FireServer({ Shoot = false }) end)
    return ok
end

-- After our release, your own key-up sends a second Shoot{Shoot=false}
-- (Input.Keyboard KeyUp L306-L318). During a layup/dunk a second shoot
-- message is the "press shoot again" jelly, so that duplicate is dropped
-- until the shot ends. Needs hookmetamethod; without it nothing changes.
local dupe = { untilT = -1, enabled = true, hooked = false }
onCleanup(function() dupe.enabled = false end)
do
    local hmm, gnm, cc = hookmetamethod, getnamecallmethod, checkcaller
    if ShootRemote and type(hmm) == 'function' and type(gnm) == 'function' and type(cc) == 'function' then
        local old
        local okH = pcall(function()
            old = hmm(game, '__namecall', function(self, ...)
                if dupe.enabled and self == ShootRemote and os.clock() < dupe.untilT and not cc() then
                    local okM, method = pcall(gnm)
                    local a = ...
                    if okM and method == 'FireServer' and type(a) == 'table' and a.Shoot == false then
                        return nil
                    end
                end
                return old(self, ...)
            end)
        end)
        dupe.hooked = okH and old ~= nil
    end
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
        local key = shot.key or shotKey(myModel)
        lastFeedback = {
            grade = gi and Pure.GRADES[gi] or tostring(grade),
            contest = tonumber(contest), key = key,
            releasedAt = shot.releasedAt, auto = shot.autoFired,
        }
        local learnX = (shot.autoFired and shot.firedAt) or (on('BB_LearnManual') and shot.manualAt) or nil
        if gi and learnX and (on('BB_AutoTiming') or (on('BB_AutoMoving') and Pure.isMovingShot(key))) then
            -- Learn from where the server's meter was when the release arrived:
            -- ours (auto) or yours (the moment you let go of the shoot key).
            local st = learn[key] or { hist = {} }
            st.hist = st.hist or {}
            -- Far outside any sweet spot = a mis-measured release (frame hitch,
            -- meter reset): not learned.
            if learnX >= GAME.LearnMin and learnX <= GAME.LearnMax then
                st.hist[#st.hist + 1] = { x = learnX, g = gi }
                while #st.hist > 15 do table.remove(st.hist, 1) end
                learn[key] = refit(st)
            end
        end
        local real = tonumber(contest)
        if real and shot.estAtRelease and shot.estAtRelease > 0.05 then
            local ratio = math.clamp((real / 100) / shot.estAtRelease, 0.2, 5)
            contestScale = contestScale + (ratio - contestScale) * 0.3
        end
        local st = learn[key]
        traceEvent('feedback', { grade = lastFeedback.grade, contest = real, estimateAtRelease = shot.estAtRelease,
            mode = shot.fireMode or (shot.manualAt and 'manual'), firedAt = shot.firedAt, manualAt = shot.manualAt,
            newTarget = st and st.target, learnedShots = st and st.hist and #st.hist, perfects = st and st.perfects,
            ping = oneWayPing() * 2, contestScale = contestScale })
        saveTargets()
        if on('BB_AutoSaveTrace') then
            local path = saveTrace(trace.current or trace.last)
            if path then Library:Notify('Shot trace: ' .. path, 4) end
        end
    end)
end

-- MeterService (Controllers.Meter L54-L98): which meter and green window the
-- server registered for your character.
do
    local svc = resolve({ 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'MeterService' })
    local reg = svc and svc:FindFirstChild('RegisterPacket')
    local upd = svc and svc:FindFirstChild('UpdateGreenWindow')
    if reg then
        connect(reg.OnClientEvent, function(model, meterType, green)
            if model == modelOf(LocalPlayer) then
                meterInfo.meterType, meterInfo.green = meterType, green
                -- The packet can land just after the shot starts: re-key before any release.
                if shot.active and not shot.autoFired and not shot.released then
                    shot.key = shotKey(model)
                    if trace.current then trace.current.key, trace.current.meterType = shot.key, meterType end
                end
                traceEvent('registerPacket', { meterType = meterType, green = green })
            end
        end)
    end
    if upd then
        connect(upd.OnClientEvent, function(model, green)
            if model == modelOf(LocalPlayer) then
                meterInfo.green = green
                traceEvent('greenWindow', { green = green })
            end
        end)
    end
end

local readContest -- defined in the contest section

local meterWatch = { last = nil }
local spaceKey = { down = false, at = -1 } -- Space Maker: see the input hooks below
-- Jelly: pressing shoot a second time (the game turns two quick taps into
-- Input "EE", Input.Keyboard AddToTap L70-L100). A second E press inside
-- the tap window, or any E press during a shot, marks a jelly.
local jellyTap = { lastE = -1, at = -1 }
local function isJellyShot()
    return shot.jelly == true or os.clock() - jellyTap.at < 0.8
end
-- Where the server's meter is (in "of the top" units) if a release left now.
serverProgressNow = function(peak)
    local lead = (on('BB_PingComp') and oneWayPing() or 0) + opt('BB_ExtraLeadMs', 0) / 1000
    local rate, p = math.abs(shot.rate or 0), Pure.effectiveProgress(shot.progress, shot.maxProgress, shot.peaked)
    if on('BB_Smooth') and shot.fitB and not shot.peaked and shot.t0 then
        -- Where the meter is right now on its line, not where the last
        -- (already old) sample said: lets the release land between frames.
        rate = shot.fitB
        local now = os.clock() - shot.t0
        local last = shot.pts[#shot.pts]
        local ahead = last and math.min(now - last.t, 0.05) or 0
        local fitP = shot.fitA + rate * (last and last.t or now)
        if math.abs(fitP - p) < 0.05 then p = fitP end
        p = p + rate * ahead
    end
    local rateU = rate / peak
    if rateU < GAME.RateMin or rateU > GAME.RateMax then rateU = GAME.RateFallback end
    local u = p / peak
    return Pure.serverProgress(u, rateU, lead), u, rateU, lead
end
-- Layup-type shot: a layup action, or a "Shooting" action whose animation
-- is a layup/floater (animation names from the dump: Layup1R, ReverseLayup1L,
-- ClutchLayup1Front, Floater...).
local function isLayupShot(action, base)
    if action ~= GAME.ShootingAction then return true end
    local b = tostring(base or ''):lower()
    return b:find('layup', 1, true) ~= nil or b:find('floater', 1, true) ~= nil or b:find('dunk', 1, true) ~= nil
end
local function stepShot(myModel)
    local action = attr(myModel, 'Action')
    local p0 = progressOf(myModel)
    local rising = p0 ~= nil and meterWatch.last ~= nil and p0 > meterWatch.last
    if p0 then meterWatch.last = p0 end
    local shooting
    if shot.active then
        shooting = action == shot.action
    else
        shooting = GAME.ShotActions[action] == true
            or (on('BB_AnyMeter') and type(action) == 'string' and action ~= '' and rising and p0 < 0.2)
    end
    if shooting and not shot.active then
        resetShot()
        shot.active = true
        shot.action = action
        diag.shots = diag.shots + 1
        shot.key = shotKey(myModel)
        trace.current = {
            startedAt = os.clock(), key = shot.key, target = aimFor(shot.key),
            meterType = meterInfo.meterType, green = meterInfo.green, action = action,
            auto = on('BB_AutoRelease'), ping = oneWayPing() * 2, samples = {}, events = {},
        }
    elseif not shooting and shot.active then
        shot.active = false
        if dupe.untilT == math.huge then dupe.untilT = os.clock() + 0.3 end
        trace.last, trace.current = trace.current, nil
    end
    if not shot.active then return end

    local p = progressOf(myModel)
    if p then
        local now = os.clock()
        if shot.prevProgress ~= p then
            shot.rate = Pure.updateRate(shot.rate, shot.prevProgress, p, shot.prevAt and now - shot.prevAt or 0, 0.5)
            -- rising samples feed the straight-line fit (last 10)
            if not shot.peaked and (shot.prevProgress == nil or p > shot.prevProgress) then
                shot.t0 = shot.t0 or now
                local pts = shot.pts
                pts[#pts + 1] = { t = now - shot.t0, p = p }
                if #pts > 10 then table.remove(pts, 1) end
                if #pts >= 4 then
                    local a, b = Pure.linearFit(pts)
                    if a and b and b > 0 then shot.fitA, shot.fitB = a, b end
                end
            end
            shot.prevProgress, shot.prevAt = p, now
        end
        shot.progress = p
        if p > shot.maxProgress then
            shot.maxProgress = p
        elseif not shot.peaked and shot.maxProgress - p > 0.02 and p >= shot.maxProgress * 0.5 then
            -- A real turn at the top (a jump back toward 0 is the meter
            -- resetting/hiding, not a peak, and is ignored).
            shot.peaked = true
            local mt = meterInfo.meterType
            -- Known meters keep their measured size (learning it from shots
            -- that end early shrank Vertical to 1.10 in a user save file).
            if mt and not GAME.MeterPeaks[mt] then
                local old = peakFor(mt)
                peaks[mt] = old and (old * 0.8 + shot.maxProgress * 0.2) or shot.maxProgress
            end
            traceEvent('peak', { value = shot.maxProgress, meterType = mt, learnedPeak = mt and peaks[mt] })
        end
    end

    local t = trace.current
    if t and #t.samples < 600 then
        local last = t.samples[#t.samples]
        local released = attr(myModel, 'ReleasedShot')
        if not last or last.progress ~= p or last.released ~= released or last.action ~= action then
            t.samples[#t.samples + 1] = { t = os.clock() - t.startedAt, action = action, progress = p,
                raw = attr(myModel, 'meterOffset'), released = released }
        end
    end

    if attr(myModel, 'ReleasedShot') == true and not shot.released then
        shot.released = true
        shot.releasedAt = Pure.effectiveProgress(shot.progress, shot.maxProgress, shot.peaked)
        local okC, est = pcall(function() return (readContest(myModel)) end)
        shot.estAtRelease = okC and est or nil
        traceEvent('serverReleased', { progress = shot.progress, effective = shot.releasedAt, peaked = shot.peaked,
            rate = shot.rate, estimate = shot.estAtRelease })
        return
    end

    if shot.released or shot.autoFired or not on('BB_AutoRelease') then return end
    -- Releasing during a layup turns it into a jelly: layups only when asked.
    local base = attr(myModel, 'BaseAnimation')
    if isLayupShot(shot.action, base) then
        if isJellyShot() then
            if not on('BB_AutoJelly') then return end
        elseif not on('BB_AutoLayup') then
            return
        end
    end
    -- Space pressed during/just before the shot: let your Space Maker happen.
    if on('BB_SpaceSkip') and (spaceKey.down or os.clock() - spaceKey.at < 0.5) then return end
    local peak = peakFor(meterInfo.meterType)
    local fire, mode, aim, su, lead = false, nil, aimFor(shot.key), nil, 0
    if peak and peak > 0 then
        -- Prefire: release when the server's meter (ours + one-way ping of travel)
        -- will be at the aim, on whichever frame lands closest to it.
        local u, rateU
        su, u, rateU, lead = serverProgressNow(peak)
        local nearest = Pure.serverProgress(u, rateU, lead + diag.dt / 2)
        mode = 'prefire'
        -- past the top and still not fired: it only gets later, go now
        fire = nearest >= aim or shot.peaked
    else
        -- Meter type the script has never seen: release at the top once, which
        -- teaches it this meter's size; the next shot prefires.
        mode = 'peak'
        fire = shot.peaked
    end
    if fire then
        local ok = fireRelease()
        if ok and on('BB_DropDupe') then dupe.untilT = math.huge end
        shot.autoFired = ok
        shot.firedAt = su
        shot.fireMode = mode
        diag.fired = diag.fired + 1
        diag.lastFire = string.format('%s at %s (aim %.3f, %s, lead %dms)', ok and 'sent' or 'FAILED',
            su and string.format('%.3f', su) or 'top', aim, mode, math.floor(lead * 1000))
        traceEvent('autoRelease', { ok = ok, mode = mode, progress = shot.progress, peak = peak, serverProgress = su,
            aim = aim, rate = shot.rate, lead = lead })
    end
end

-- React the moment the server changes the meter instead of waiting for the next Heartbeat.
local meterHook = { model = nil, conn = nil }
local function hookMeter(myModel)
    if meterHook.model == myModel then return end
    if meterHook.conn then meterHook.conn:Disconnect() end
    meterHook.model, meterHook.conn = myModel, nil
    if myModel then
        local ok, sig = pcall(myModel.GetAttributeChangedSignal, myModel, 'meterOffset')
        if ok and sig then
            meterHook.conn = sig:Connect(function()
                local okS, err = pcall(stepShot, myModel)
                if not okS then diag.lastError = 'shot: ' .. tostring(err) end
            end)
        end
    end
end
onCleanup(function() if meterHook.conn then meterHook.conn:Disconnect() end end)

-- Your own releases: the game sends Shoot{Shoot=false} the moment the shoot
-- or jump key goes up (Input.Keyboard KeyUp handler, L306-L318), so that
-- instant is when your release left. Remembered for learning.
local MANUAL_KEYS = { E = true, Space = true, ButtonX = true, ButtonA = true }
-- Space Maker (badge ability): pressing jump while shooting. Remember when
-- space went down so a shot started from space can be left to you.
connect(UserInputService.InputBegan, function(input)
    local name = input and input.KeyCode and input.KeyCode.Name
    if name == 'Space' or name == 'ButtonA' then spaceKey.down, spaceKey.at = true, os.clock() end
    if name == 'E' or name == 'ButtonX' then
        local now = os.clock()
        if shot.active or now - jellyTap.lastE < 0.45 then
            jellyTap.at = now
            if shot.active then shot.jelly = true end
        end
        jellyTap.lastE = now
    end
end)
connect(UserInputService.InputEnded, function(input)
    local name = input and input.KeyCode and input.KeyCode.Name
    if name == 'Space' or name == 'ButtonA' then spaceKey.down = false end
end)
connect(UserInputService.InputEnded, function(input)
    local name = input and input.KeyCode and input.KeyCode.Name
    if not MANUAL_KEYS[name] or not shot.active or shot.released or shot.autoFired or shot.manualAt then return end
    local peak = peakFor(meterInfo.meterType)
    if not peak or peak <= 0 then return end
    shot.manualAt = (serverProgressNow(peak))
    traceEvent('manualRelease', { key = name, progress = shot.progress, serverProgress = shot.manualAt })
end)

local function recalibrate(all)
    if all then
        learn, peaks = {}, {}
    else
        local key = shot.key or (lastFeedback and lastFeedback.key)
        if not key then
            local m = modelOf(LocalPlayer)
            key = m and shotKey(m)
        end
        if key then learn[key] = nil end
    end
    saveTargets()
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

    -- Small billboard above your head (only you see it: it is created on
    -- your client).
    local gui = Instance.new('BillboardGui')
    gui.Name = 'YazuContestMeter'
    gui.ResetOnSpawn = false
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(130, 38)
    gui.StudsOffset = Vector3.new(0, 3.4, 0)
    gui.MaxDistance = 200

    local frame = Instance.new('Frame')
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local c1 = Instance.new('UICorner'); c1.CornerRadius = UDim.new(0, 6); c1.Parent = frame

    local function text(y, h, size, color)
        local t = Instance.new('TextLabel')
        t.BackgroundTransparency = 1
        t.Position = UDim2.fromOffset(4, y)
        t.Size = UDim2.new(1, -8, 0, h)
        t.Font = Enum.Font.GothamBold
        t.TextSize = size
        t.TextColor3 = color
        t.TextXAlignment = Enum.TextXAlignment.Center
        t.TextTruncate = Enum.TextTruncate.AtEnd
        t.Text = ''
        t.Parent = frame
        return t
    end
    local live = text(2, 14, 12, Color3.fromRGB(240, 240, 248))
    local last = text(24, 12, 10, Color3.fromRGB(170, 170, 190))

    local barBg = Instance.new('Frame')
    barBg.Position = UDim2.fromOffset(6, 17)
    barBg.Size = UDim2.new(1, -12, 0, 5)
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

readContest = function(myModel)
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
                -- Where they will be by the time the shot goes up, from both
                -- players' current velocities (a defender sprinting at you
                -- contests from farther away; fading away adds space).
                local useDist = dist
                if on('BB_ContestPredict') then
                    local mv, dv = myRoot.AssemblyLinearVelocity, root.AssemblyLinearVelocity
                    local t = opt('BB_ContestLookMs', 350) / 1000
                    if typeof(mv) == 'Vector3' and typeof(dv) == 'Vector3' then
                        useDist = math.min(dist, Pure.predictDist(my.X, my.Z, mv.X, mv.Z, d.X, d.Z, dv.X, dv.Z, t))
                    end
                end
                local s = Pure.contestScore(useDist, range, lx * ux + lz * uz, between)
                if s > best then best, bestPlayer, bestDist = s, p, useDist end
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
    local root = rootOfModel(myModel)
    if meter.gui.Adornee ~= root then meter.gui.Adornee = root end
    meter.gui.Enabled = root ~= nil
    local rawScore, who, dist = readContest(myModel)
    local score = math.clamp(rawScore * contestScale, 0, 1)
    meter.fill.Size = UDim2.fromScale(score, 1)
    meter.fill.BackgroundColor3 = score < 0.34 and GREEN or (score < 0.67 and YELLOW or RED)
    if who then
        meter.live.Text = string.format('%d%% %s', math.floor(score * 100 + 0.5), who.DisplayName)
    else
        meter.live.Text = 'OPEN'
    end
    if on('BB_AutoRelease') and peakFor(meterInfo.meterType) == nil and meterInfo.meterType ~= nil then
        meter.last.Text = 'new meter: top release'
    elseif lastFeedback then
        meter.last.Text = string.format('last: %s%% %s%s', lastFeedback.contest and tostring(math.floor(lastFeedback.contest + 0.5)) or '?',
            tostring(lastFeedback.grade), '')
    else
        meter.last.Text = string.format('%.1f studs', dist or 0)
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
        local ox, oz = Pure.guardAssistDir(wx, wz, d.mx, d.mz, d.hx, d.hz, d.gx, d.gz, d.dist, d.strength, d.deadzone)
        if ox == 0 and oz == 0 then return v end
        -- Turn toward the new direction over a moment instead of snapping.
        local now = os.clock()
        local a = Pure.smoothAlpha(assist.outAt and math.min(now - assist.outAt, 0.1) or 1, d.smooth)
        assist.outAt = now
        if assist.outX then
            ox, oz = Pure.unit(assist.outX + (ox - assist.outX) * a, assist.outZ + (oz - assist.outZ) * a)
        end
        assist.outX, assist.outZ = ox, oz
        local len = math.sqrt(wx * wx + wz * wz)
        if len < 1e-3 then
            -- Standing still: drift toward the spot at a reduced pace, and only
            -- when you are outside the loose zone.
            local ux, uz = Pure.unit(d.gx - d.hx, d.gz - d.hz)
            local px, pz = d.hx + ux * d.dist - d.mx, d.hz + uz * d.dist - d.mz
            local off = math.sqrt(px * px + pz * pz)
            local mag = math.clamp((off - d.deadzone) / 4, 0, 1) * d.idle
            if mag <= 0.05 then return v end
            ox, oz = ox * mag, oz * mag
        else
            ox, oz = ox * math.min(len, 1), oz * math.min(len, 1)
        end
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
    -- Reaction time: follow where the handler WAS a moment ago (smoothed),
    -- so you react to moves late like a person instead of mirroring them.
    local now = os.clock()
    local dt = assist.seenAt and math.min(now - assist.seenAt, 0.25) or 0
    assist.seenAt = now
    if assist.seenTarget ~= target or not assist.hx then
        assist.seenTarget, assist.hx, assist.hz = target, h.X, h.Z
    else
        local a = Pure.smoothAlpha(dt, opt('BB_AssistReactionMs', 130) / 1000)
        assist.hx = assist.hx + (h.X - assist.hx) * a
        assist.hz = assist.hz + (h.Z - assist.hz) * a
    end
    assist.dir = { mx = my.X, mz = my.Z, hx = assist.hx, hz = assist.hz, gx = goal.X, gz = goal.Z,
        dist = opt('BB_GuardDistance', GAME.AssistDistance), strength = opt('BB_AssistStrength', 0.32),
        deadzone = opt('BB_AssistDeadzone', 1.0), smooth = opt('BB_AssistSmooth', 0.1), idle = opt('BB_AssistIdle', 0.6) }
    assist.active = true
end

-- ================================================================
--  DEFENSE / BALL AUTOMATION
--  Steal, block and rebound are decided by the server from its own
--  positions: the client only sends "pressed steal" / "jumped"
--  (InputService.Steal:FireServer() with no arguments, InputService.Jump,
--  Modules.Components.Input.Keyboard L231-L254). These features choose
--  WHEN to press; they cannot change reach or hitboxes.
-- ================================================================

local StealRemote   = resolve({ 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InputService', 'Steal' })
local JumpRemote    = resolve({ 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InputService', 'Jump' })
local DribbleRemote = resolve({ 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InputService', 'Dribble' })

local auto = { lastSteal = 0, lastJump = 0, blockedShots = {}, balls = {}, dribbleBusy = false, dribbleKeyWas = false }

-- Same packets the keyboard sends for the Jump bind: Shoot{Shoot=true,
-- Input='E', UseSpace=true} + Jump on press, Shoot{Shoot=false} on release.
local function jumpPress(hold)
    if not JumpRemote or not ShootRemote then return false end
    pcall(function() ShootRemote:FireServer({ Shoot = true, Input = 'E', UseSpace = true }) end)
    pcall(function() JumpRemote:FireServer() end)
    task.delay(hold, function()
        pcall(function() ShootRemote:FireServer({ Shoot = false }) end)
    end)
    return true
end

local function stepSteal(myModel, myRoot, now)
    if not (on('BB_AutoSteal') and StealRemote and windowFocused) then return end
    if attr(myModel, 'Basketball') then return end
    if now - auto.lastSteal < opt('BB_StealCooldown', 0.8) then return end
    local range = opt('BB_StealRange', 5)
    local my = myRoot.Position
    for _, p in ipairs(Players:GetPlayers()) do
        local opp, model = isOpponent(p, myModel)
        local root = opp and rootOfModel(model)
        if root and attr(model, 'Basketball') then
            local d = Pure.flatDist(my.X, my.Z, root.Position.X, root.Position.Z)
            local okAction = not on('BB_StealOnlyDribble') or attr(model, 'Action') == 'Dribbling'
            if d <= range and okAction then
                pcall(function() StealRemote:FireServer() end)
                auto.lastSteal = now
                return
            end
        end
    end
end

local function stepBlock(myModel, myRoot, now)
    if not (on('BB_AutoBlock') and windowFocused) then return end
    if attr(myModel, 'Basketball') or now - auto.lastJump < 0.9 then return end
    local range = opt('BB_BlockRange', 7)
    local my = myRoot.Position
    for _, p in ipairs(Players:GetPlayers()) do
        local opp, model = isOpponent(p, myModel)
        local root = opp and rootOfModel(model)
        if root and GAME.ShotActions[attr(model, 'Action')] then
            local id = tostring(attr(model, 'ShotStartTime') or model.Name)
            local d = Pure.flatDist(my.X, my.Z, root.Position.X, root.Position.Z)
            if d <= range and not auto.blockedShots[model] then
                auto.blockedShots[model] = id
                auto.lastJump = now
                task.delay(opt('BB_BlockDelayMs', 0) / 1000, function() jumpPress(0.25) end)
                return
            end
        elseif auto.blockedShots[model] then
            auto.blockedShots[model] = nil
        end
    end
end

local function stepRebound(myModel, myRoot, now)
    local folder = workspace:FindFirstChild('Basketballs')
    if not folder then return end
    local my = myRoot.Position
    local range = opt('BB_ReboundRange', 8)
    for ball, _ in pairs(auto.balls) do
        if ball.Parent ~= folder then auto.balls[ball] = nil end
    end
    for _, ball in ipairs(folder:GetChildren()) do
        if ball:IsA('BasePart') and finiteVec(ball.Position) then
            local rec = auto.balls[ball]
            local pos = ball.Position
            if rec and now > rec.t then
                rec.vy = (pos.Y - rec.y) / (now - rec.t)
            end
            if not rec then
                rec = {}
                auto.balls[ball] = rec
            end
            rec.y, rec.t, rec.pos = pos.Y, now, pos
            if on('BB_AutoRebound') and windowFocused and not attr(myModel, 'Basketball') and now - auto.lastJump > 1.0 then
                local dh = Pure.flatDist(my.X, my.Z, pos.X, pos.Z)
                local above = pos.Y - my.Y
                if dh <= range and rec.vy and rec.vy < -2 and above > 2 and above < opt('BB_ReboundHeight', 10) then
                    auto.lastJump = now
                    jumpPress(0.2)
                    return
                end
            end
        end
    end
end

-- Dribble macro: sends the combo strings the keyboard would send
-- (Dribble:FireServer(combo, sprinting, lastMoveDirection), Keyboard L39-L61),
-- one after another. Which move a combo makes is decided by the server
-- from your own bindings/packages, so type the combos you use in game.
local function currentMoveDir()
    local controls = assist.controls or getControls()
    if type(controls) ~= 'table' then return Vector3.zero end
    local ok, v = pcall(function() return controls:GetMoveVector() end)
    local c, s = cameraBasis()
    if not ok or typeof(v) ~= 'Vector3' or not c then return Vector3.zero end
    local wx, wz = Pure.rawFromMove(c, s, v.X, v.Z)
    local ux, uz = Pure.unit(wx, wz)
    return Vector3.new(ux, 0, uz)
end

local function runDribbleMacro()
    if auto.dribbleBusy or not DribbleRemote then return end
    local combos = Pure.splitCombos(opt('BB_DribbleCombo', ''))
    if #combos == 0 then return end
    auto.dribbleBusy = true
    task.spawn(function()
        for i, combo in ipairs(combos) do
            if not windowFocused then break end
            pcall(function() DribbleRemote:FireServer(combo, on('BB_DribbleSprint'), currentMoveDir()) end)
            if i < #combos then task.wait(opt('BB_DribbleDelay', 0.35)) end
        end
        auto.dribbleBusy = false
    end)
end

-- One-key dribble moves. Combos are the letters the game groups inside its
-- dribble window (Input.Keyboard AddToCombo L39-L66 -> InputService.Dribble
-- (combo, sprinting, moveDirection)). Key sequences from the tutorial clips
-- you sent: Spin "cxz/zxc", Snatchback "shift+xx", Combo "vv",
-- Crossover "shift z/c", Double Stepback "shift+vv+s+e", Halo spin
-- "spin, switch hands, switch hands + tap shoot while holding post".
local HoldGRemote = resolve({ 'ReplicatedStorage', 'Aero', 'AeroRemoteServices', 'InputService', 'HoldG' })
local function awayFromHoopDir(myModel)
    local root, goal = rootOfModel(myModel), goalPos(myModel)
    if not root or not goal then return currentMoveDir() end
    local ux, uz = Pure.unit(root.Position.X - goal.X, root.Position.Z - goal.Z)
    return Vector3.new(ux, 0, uz)
end
local MOVES = {
    { key = 'BB_MoveSpin',       name = 'Spin',            steps = { { 'ZXC', false } } },
    { key = 'BB_MoveSnatch',     name = 'Snatchback',      steps = { { 'XX', true } } },
    { key = 'BB_MoveCombo',      name = 'Combo (VV)',      steps = { { 'VV', false } } },
    { key = 'BB_MoveCrossL',     name = 'Crossover Left',  steps = { { 'Z', true } } },
    { key = 'BB_MoveCrossR',     name = 'Crossover Right', steps = { { 'C', true } } },
    { key = 'BB_MoveSwitch',     name = 'Switch Hands',    steps = { { 'H', false } } },
    { key = 'BB_MoveDStep',      name = 'Double Stepback', steps = { { 'VV', true, 'back' }, { 'shoot' } } },
    { key = 'BB_MoveHalo',       name = 'Halo Spin',       steps = { { 'ZXC', false }, { 'H', false }, { 'H', false, nil, 'post' } } },
}
local function runMove(move, myModel)
    if auto.dribbleBusy or not DribbleRemote then return end
    auto.dribbleBusy = true
    task.spawn(function()
        for i, st in ipairs(move.steps) do
            if not windowFocused then break end
            if st[1] == 'shoot' then
                if ShootRemote then
                    pcall(function() ShootRemote:FireServer({ Shoot = true, Input = 'E' }) end)
                    -- Auto Release times it; without it, let go after a normal hold.
                    if not on('BB_AutoRelease') then
                        task.delay(0.45, function() pcall(function() ShootRemote:FireServer({ Shoot = false }) end) end)
                    end
                end
            else
                local dir = st[3] == 'back' and awayFromHoopDir(myModel) or currentMoveDir()
                if st[4] == 'post' and HoldGRemote then pcall(function() HoldGRemote:FireServer({ HoldingG = true }) end) end
                pcall(function() DribbleRemote:FireServer(st[1], st[2], dir) end)
                if st[4] == 'post' then
                    if ShootRemote then
                        pcall(function() ShootRemote:FireServer({ Shoot = true, Input = 'E' }) end)
                        task.wait(0.06)
                        pcall(function() ShootRemote:FireServer({ Shoot = false }) end)
                    end
                    if HoldGRemote then
                        task.wait(0.15)
                        pcall(function() HoldGRemote:FireServer({ HoldingG = false }) end)
                    end
                end
            end
            if i < #move.steps then task.wait(opt('BB_DribbleDelay', 0.35)) end
        end
        auto.dribbleBusy = false
    end)
end

-- Court boxes, refreshed every few seconds.
local courtCache = { at = -10, boxes = {} }
local function courtBoxes()
    local now = os.clock()
    if now - courtCache.at < 5 then return courtCache.boxes end
    courtCache.at = now
    local boxes = {}
    local assets = workspace:FindFirstChild('Assets')
    local cb = assets and assets:FindFirstChild('CourtBounds')
    if cb then
        for _, part in ipairs(cb:GetChildren()) do
            if part:IsA('BasePart') then
                local r = part.CFrame.RightVector
                local rx, rz = Pure.unit(r.X, r.Z)
                boxes[#boxes + 1] = { cx = part.Position.X, cz = part.Position.Z, rx = rx, rz = rz,
                    hx = part.Size.X / 2, hz = part.Size.Z / 2 }
            end
        end
    end
    courtCache.boxes = boxes
    return boxes
end

auto.lastAutoDribble = 0
local function stepAutoDribble(myModel, myRoot, now)
    if not on('BB_AutoDribble') or auto.dribbleBusy or not DribbleRemote then return end
    local kp = Options and Options.BB_AutoDribbleKey
    if kp and kp.Value and kp.Value ~= 'None' and not keyHeld('BB_AutoDribbleKey') then return end
    if not attr(myModel, 'Basketball') then return end
    local action = attr(myModel, 'Action')
    if action ~= '' and action ~= 'Dribbling' and action ~= 'Moving' and action ~= nil then return end
    if now - auto.lastAutoDribble < math.max(opt('BB_DribbleDelay', 0.35), opt('BB_AutoDribbleGap', 0.7)) then return end
    local my = myRoot.Position
    local best, bestD
    for _, p in ipairs(Players:GetPlayers()) do
        local opp, model = isOpponent(p, myModel)
        local root = opp and rootOfModel(model)
        if root then
            local d = Pure.flatDist(my.X, my.Z, root.Position.X, root.Position.Z)
            if not bestD or d < bestD then best, bestD = root, d end
        end
    end
    if not best then return end
    local dv = best.AssemblyLinearVelocity
    if typeof(dv) ~= 'Vector3' then return end
    local kind, side = Pure.dribbleDecision(my.X, my.Z, best.Position.X, best.Position.Z, dv.X, dv.Z,
        opt('BB_AutoDribbleRange', 9), opt('BB_BiteSpeed', 6), 8, 5)
    if not kind then return end
    local rx, rz = best.Position.X - my.X, best.Position.Z - my.Z
    local ux, uz = Pure.unit(rx, rz)
    local dirX, dirZ, combo, sprint
    if kind == 'cross' then
        -- sideways (away from where they bit) and a bit forward past them
        local px, pz = -uz * side, ux * side
        dirX, dirZ = Pure.unit(px + ux * 0.4, pz + uz * 0.4)
        local leftSide = side < 0
        if on('BB_SwapCross') then leftSide = not leftSide end
        combo, sprint = leftSide and 'Z' or 'C', true
    else
        dirX, dirZ = -ux, -uz
        combo, sprint = (on('BB_AutoDribbleSnatch') and 'XX' or 'VV'), true
    end
    -- never dribble toward out of bounds: test ~7 studs along the move
    local boxes = courtBoxes()
    if not Pure.insideBoxes(my.X + dirX * 7, my.Z + dirZ * 7, boxes) then
        if kind ~= 'cross' then return end
        -- try the other side instead
        local px, pz = uz * side, -ux * side
        dirX, dirZ = Pure.unit(px + ux * 0.4, pz + uz * 0.4)
        if not Pure.insideBoxes(my.X + dirX * 7, my.Z + dirZ * 7, boxes) then return end
        combo = combo == 'Z' and 'C' or 'Z'
    end
    auto.lastAutoDribble = now
    pcall(function() DribbleRemote:FireServer(combo, sprint, Vector3.new(dirX, 0, dirZ)) end)
    diag.lastDribble = string.format('%s %s (%.1f studs)', kind, combo, bestD)
end

local function stepAuto(myModel)
    local myRoot = rootOfModel(myModel)
    if not myRoot then return end
    local now = os.clock()
    stepSteal(myModel, myRoot, now)
    stepBlock(myModel, myRoot, now)
    stepRebound(myModel, myRoot, now)
    stepAutoDribble(myModel, myRoot, now)
    local held = keyHeld('BB_DribbleKey')
    if held and not auto.dribbleKeyWas then runDribbleMacro() end
    auto.dribbleKeyWas = held
    auto.moveWas = auto.moveWas or {}
    for _, mv in ipairs(MOVES) do
        local h = keyHeld(mv.key)
        if h and not auto.moveWas[mv.key] and attr(myModel, 'Basketball') then runMove(mv, myModel) end
        auto.moveWas[mv.key] = h
    end
end

-- ================================================================
--  MAIN LOOP
-- ================================================================

connect(RunService.Heartbeat, function(dt)
    if type(dt) == 'number' and dt > 0 and dt < 0.5 then diag.dt = diag.dt + (dt - diag.dt) * 0.1 end
    local myModel = modelOf(LocalPlayer)
    hookMeter(myModel)
    if not myModel then
        if shot.active then resetShot() end
        assist.active, assist.dir = false, nil
        return
    end
    local ok, err = pcall(stepShot, myModel)
    if not ok then diag.lastError = 'shot: ' .. tostring(err) end
    local okA, errA = pcall(stepAssist, myModel)
    if not okA then diag.lastError = 'assist: ' .. tostring(errA) end
    local okX, errX = pcall(stepAuto, myModel)
    if not okX then diag.lastError = 'auto: ' .. tostring(errX) end
end)

-- More checks per second = release lands closer to the exact moment.
-- setfpscap is an executor function; without it this does nothing.
local function applyFps()
    if type(setfpscap) == 'function' then pcall(setfpscap, on('BB_FpsUnlock') and 240 or 60) end
end

local lastDraw = 0
connect(RunService.RenderStepped, function()
    local now = os.clock()
    if now - lastDraw < 1 / 30 then return end
    lastDraw = now
    local myModel = modelOf(LocalPlayer)
    if myModel then pcall(drawMeter, myModel) elseif meter.gui then meter.gui.Enabled = false end
end)

-- ================================================================
--  DEBUG PANEL
-- ================================================================

local dbg = {}
local function buildDebug()
    if dbg.gui then return end
    local parent
    if type(gethui) == 'function' then
        local ok, h = pcall(gethui)
        if ok then parent = h end
    end
    parent = parent or LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not parent then return end
    local gui = Instance.new('ScreenGui')
    gui.Name = 'YazuBBDebug'
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 1001
    local t = Instance.new('TextLabel')
    t.Position = UDim2.fromOffset(12, 60)
    t.Size = UDim2.fromOffset(460, 230)
    t.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
    t.BackgroundTransparency = 0.2
    t.BorderSizePixel = 0
    t.Font = Enum.Font.Code
    t.TextSize = 13
    t.TextColor3 = Color3.fromRGB(230, 230, 240)
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.TextYAlignment = Enum.TextYAlignment.Top
    t.TextWrapped = true
    t.Parent = gui
    gui.Parent = parent
    dbg.gui, dbg.text = gui, t
end
onCleanup(function() if dbg.gui then pcall(function() dbg.gui:Destroy() end) end dbg = {} end)

local function drawDebug()
    if not on('BB_Debug') then
        if dbg.gui then dbg.gui.Enabled = false end
        return
    end
    buildDebug()
    if not dbg.gui then return end
    dbg.gui.Enabled = true
    local m = modelOf(LocalPlayer)
    local lines = {}
    local function add(...) lines[#lines + 1] = string.format(...) end
    add('character model : %s', m and m:GetFullName() or 'NOT FOUND in workspace.Characters')
    add('shoot remote    : %s   feedback: %s', ShootRemote and 'ok' or 'MISSING', FeedbackRemote and 'ok' or 'MISSING')
    if m then
        add('Action          : %q   ReleasedShot: %s', tostring(attr(m, 'Action')), tostring(attr(m, 'ReleasedShot')))
        add('meterOffset     : %s', tostring(attr(m, 'meterOffset')))
        add('BaseAnimation   : %s', tostring(attr(m, 'BaseAnimation')))
    end
    add('shot active     : %s  progress %.4f  rate %.3f/s', tostring(shot.active), shot.progress or 0, shot.rate or 0)
    local k = shot.key or (m and shotKey(m))
    local st = k and learn[k]
    add('key             : %s', tostring(k))
    add('aim / meter top : %.3f%s / %s   peaked %s', k and aimFor(k) or GAME.DefaultAim, st and '' or ' (default)',
        peakFor(meterInfo.meterType) and string.format('%.3f', peakFor(meterInfo.meterType)) or '-', tostring(shot.peaked))
    add('learned shots   : %d (%d perfect) for this animation', st and st.hist and #st.hist or 0, st and st.perfects or 0)
    add('meter (server)  : type %s  green %s', tostring(meterInfo.meterType), tostring(meterInfo.green))
    add('auto release    : %s   fired %d   last: %s', on('BB_AutoRelease') and 'ON' or 'off', diag.fired, diag.lastFire)
    add('shots seen      : %d   ping %dms', diag.shots, math.floor(oneWayPing() * 2000))
    add('auto dribble    : %s', tostring(diag.lastDribble or 'none'))
    add('extra release   : %s', dupe.hooked and (os.clock() < dupe.untilT and 'dropping (shot in progress)' or 'ready') or 'hook unavailable')
    if lastFeedback then add('last grade      : %s, %s%% contested', tostring(lastFeedback.grade), tostring(lastFeedback.contest)) end
    add('contest scale   : x%.2f', contestScale)
    add('last error      : %s', tostring(diag.lastError or 'none'))
    dbg.text.Text = table.concat(lines, '\n')
end

local lastDbg = 0
connect(RunService.RenderStepped, function()
    local now = os.clock()
    if now - lastDbg < 0.1 then return end
    lastDbg = now
    pcall(drawDebug)
end)

-- ================================================================
--  UI
-- ================================================================

local Shoot = Tab:AddLeftGroupbox('Shooting')
Shoot:AddToggle('BB_AutoRelease', { Text = 'Auto Release', Default = true })
Shoot:AddToggle('BB_SpaceSkip', { Text = 'Let Me Space Make (no auto release after Space)', Default = false })
Shoot:AddToggle('BB_AutoTiming', { Text = 'Per-Animation Learning (optional)', Default = false })
Shoot:AddToggle('BB_PerfectOnly', { Text = 'Train On Perfects Only', Default = true })
Shoot:AddToggle('BB_LearnManual', { Text = 'Learn From My Releases', Default = false })
Shoot:AddToggle('BB_AutoLayup', { Text = 'Auto Release Layups', Default = true })
Shoot:AddToggle('BB_DropDupe', { Text = 'Drop My Extra Release (stops auto-layup jellies)', Default = true })
Shoot:AddToggle('BB_AutoJelly', { Text = 'Auto Release Jellies (double-tap shoot)', Default = false })
Shoot:AddToggle('BB_AnyMeter', { Text = 'Track Unknown Meter Actions', Default = false })
Shoot:AddToggle('BB_AutoMoving', { Text = 'Auto-Adjust Fade/Moving Shots', Default = true })
Shoot:AddToggle('BB_PingComp', { Text = 'Prefire for Ping', Default = true })
Shoot:AddToggle('BB_Smooth', { Text = 'Between-Frame Timing', Default = true })
Shoot:AddToggle('BB_FpsUnlock', { Text = 'Unlock FPS (240) for timing', Default = true })
if Toggles.BB_FpsUnlock and Toggles.BB_FpsUnlock.OnChanged then Toggles.BB_FpsUnlock:OnChanged(applyFps) end
applyFps()
Shoot:AddSlider('BB_ExtraLeadMs', { Text = 'Extra Lead (ms)', Default = 0, Min = -100, Max = 150, Rounding = 0 })
Shoot:AddButton({ Text = 'Show Learned Targets', Func = function()
    local parts = {}
    for k, st in pairs(learn) do
        parts[#parts + 1] = string.format('%s=%.3f (%d perfect)', k, aimFor(k), st.perfects or 0)
    end
    table.sort(parts)
    Library:Notify(#parts > 0 and table.concat(parts, '  ') or 'No targets yet: take a few shots with Auto Timing on', 8)
end })
Shoot:AddButton({ Text = 'Recalibrate (current animation)', Func = function()
    recalibrate(false)
    Library:Notify('Recalibrating this jumpshot animation: back to the default prefire, then it re-learns', 6)
end })
Shoot:AddButton({ Text = 'Recalibrate All', Func = function()
    recalibrate(true)
    Library:Notify('All learned release points cleared')
end })
Shoot:AddDivider()
Shoot:AddToggle('BB_Debug', { Text = 'Debug Panel', Default = false })
Shoot:AddToggle('BB_AutoSaveTrace', { Text = 'Auto-save shot traces', Default = false })
Shoot:AddButton({ Text = 'Save Last Shot Trace', Func = function()
    local path, err = saveTrace(trace.last or trace.current)
    Library:Notify(path and ('Saved workspace/' .. path) or ('Trace: ' .. tostring(err)), 6)
end })
Shoot:AddLabel('Prefires by your ping like a manual player, on every meter type, with one aim measured from your Perfects. No training needed. Use Extra Lead (ms) to nudge: + releases earlier, - later.', true)
if not ShootRemote then Shoot:AddLabel('!! InputService.Shoot remote not found; Auto Release is off', true) end
if not FeedbackRemote then Shoot:AddLabel('!! InterfaceService.ShowFeedback not found; Auto Timing cannot learn', true) end

local Defense = Tab:AddRightGroupbox('Defense')
Defense:AddToggle('BB_GuardAssist', { Text = 'Guard Assist', Default = false })
Defense:AddLabel('Assist Key'):AddKeyPicker('BB_GuardKey', { Default = 'None', Text = 'Guard Assist Key', Mode = 'Hold' })
Defense:AddToggle('BB_AssistOnGameGuard', { Text = 'Also while holding game guard (G)', Default = true })
Defense:AddSlider('BB_AssistStrength', { Text = 'Assist Strength', Default = 0.32, Min = 0.05, Max = 1, Rounding = 3 })
Defense:AddSlider('BB_AssistReactionMs', { Text = 'Reaction Delay (ms)', Default = 130, Min = 0, Max = 500, Rounding = 0 })
Defense:AddSlider('BB_AssistSmooth', { Text = 'Turn Smoothing (s)', Default = 0.1, Min = 0, Max = 0.5, Rounding = 2 })
Defense:AddSlider('BB_AssistDeadzone', { Text = 'Loose Zone (studs)', Default = 1.0, Min = 0, Max = 4, Rounding = 1 })
Defense:AddSlider('BB_AssistIdle', { Text = 'Pull While Standing Still', Default = 0.6, Min = 0, Max = 1, Rounding = 2 })
Defense:AddSlider('BB_GuardDistance', { Text = 'Guard Distance (studs)', Default = GAME.AssistDistance, Min = 1.5, Max = 8, Rounding = 2 })
Defense:AddSlider('BB_AssistRange', { Text = 'Target Range (studs)', Default = 25, Min = 5, Max = 80, Rounding = 0 })

local Info = Tab:AddRightGroupbox('Contest')
Info:AddToggle('BB_ContestMeter', { Text = 'Contest Meter', Default = false })
Info:AddToggle('BB_ContestPredict', { Text = 'Predict Defender Closeout (speed)', Default = true })
Info:AddSlider('BB_ContestLookMs', { Text = 'Closeout Lookahead (ms)', Default = 350, Min = 0, Max = 800, Rounding = 0 })
Info:AddSlider('BB_ContestRange', { Text = 'Estimate Range (studs)', Default = GAME.GuardReactRange, Min = 4, Max = 30, Rounding = 0 })
Info:AddLabel('Top line is an estimate; "last shot" is the game\'s real contest % and grade.', true)

local Ball = Tab:AddLeftGroupbox('Ball / Defense Automation')
Ball:AddLabel('Server decides steals, blocks and rebounds; these only time the button press.', true)
Ball:AddToggle('BB_AutoSteal', { Text = 'Auto Steal', Default = false })
Ball:AddToggle('BB_StealOnlyDribble', { Text = 'Only during their dribble moves', Default = false })
Ball:AddSlider('BB_StealRange', { Text = 'Steal Range (studs, uncalibrated)', Default = 5, Min = 2, Max = 12, Rounding = 1 })
Ball:AddSlider('BB_StealCooldown', { Text = 'Steal Cooldown (s)', Default = 0.8, Min = 0.2, Max = 3, Rounding = 2 })
Ball:AddDivider()
Ball:AddToggle('BB_AutoBlock', { Text = 'Auto Block (jump on nearby shot)', Default = false })
Ball:AddSlider('BB_BlockRange', { Text = 'Block Range (studs)', Default = 7, Min = 2, Max = 15, Rounding = 1 })
Ball:AddSlider('BB_BlockDelayMs', { Text = 'Block Delay (ms)', Default = 0, Min = 0, Max = 500, Rounding = 0 })
Ball:AddDivider()
Ball:AddToggle('BB_AutoRebound', { Text = 'Auto Rebound (jump at falling ball)', Default = false })
Ball:AddSlider('BB_ReboundRange', { Text = 'Rebound Range (studs)', Default = 8, Min = 2, Max = 20, Rounding = 1 })
Ball:AddSlider('BB_ReboundHeight', { Text = 'Max Ball Height Above You', Default = 10, Min = 3, Max = 25, Rounding = 1 })
Ball:AddDivider()
Ball:AddInput('BB_DribbleCombo', { Default = 'Z,X', Text = 'Dribble Macro (combos, comma separated)', Placeholder = 'e.g. Z,ZX,C', Finished = true })
Ball:AddSlider('BB_DribbleDelay', { Text = 'Delay Between Moves (s)', Default = 0.35, Min = 0.05, Max = 1.5, Rounding = 2 })
Ball:AddToggle('BB_DribbleSprint', { Text = 'Send as Sprinting', Default = false })
Ball:AddLabel('Dribble Macro Key'):AddKeyPicker('BB_DribbleKey', { Default = 'None', Text = 'Dribble Macro', Mode = 'Hold' })
Ball:AddDivider()
Ball:AddToggle('BB_AutoDribble', { Text = 'Auto Dribble (cross when they bite)', Default = false })
Ball:AddLabel('Auto Dribble Key (optional)'):AddKeyPicker('BB_AutoDribbleKey', { Default = 'None', Text = 'Auto Dribble (hold)', Mode = 'Hold' })
Ball:AddSlider('BB_BiteSpeed', { Text = 'Bite Speed (studs/s)', Default = 6, Min = 2, Max = 16, Rounding = 1 })
Ball:AddSlider('BB_AutoDribbleRange', { Text = 'Defender Range (studs)', Default = 9, Min = 3, Max = 20, Rounding = 1 })
Ball:AddSlider('BB_AutoDribbleGap', { Text = 'Min Time Between Moves (s)', Default = 0.7, Min = 0.2, Max = 2, Rounding = 2 })
Ball:AddToggle('BB_AutoDribbleSnatch', { Text = 'Use Snatchback (else Stepback) on closeouts', Default = false })
Ball:AddToggle('BB_SwapCross', { Text = 'Swap Crossover Sides', Default = false })
Ball:AddDivider()
Ball:AddLabel('One-key moves (set a key for each):', true)
for _, mv in ipairs(MOVES) do
    Ball:AddLabel(mv.name):AddKeyPicker(mv.key, { Default = 'None', Text = mv.name, Mode = 'Hold' })
end

end -- return function
