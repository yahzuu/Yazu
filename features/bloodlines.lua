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

-- samples: array of { t, x, y, z, vx, vy, vz } in time order (seconds, studs, studs/second).
-- A "snap" is a frame whose position differs from where the previous frame's velocity
-- predicts it should be by more than snapThreshold studs: something other than
-- ordinary physics moved the character (server correction, teleport, direct CFrame write).
function Pure.analyzeTrack(samples, snapThreshold)
    local result = { frames = #samples, maxSpeed = 0, maxStep = 0, snaps = {} }
    for i = 1, #samples do
        local s = samples[i]
        local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
        if Pure.isFinite(speed) and speed > result.maxSpeed then result.maxSpeed = speed end
        if i > 1 then
            local p = samples[i - 1]
            local dt = s.t - p.t
            if dt > 0 and dt < 0.5 then
                local step = math.sqrt((s.x - p.x) ^ 2 + (s.y - p.y) ^ 2 + (s.z - p.z) ^ 2)
                if Pure.isFinite(step) and step > result.maxStep then result.maxStep = step end
                local dx = s.x - (p.x + p.vx * dt)
                local dy = s.y - (p.y + p.vy * dt)
                local dz = s.z - (p.z + p.vz * dt)
                local err = math.sqrt(dx * dx + dy * dy + dz * dz)
                if Pure.isFinite(err) and err > snapThreshold then
                    result.snaps[#result.snaps + 1] = { t = s.t, err = err, dx = dx, dy = dy, dz = dz }
                end
            end
        end
    end
    return result
end

-- Stand position around a target. World space: Roblox, Y up, right-handed. (lx, lz) is the target's planar look
-- direction and its right vector is (-lz, lx). Modes: Behind, Front, Left, Right, Orbit (Orbit uses `angle`, radians).
-- An unknown mode means Behind. A degenerate look vector falls back to the line target -> origin.
function Pure.relativeStand(mode, tx, ty, tz, lx, lz, ox, oz, distance, height, angle)
    if mode == 'Orbit' then
        local a = angle or 0
        return tx + math.cos(a) * distance, ty + height, tz + math.sin(a) * distance
    end
    local len = math.sqrt(lx * lx + lz * lz)
    if not Pure.isFinite(len) or len < 0.01 then
        return Pure.standPosition(tx, ty, tz, ox, oz, distance, height)
    end
    lx, lz = lx / len, lz / len
    local rx, rz = -lz, lx
    local dx, dz
    if mode == 'Front' then dx, dz = lx, lz
    elseif mode == 'Left' then dx, dz = -rx, -rz
    elseif mode == 'Right' then dx, dz = rx, rz
    else dx, dz = -lx, -lz end
    return tx + dx * distance, ty + height, tz + dz * distance
end

-- Hysteresis for the low-health retreat. Returns 'retreat', 'return', 'hold' or 'none'.
function Pure.safetyDecision(retreated, hpPct, enterPct, exitPct)
    if not Pure.isFinite(hpPct) then return 'hold' end
    if exitPct <= enterPct then exitPct = enterPct + 1 end
    if not retreated then
        if hpPct < enterPct then return 'retreat' end
        return 'none'
    end
    if hpPct >= exitPct then return 'return' end
    return 'hold'
end

-- servers: array of { id, playing, maxPlayers }. Lowest population that is not the current server and not full.
function Pure.pickServer(servers, currentId, minPlayers)
    local best
    for _, s in ipairs(servers) do
        local playing, cap = s.playing, s.maxPlayers
        if type(s.id) == 'string' and s.id ~= currentId and Pure.isFinite(playing) and playing >= (minPlayers or 0)
            and (not Pure.isFinite(cap) or playing < cap) then
            if not best or playing < best.playing then best = s end
        end
    end
    return best
end

function Pure.stripNumericSuffix(name)
    local stripped = string.gsub(name, '%d+$', '')
    stripped = string.gsub(stripped, '%s+$', '')
    return stripped
end

-- known: map key -> { name, x, y, z }. Returns an array of { key, name, x, y, z } whose name matches `filter`
-- and whose key is not in `skipKeys`.
function Pure.filterKnown(known, filter, skipKeys)
    local list = {}
    for key, e in pairs(known) do
        if Pure.nameMatches(e.name, filter) and not (skipKeys and skipKeys[key]) then
            list[#list + 1] = { key = key, name = e.name, x = e.x, y = e.y, z = e.z }
        end
    end
    return list
end

-- Digits of an animation asset id, from either 'rbxassetid://123' or 'http://www.roblox.com/asset/?id=123'.
function Pure.animId(id)
    return string.match(tostring(id or ''), '%d+')
end

-- Enum.AnimationPriority.Core (1000) is the engine's default-animation tier and ranks below Idle.
function Pure.priorityRank(value)
    if value == nil then return -1 end
    if value >= 1000 then return -1 end
    return value
end

-- info: { id, priority (EnumItem.Value), looped, length }
-- cfg:  { minRank, minLength, maxLength, include = {[id]=true}, exclude = {[id]=true}, learned = {[id]=true} }
-- Returns isAttack, reason.
function Pure.isAttackAnimation(info, cfg)
    local id = Pure.animId(info.id)
    if id and cfg.exclude and cfg.exclude[id] then return false, 'excluded' end
    if id and cfg.include and cfg.include[id] then return true, 'listed' end
    if id and cfg.learned and cfg.learned[id] then return true, 'learned' end
    if info.looped then return false, 'looped' end
    if not Pure.isFinite(info.length) or info.length < cfg.minLength or info.length > cfg.maxLength then return false, 'length' end
    if Pure.priorityRank(info.priority) < cfg.minRank then return false, 'priority' end
    return true, 'heuristic'
end

-- Counts one attributed hit for an animation id; true once it reaches `threshold`.
function Pure.learnAttack(counts, id, threshold)
    if not id then return false end
    counts[id] = (counts[id] or 0) + 1
    return counts[id] >= threshold
end

-- Is the enemy at (ex, ez) with planar look (lx, lz) pointing toward (tx, tz) within minCos of straight on?
function Pure.isFacing(ex, ez, lx, lz, tx, tz, minCos)
    local dx, dz = tx - ex, tz - ez
    local dl, ll = math.sqrt(dx * dx + dz * dz), math.sqrt(lx * lx + lz * lz)
    if dl < 0.01 or ll < 0.01 then return true end
    return (dx * lx + dz * lz) / (dl * ll) >= minCos
end

-- before/after: { present, transparency, active, y }. A pickup counts as done when the item is gone, hidden,
-- disabled or moved far away.
function Pure.itemChanged(before, after)
    if not after or not after.present then return true, 'gone' end
    if not before then return false end
    if (after.transparency or 0) - (before.transparency or 0) >= 0.5 then return true, 'hidden' end
    if before.active ~= false and after.active == false then return true, 'disabled' end
    if before.y and after.y and math.abs(after.y - before.y) > 20 then return true, 'moved' end
    return false
end

-- 'QuestA, QuestB@Npc Name' -> { { quest = 'QuestA' }, { quest = 'QuestB', npc = 'Npc Name' } }; separators , ; newline.
function Pure.parseQuestList(text)
    local list, seen = {}, {}
    for token in string.gmatch(text or '', '[^,;\n]+') do
        local quest, npc = string.match(token, '^%s*(.-)%s*@%s*(.-)%s*$')
        if not quest then quest = string.match(token, '^%s*(.-)%s*$') end
        if quest and quest ~= '' and not seen[quest] then
            seen[quest] = true
            list[#list + 1] = { quest = quest, npc = (npc and npc ~= '') and npc or nil }
        end
    end
    return list
end

-- 'a, b ; c' -> { a = true, b = true, c = true } (lower case).
function Pure.parseNameSet(text)
    local set = {}
    for token in string.gmatch(text or '', '[^,;\n]+') do
        local name = string.match(token, '^%s*(.-)%s*$')
        if name and name ~= '' then set[string.lower(name)] = true end
    end
    return set
end

-- '123, 456' -> { ['123'] = true, ['456'] = true }
function Pure.parseIdSet(text)
    local set = {}
    for id in string.gmatch(text or '', '%d+') do set[id] = true end
    return set
end

-- candidates: { x, y, z, hp }. priority 'Nearest' or 'Lowest Health'; maxDistance <= 0 or nil means any.
function Pure.pickTarget(candidates, priority, ox, oy, oz, maxDistance)
    local pool = candidates
    if maxDistance and maxDistance > 0 then
        pool = {}
        for _, c in ipairs(candidates) do
            if Pure.isFinite(c.x) and Pure.isFinite(c.y) and Pure.isFinite(c.z) then
                local dx, dy, dz = c.x - ox, c.y - oy, c.z - oz
                if math.sqrt(dx * dx + dy * dy + dz * dz) <= maxDistance then pool[#pool + 1] = c end
            end
        end
    end
    if priority == 'Lowest Health' then
        local best
        for _, c in ipairs(pool) do
            if Pure.isFinite(c.hp) and Pure.isFinite(c.x) and Pure.isFinite(c.y) and Pure.isFinite(c.z)
                and (not best or c.hp < best.hp) then
                best = c
            end
        end
        if best then return best end
    end
    return (Pure.pickNearest(pool, ox, oy, oz))
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

    -- Grip / carry: DataEvent:FireServer("Grip") L7219 and ("Carry") L7234, no arguments. The client precondition at L7218
    -- reads the LOCAL player's Settings (MeleeCooldown false, Gripping "None", Stunned false, ...); where that folder lives is UNVERIFIED.
    GripAction           = 'Grip',
    GripNone             = 'None',          -- Settings.Gripping is "None" when idle (dump 2 tree)
    SettingsGripping     = 'Gripping',      -- StringValue (dump 2 tree)
    SettingsBeingGripped = 'BeingGripped',  -- BoolValue (dump 2 tree)
    SettingsKnocked      = 'Knocked',       -- BoolValue (dump 2 tree)

    -- Quests: DataFunction:InvokeServer("GetQuestProgress", name[, "DontComplete"]) L6827 / L8810 returns (status, extra);
    -- status "Start" leads to InvokeServer("StartQuest", name, 2) at L6831-6832. Other statuses are UNKNOWN (logged at run time).
    QuestProgressAction = 'GetQuestProgress',
    QuestStartAction    = 'StartQuest',
    QuestStartArg       = 2,
    QuestStatusStart    = 'Start',

    -- Loot: DataEvent:FireServer("PickUp", ID.Value, 2) L8202, inside the click handler that also sets Active.Value = false (L8201).
    -- UNVERIFIED which objects carry ID and Active; no dropped item was loaded in either dump.
    PickUpAction    = 'PickUp',
    PickUpArg       = 2,
    LootIdName      = 'ID',
    LootActiveName  = 'Active',

    FruitsFunction = 'NearbyFruitsPlease', -- DataFunction:InvokeServer, L18525; return shape UNKNOWN (logged at run time)
    FallKillAction = 'killme',             -- DataEvent:FireServer("KillMe"), single call site L7467 inside the fall damage branch

    StreamingMinRadius = 128,              -- StreamingEnabled true, min 128, target 1024 (dump session section)

    ServerListBase  = 'https://games.roblox.com/v1/games/',       -- UNVERIFIED, written from memory
    ServerListQuery = '/servers/Public?sortOrder=Asc&limit=100',  -- UNVERIFIED, written from memory
    ReexecUrl       = 'https://raw.githubusercontent.com/yahzuu/Yazu/main/main.lua', -- repo base is main.lua line 6; the file name main.lua is assumed

    -- Positions copied from the dump. Combat and item entries are where the object was when dumped; they only
    -- seed the travel-back list until the real positions are seen. Dialog NPCs come from the mobs section.
    Seeds = {
        items = {
            { name = 'Gloweed', x = -1404.81591796875, y = -192.75, z = -1067.6673583984375 },       -- dump 2 interactables
            { name = 'Seaweed', x = -391.6672668457031, y = -241.01541137695312, z = -892.29736328125 }, -- dump 2 interactables (1 of 4)
        },
        combat = {
            { name = 'Tairock', x = -147.7118377685547, y = -216.09707641601562, z = -1020.145751953125 }, -- dump 2 mobs section
        },
        npcs = {
        { name = 'Chakra Man', x = 468.4013977050781, y = 27.499998092651367, z = -314.6583557128906 },
        { name = 'Chef', x = -66.23486328125, y = -37.24994659423828, z = -257.8305969238281 },
        { name = 'Choji', x = 554.0623779296875, y = -48.500003814697266, z = -297.2560729980469 },
        { name = 'Crabuto', x = 194.83700561523438, y = -277.9159851074219, z = 243.39999389648438 },
        { name = 'Eldest Elder', x = -671.4281616210938, y = -101.30406188964844, z = -669.37158203125 },
        { name = 'Food Merchant', x = 181.0169219970703, y = -29.526845932006836, z = -424.2516174316406 },
        { name = 'Hyuga Boss', x = -674.8930053710938, y = -358.9648132324219, z = -773 },
        { name = 'Hyuga Elder', x = -703.6235961914062, y = 238.587890625, z = -694.7876586914062 },
        { name = 'InnKeeper', x = -607.9999389648438, y = -188.45001220703125, z = -514 },
        { name = 'Ino', x = -320, y = 91.05500030517578, z = -475.4949951171875 },
        { name = 'Konan, Sorythia\'s Protector', x = 7.533304691314697, y = 4.22499942779541, z = -394.9700012207031 },
        { name = 'Lady Chef', x = -323.4000244140625, y = 107.69999694824219, z = 203.02001953125 },
        { name = 'Lavaroldy', x = -143.3772430419922, y = -115.58303833007812, z = 209.61236572265625 },
        { name = 'Medic', x = -700.9999389648438, y = 238.39598083496094, z = -762.4999389648438 },
        { name = 'Merchant', x = -658.0000610351562, y = -188.4499969482422, z = -423 },
        { name = 'Sorythia Sensei', x = -1.511680006980896, y = 2.0250039100646973, z = -393.9010314941406 },
        { name = 'The Banker', x = -695.07763671875, y = -189.00001525878906, z = -484.9206848144531 },
        { name = 'The Barbarian', x = -598.6497802734375, y = -127.486328125, z = -93.17329406738281 },
        { name = 'The Cunning Collector', x = -630.5000610351562, y = -173.79876708984375, z = -427.5754089355469 },
        { name = 'The Dazzling Dyer', x = 103.510009765625, y = -45.14500427246094, z = -761.5999755859375 },
        { name = 'The Deprived Damsel', x = -893.7832641601562, y = -40.97800827026367, z = 381.4665832519531 },
        { name = 'The Judicious Jailor', x = 126.53296661376953, y = -216.00001525878906, z = 298.4554748535156 },
        { name = 'The Mysterious Man', x = -756.4995727539062, y = 189.34481811523438, z = -786.0000610351562 },
        { name = 'The Poorly Traveller', x = -158.01727294921875, y = 85.80760192871094, z = -807.913330078125 },
        { name = 'The Scarlet Slowcoach', x = 217.11813354492188, y = -45.094017028808594, z = -809.723876953125 },
        { name = 'The Slithering Sannin', x = 87, y = -245.95001220703125, z = 352.71844482421875 },
        { name = 'The Spinebreaker', x = -702.9596557617188, y = -245.9752197265625, z = -214.2881622314453 },
        { name = 'The Stranded Sharkman', x = -93.31368255615234, y = -38.79499053955078, z = -234.1453094482422 },
        { name = 'The Stunning Stylist', x = 103.48999786376953, y = -45.14500427246094, z = -902.4000244140625 },
        { name = 'The Summoner', x = -549.393310546875, y = -223.65000915527344, z = -689.5000610351562 },
        { name = 'The Tempest Tutor', x = -633.9370727539062, y = -120.47472381591797, z = -1154.9969482421875 },
        { name = 'The True Sharkman', x = -1178.31689453125, y = -300.9523010253906, z = 634.732666015625 },
        { name = 'The Useless Kunoichi', x = -580.7518920898438, y = -215.9739990234375, z = 336.0435791015625 },
        { name = 'Undead Cook', x = 35.75, y = -41.80000686645508, z = -249.75 },
        },
    },
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
--  NAMECALL HOOK (BanMe and fall damage gates, passive Block spy)
--  State lives in getgenv so a re-run reuses the one installed hook.
-- ================================================================

local genv = (type(getgenv) == 'function' and getgenv()) or _G
local hook = genv.__YazuBloodlinesHook
if not hook then
    hook = { installed = false, blockBan = false, blockFall = false, blockedBans = 0, remote = nil }
    genv.__YazuBloodlinesHook = hook
end
hook.remote = DataEvent
hook.func = DataFunction
hook.spy = nil                         -- set by the parry log; called as spy(action, ...) for the game's own InvokeServer calls
hook.reasons = hook.reasons or {}      -- BanMe reason string -> times dropped (at most 20 distinct reasons kept)
hook.reasonKinds = hook.reasonKinds or 0

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
                    local reason = select(2, ...)
                    local key = type(reason) == 'string' and reason or '(no reason)'
                    if hook.reasons[key] == nil and hook.reasonKinds < 20 then
                        hook.reasons[key] = 0
                        hook.reasonKinds = hook.reasonKinds + 1
                    end
                    if hook.reasons[key] then hook.reasons[key] = hook.reasons[key] + 1 end
                    return nil
                end
                if hook.blockFall and (lowered == BUILD.FallDamageAction or lowered == BUILD.FallKillAction) then
                    return nil
                end
            end
        elseif hook.spy and self == hook.func and (method == 'InvokeServer' or method == 'invokeServer') then
            local action = ...
            if type(action) == 'string' and not (type(checkcaller) == 'function' and checkcaller()) then
                pcall(hook.spy, ...)
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
    hook.blockBan, hook.blockFall, hook.spy = false, false, nil
end)

-- ================================================================
--  CHARACTER, WORLD AND MOVEMENT HELPERS
-- ================================================================

local STREAM_NEAR = BUILD.StreamingMinRadius - 28   -- inside this distance the client already has the area loaded
local KNOWN_CAP = 400
local MOVER_TIMEOUT = 10

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

-- Shared runtime. mover: which feature currently owns character movement (one at a time).
-- known: positions remembered while an object was loaded, so features can travel back to it after
-- StreamingEnabled unloads it. safety: the low-health retreat; while active nothing else may move the character.
local rt = {
    mover = nil, moverAt = 0,
    known = { combat = {}, items = {} },   -- key -> { name, x, y, z }
    knownCount = 0,
    safety = { active = false },
    anchor = nil,                          -- Vector3 saved by "Set Farm Anchor Here"
    fruits = {},
}

local parry = {
    blocking = false, holdUntil = 0,
    watched = {}, log = {},
    learned = {}, counts = {},             -- animation id -> true / attributed hit count
    recent = {},                           -- enemy animations seen in the last second or so
}

function rt.streaming()
    local ok, value = pcall(function() return workspace.StreamingEnabled end)
    return ok and value == true
end

-- Yields. Loads the area around `pos` so the character does not fall through unloaded ground.
function rt.streamAround(pos, timeout)
    if not rt.streaming() then return true end
    local ok = pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, timeout or 3) end)
    return ok
end

function rt.tryMove(owner)
    if rt.safety.active and owner ~= 'safety' and owner ~= 'manual' then return false end
    local now = os.clock()
    if rt.mover == nil or rt.mover == owner or now - rt.moverAt > MOVER_TIMEOUT then
        rt.mover, rt.moverAt = owner, now
        return true
    end
    return false
end

function rt.releaseMove(owner)
    if rt.mover == owner then rt.mover = nil end
end

local function placeRoot(owner, cf)
    if rt.safety.active and owner ~= 'safety' and owner ~= 'manual' then return false end
    local _, _, root = getCharacter()
    if not root or not cf then return false end
    local p = cf.Position
    if not (Pure.isFinite(p.X) and Pure.isFinite(p.Y) and Pure.isFinite(p.Z)) then return false end
    root.CFrame = cf
    zeroVelocity(root)
    return true
end

-- Yields when the destination is far enough that the client may not have it loaded.
local function travelTo(owner, cf)
    local _, _, root = getCharacter()
    if not root or not cf then return false end
    local p = cf.Position
    if rt.streaming() and (p - root.Position).Magnitude > STREAM_NEAR then
        rt.streamAround(p, 3)
    end
    return placeRoot(owner, cf)
end

local function teleportTo(cf)
    if not cf then return false end
    return travelTo('manual', cf + Vector3.new(0, 3, 0))
end

local function remember(bucket, key, name, x, y, z)
    local map = rt.known[bucket]
    local e = map[key]
    if e then
        e.x, e.y, e.z = x, y, z
        return
    end
    if rt.knownCount >= KNOWN_CAP then return end
    rt.knownCount = rt.knownCount + 1
    map[key] = { name = name, x = x, y = y, z = z }
end

for _, seed in ipairs(BUILD.Seeds.items) do
    rt.known.items['seed:' .. seed.name] = { name = seed.name, x = seed.x, y = seed.y, z = seed.z }
end
for _, seed in ipairs(BUILD.Seeds.combat) do
    rt.known.combat['seed:' .. seed.name] = { name = seed.name, x = seed.x, y = seed.y, z = seed.z }
end

local function cellKey(name, x, z)
    return name .. '@' .. math.floor(x / 4) .. ',' .. math.floor(z / 4)
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

local function flagOf(model, name)
    local settings = model:FindFirstChild(BUILD.SettingsFolder)
    local value = settings and settings:FindFirstChild(name)
    if value and value:IsA('BoolValue') then return value.Value end
    return nil
end

-- Living Combat NPCs matching `filter`. Also remembers each one's spawn position.
local function collectTargets(filter)
    local list = {}
    eachNpc(function(model, kind)
        if kind ~= BUILD.NPCCombat or not Pure.nameMatches(model.Name, filter) then return end
        local hum  = model:FindFirstChildOfClass('Humanoid')
        local root = model:FindFirstChild('HumanoidRootPart')
        if not hum or not root or hum.Health <= 0 then return end
        local p = root.Position
        local spawn = model:GetAttribute('SpawnCF')
        local sp = (typeof(spawn) == 'CFrame') and spawn.Position or p
        local base = Pure.stripNumericSuffix(model.Name)
        remember('combat', cellKey(base, sp.X, sp.Z), base, sp.X, sp.Y, sp.Z)
        list[#list + 1] = { model = model, hum = hum, root = root, x = p.X, y = p.Y, z = p.Z, hp = hum.Health, name = model.Name, kind = 'npc' }
    end)
    return list
end

local friendCache = {}   -- UserId -> { value, at }; refreshed after a minute
local function isFriend(player)
    local uid = player.UserId
    if not uid then return false end
    local now = os.clock()
    local cached = friendCache[uid]
    if not cached or now - cached.at > 60 then
        local ok, result = pcall(function() return LocalPlayer:IsFriendsWith(uid) end)
        cached = { value = ok and result == true, at = now }
        friendCache[uid] = cached
    end
    return cached.value
end

-- Living other players, minus the ignore list (and friends when asked).
local function collectPlayers()
    local ignore = Pure.parseNameSet(Options.BL_PlayerIgnore.Value)
    local skipFriends = Toggles.BL_PlayerSkipFriends.Value
    local list = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not ignore[string.lower(player.Name)] then
            local char = player.Character
            local hum  = char and char:FindFirstChildOfClass('Humanoid')
            local root = char and char:FindFirstChild('HumanoidRootPart')
            if hum and root and hum.Health > 0 and not (skipFriends and isFriend(player)) then
                local p = root.Position
                list[#list + 1] = { model = char, hum = hum, root = root, x = p.X, y = p.Y, z = p.Z, hp = hum.Health, name = player.Name, kind = 'player', player = player }
            end
        end
    end
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
local TargetGrp = Tab:AddLeftGroupbox('Auto Target & Grip')
local ParryGrp  = Tab:AddLeftGroupbox('Auto Parry')
local EspGrp    = Tab:AddRightGroupbox('ESP')
local UtilGrp   = Tab:AddRightGroupbox('Harvest & Utility')
local TpGrp     = Tab:AddRightGroupbox('Teleport Cheats')
local AutoGrp   = Tab:AddRightGroupbox('Quests & Progression')
local ServerGrp = Tab:AddRightGroupbox('Server')
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
    Text = 'No Fall Damage', Default = true,
    Tooltip = 'Drops the client-reported TakeDamage and KillMe calls from the fall branch (L7462, L7467).',
    Callback = function(state)
        if state and not installHook() then
            if Toggles.BL_NoFall then Toggles.BL_NoFall:SetValue(false) end
            return
        end
        hook.blockFall = state
    end,
})
local function banReasonsText()
    local keys = {}
    for key in pairs(hook.reasons) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. ' x' .. tostring(hook.reasons[key]) end
    return #parts > 0 and table.concat(parts, ', ') or '(none)'
end

SafeGrp:AddButton({ Text = 'Print Blocked BanMe Count', Func = function()
    Library:Notify('Blocked BanMe reports: ' .. tostring(hook.blockedBans) .. ' | ' .. banReasonsText(), 10)
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
    if Toggles.BL_BlockBan.Value or Toggles.BL_NoFall.Value then
        if installHook() then
            hook.blockBan = Toggles.BL_BlockBan.Value
            hook.blockFall = Toggles.BL_NoFall.Value
        end
    end
end)

-- ================================================================
--  AUTO SAFETY
--  Below the retreat HP the character is moved to a platform far from the fight; once HP is back at the
--  return threshold it is moved back to where it was. While retreated, no other feature may move the
--  character (rt.tryMove / placeRoot refuse). The platform is a local part, invisible to other players.
--  UNVERIFIED in game: whether health regenerates on its own at the safe spot, and whether the server
--  accepts the position jump (BanMe reports are dropped by the hook while Block BanMe Reports is on).
-- ================================================================

SafeGrp:AddToggle('BL_AutoSafety', { Text = 'Auto Safety (retreat on low HP)', Default = false,
    Tooltip = 'Teleports to a far platform below the retreat HP and back once healed. Pauses every other mover meanwhile.' })
SafeGrp:AddSlider('BL_SafeEnterHP', { Text = 'Retreat Below HP %', Default = 35, Min = 5, Max = 90, Rounding = 0 })
SafeGrp:AddSlider('BL_SafeExitHP', { Text = 'Return At HP %', Default = 85, Min = 20, Max = 100, Rounding = 0 })
SafeGrp:AddDropdown('BL_SafeMode', { Text = 'Safe Spot', Default = 'Sky above you', Values = { 'Sky above you', 'Far away', 'Saved spot' } })
SafeGrp:AddSlider('BL_SafeDistance', { Text = 'Safe Spot Distance (studs)', Default = 3000, Min = 500, Max = 20000, Rounding = 0 })
SafeGrp:AddSlider('BL_SafeMaxAway', { Text = 'Max Time Away (s, 0 = until healed)', Default = 0, Min = 0, Max = 600, Rounding = 0 })

do
    local safety = rt.safety
    local savedSpot

    local function spotFor(origin)
        local mode = Options.BL_SafeMode.Value
        local distance = Options.BL_SafeDistance.Value
        if mode == 'Saved spot' and savedSpot then return savedSpot end
        if mode == 'Far away' then return Vector3.new(origin.X + distance, origin.Y + 200, origin.Z) end
        return Vector3.new(origin.X, origin.Y + distance, origin.Z)
    end

    local function makePlatform(pos)
        local part = Instance.new('Part')
        part.Name = 'YazuSafe'
        part.Anchored = true
        part.CanCollide = true
        part.Size = Vector3.new(80, 2, 80)
        part.Transparency = 0.6
        part.CFrame = CFrame.new(pos - Vector3.new(0, 1.5, 0))
        part.Parent = workspace
        return part
    end

    local function clearPlatform()
        if safety.platform then safety.platform:Destroy() end
        safety.platform = nil
    end

    local function reset()
        clearPlatform()
        safety.active, safety.returning, safety.returnCF, safety.spot, safety.manual = false, false, nil, nil, false
    end

    local function retreat()
        local _, _, root = getCharacter()
        if not root or safety.active then return end
        local spot = spotFor(root.Position)
        safety.returnCF = root.CFrame
        safety.spot = spot
        safety.since = os.clock()
        safety.active = true
        safety.platform = makePlatform(spot)
        placeRoot('safety', CFrame.new(spot + Vector3.new(0, 3, 0)))
        Library:Notify('Auto Safety: retreated')
    end

    local function comeBack()
        if not safety.active or safety.returning then return end
        safety.returning = true
        local cf = safety.returnCF
        if cf then travelTo('safety', cf) end
        reset()
        Library:Notify('Auto Safety: back at the saved position')
    end

    connect(RunService.Heartbeat, function()
        if not Toggles.BL_AutoSafety.Value and not safety.active then return end
        local _, hum, root = getCharacter()
        if not hum then return end
        if hum.MaxHealth <= 0 then return end
        local pct = hum.Health / hum.MaxHealth * 100
        if not Toggles.BL_AutoSafety.Value then
            if safety.active and not safety.returning and not safety.manual then task.spawn(comeBack) end
            return
        end
        if safety.forced and pct >= Options.BL_SafeExitHP.Value then safety.forced = false end
        local verdict = Pure.safetyDecision(safety.active, pct, Options.BL_SafeEnterHP.Value, Options.BL_SafeExitHP.Value)
        if verdict == 'retreat' then
            if not safety.forced then retreat() end   -- after a timed-out stay, do not bounce straight back until healed
        elseif verdict == 'return' then
            task.spawn(comeBack)
        elseif safety.active and not safety.returning then
            local maxAway = Options.BL_SafeMaxAway.Value
            if maxAway > 0 and os.clock() - safety.since >= maxAway then
                safety.forced = true
                task.spawn(comeBack)
            elseif safety.spot and (root.Position - safety.spot).Magnitude > 40 then
                placeRoot('safety', CFrame.new(safety.spot + Vector3.new(0, 3, 0)))
            end
        end
    end)

    -- A new character has no meaningful return position.
    connect(LocalPlayer.CharacterAdded, function()
        safety.forced = false
        if safety.active then reset() end
    end)

    SafeGrp:AddButton({ Text = 'Save Safe Spot Here', Func = function()
        local _, _, root = getCharacter()
        if not root then Library:Notify('No living character') return end
        savedSpot = root.Position
        Library:Notify('Safe spot saved (used when Safe Spot is "Saved spot")')
    end })
    SafeGrp:AddButton({ Text = 'Retreat Now', Func = function()
        retreat()
        if safety.active then safety.manual = true end
    end })
    SafeGrp:AddButton({ Text = 'Return Now', Func = function() task.spawn(comeBack) end })

    onCleanup(function()
        if safety.active and safety.returnCF then placeRoot('safety', safety.returnCF) end
        reset()
    end)
end

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
--  COMBAT: Auto Attack, Auto Farm (Combat NPCs), Auto Target (players), Auto Grip
--  Melee call UNVERIFIED in game; timings uncalibrated. One feature moves the character at a time
--  (rt.tryMove); a retreat from Auto Safety pauses all of them without turning them off.
-- ================================================================

FarmGrp:AddLabel('Targets: Workspace models whose NPC value is Combat.')
FarmGrp:AddInput('BL_TargetFilter', { Default = '', Text = 'Target name contains', Placeholder = 'empty = any Combat NPC' })
FarmGrp:AddSlider('BL_AttackInterval', { Text = 'Attack / Reposition Interval (s) - uncalibrated', Default = 0.4, Min = 0.1, Max = 2, Rounding = 2 })
FarmGrp:AddSlider('BL_StandDistance', { Text = 'Stand Distance (studs) - uncalibrated', Default = 5, Min = 2, Max = 15, Rounding = 1 })
FarmGrp:AddSlider('BL_StandHeight', { Text = 'Stand Height Offset', Default = 0, Min = -5, Max = 10, Rounding = 1 })
FarmGrp:AddDropdown('BL_StandMode', { Text = 'Stand Position', Default = 'Behind', Values = { 'Behind', 'Front', 'Left', 'Right', 'Orbit' },
    Tooltip = 'Relative to the way the target faces. Behind is the way past a held block, if the block is directional (UNVERIFIED).' })
FarmGrp:AddSlider('BL_OrbitSpeed', { Text = 'Orbit Speed (deg/s)', Default = 180, Min = 30, Max = 720, Rounding = 0 })
FarmGrp:AddDropdown('BL_TargetPriority', { Text = 'Target Priority', Default = 'Nearest', Values = { 'Nearest', 'Lowest Health' } })
FarmGrp:AddSlider('BL_MaxTargetDistance', { Text = 'Max Target Distance (0 = any)', Default = 0, Min = 0, Max = 3000, Rounding = 0 })

FarmGrp:AddToggle('BL_AutoAttack', { Text = 'Auto Attack (no movement)', Default = false })
FarmGrp:AddToggle('BL_AutoFarm', { Text = 'Auto Farm (Combat NPCs)', Default = false,
    Tooltip = 'Moves next to the target, faces it, swings. Travels back to remembered spawns or the farm anchor when none is loaded. Untested in game.' })
FarmGrp:AddButton({ Text = 'Set Farm Anchor Here', Func = function()
    local _, _, root = getCharacter()
    if not root then Library:Notify('No living character') return end
    rt.anchor = root.Position
    Library:Notify('Farm anchor saved')
end })
FarmGrp:AddButton({ Text = 'Clear Farm Anchor', Func = function() rt.anchor = nil end })

TargetGrp:AddToggle('BL_AutoTarget', { Text = 'Auto Target Player', Default = false,
    Tooltip = 'Same engine as Auto Farm, but the targets are other players. Turns Auto Farm off. Untested in game.' })
TargetGrp:AddInput('BL_PlayerIgnore', { Default = '', Text = 'Ignore player names', Placeholder = 'name, name' })
TargetGrp:AddToggle('BL_PlayerSkipFriends', { Text = 'Skip Friends', Default = true })
TargetGrp:AddToggle('BL_AutoGrip', { Text = 'Auto Grip (knocked targets)', Default = false,
    Tooltip = 'Moves next to a knocked target and fires Grip. NPCs: Settings.Knocked. Players: unknown flag, see the HP setting.' })
TargetGrp:AddToggle('BL_GripNpcs', { Text = 'Grip Combat NPCs', Default = true })
TargetGrp:AddToggle('BL_GripPlayers', { Text = 'Grip Players', Default = true })
TargetGrp:AddSlider('BL_GripRange', { Text = 'Grip Search Range (studs)', Default = 80, Min = 10, Max = 500, Rounding = 0 })
TargetGrp:AddSlider('BL_GripDistance', { Text = 'Grip Stand Distance (studs) - uncalibrated', Default = 4, Min = 1, Max = 10, Rounding = 1 })
TargetGrp:AddSlider('BL_GripPlayerHP', { Text = 'Player Counts As Knocked Below HP % - uncalibrated', Default = 15, Min = 1, Max = 50, Rounding = 0 })

do
    local combatRun = { npc = 0, player = 0 }
    local attackRun, gripRun = 0, 0

    local function swingAllowed()
        return os.clock() >= parry.holdUntil
    end

    local function isKnocked(entry)
        return flagOf(entry.model, BUILD.SettingsKnocked) == true
    end

    local function notifyOnce(state, message)
        if state.warned[message] then return end
        state.warned[message] = true
        Library:Notify(message)
    end

    -- Nothing living is loaded: go back to a remembered spawn, else to the farm anchor.
    local function fallbackTravel(state, owner)
        local _, _, root = getCharacter()
        local origin = root.Position
        local now = os.clock()
        local skip = {}
        for key, at in pairs(state.visited) do
            if now - at < 25 then skip[key] = true end
        end
        local pick = Pure.pickNearest(Pure.filterKnown(rt.known.combat, Options.BL_TargetFilter.Value, skip), origin.X, origin.Y, origin.Z)
        if pick then
            state.visited[pick.key] = now
            if (Vector3.new(pick.x, pick.y, pick.z) - origin).Magnitude > 20 then
                notifyOnce(state, 'Auto Farm: no Combat NPC loaded, going to remembered spawn: ' .. pick.name)
                travelTo(owner, CFrame.new(Vector3.new(pick.x, pick.y + 3, pick.z)))
                return 1.5
            end
            return 0.3
        end
        if rt.anchor and (rt.anchor - origin).Magnitude > 40 then
            notifyOnce(state, 'Auto Farm: nothing loaded, returning to the farm anchor')
            travelTo(owner, CFrame.new(rt.anchor))
            return 1.5
        end
        notifyOnce(state, 'Auto Farm: no living Combat NPC is loaded or remembered; walk to a mob area once, or set a farm anchor')
        return 1
    end

    local function combatTick(kind, state, owner)
        local char, hum, root = getCharacter()
        if not char then return 0.5 end
        local origin = root.Position
        local now = os.clock()
        local interval = Options.BL_AttackInterval.Value

        local target = state.target
        if target and (not target.model.Parent or target.hum.Health <= 0 or isKnocked(target)) then target = nil end
        if target and Options.BL_TargetPriority.Value == 'Lowest Health' and now - state.pickedAt > 1 then target = nil end
        if target and kind == 'npc' and not Pure.nameMatches(target.name, Options.BL_TargetFilter.Value) then target = nil end
        if target then
            local maxDistance = Options.BL_MaxTargetDistance.Value
            if maxDistance > 0 and (target.root.Position - origin).Magnitude > maxDistance then target = nil end
        end
        if not target then
            local list = (kind == 'npc') and collectTargets(Options.BL_TargetFilter.Value) or collectPlayers()
            local usable = {}
            for _, entry in ipairs(list) do
                if not isKnocked(entry) then usable[#usable + 1] = entry end
            end
            target = Pure.pickTarget(usable, Options.BL_TargetPriority.Value, origin.X, origin.Y, origin.Z, Options.BL_MaxTargetDistance.Value)
            state.pickedAt = now
        end
        state.target = target
        if not target then
            if kind == 'npc' then return fallbackTravel(state, owner) end
            notifyOnce(state, 'Auto Target: no eligible player loaded')
            return interval
        end

        state.orbit = state.orbit + math.rad(Options.BL_OrbitSpeed.Value) * interval
        local tp = target.root.Position
        local look = target.root.CFrame.LookVector
        local sx, sy, sz = Pure.relativeStand(Options.BL_StandMode.Value, tp.X, tp.Y, tp.Z, look.X, look.Z, origin.X, origin.Z,
            Options.BL_StandDistance.Value, Options.BL_StandHeight.Value, state.orbit)
        local dest = Vector3.new(sx, sy, sz)
        if not travelTo(owner, CFrame.new(dest, Vector3.new(tp.X, dest.Y, tp.Z))) then return interval end
        if swingAllowed() then sendMelee() end
        return interval
    end

    local function startCombat(kind, toggle)
        combatRun[kind] = combatRun[kind] + 1
        local mine = combatRun[kind]
        if not toggle.Value then return end
        if not DataEvent then
            Library:Notify('Combat unavailable: DataEvent missing')
            toggle:SetValue(false)
            return
        end
        local owner = 'combat-' .. kind
        local state = { orbit = 0, pickedAt = 0, warned = {}, visited = {} }
        task.spawn(function()
            while combatRun[kind] == mine and toggle.Value do
                local wait = 0.2
                if rt.tryMove(owner) then
                    local ok, result = pcall(combatTick, kind, state, owner)
                    rt.releaseMove(owner)
                    if ok then
                        wait = result or Options.BL_AttackInterval.Value
                    else
                        wait = 1
                        notifyOnce(state, 'Combat error: ' .. tostring(result))
                    end
                end
                task.wait(wait)
            end
            rt.releaseMove(owner)
        end)
    end

    Toggles.BL_AutoFarm:OnChanged(function()
        if Toggles.BL_AutoFarm.Value and Toggles.BL_AutoTarget.Value then Toggles.BL_AutoTarget:SetValue(false) end
        startCombat('npc', Toggles.BL_AutoFarm)
    end)
    Toggles.BL_AutoTarget:OnChanged(function()
        if Toggles.BL_AutoTarget.Value and Toggles.BL_AutoFarm.Value then Toggles.BL_AutoFarm:SetValue(false) end
        startCombat('player', Toggles.BL_AutoTarget)
    end)

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
                if getCharacter() and swingAllowed() then sendMelee() end
                task.wait(Options.BL_AttackInterval.Value)
            end
        end)
    end)

    -- ---------------- Auto Grip ----------------
    -- Preconditions are read from the local player's Settings when that folder can be found (candidates below);
    -- UNVERIFIED where it lives. Success is read from the target's BeingGripped flag or my own Gripping value.
    local function mySettings()
        local char = LocalPlayer.Character
        local candidates = { char and char:FindFirstChild(BUILD.SettingsFolder), LocalPlayer:FindFirstChild(BUILD.SettingsFolder) }
        for _, folder in pairs(candidates) do
            if folder then return folder end
        end
        return nil
    end

    local function myGripping()
        local folder = mySettings()
        local value = folder and folder:FindFirstChild(BUILD.SettingsGripping)
        if value and value:IsA('StringValue') then return value.Value end
        return nil
    end

    local function gripCandidates(origin)
        local range = Options.BL_GripRange.Value
        local list = {}
        local function consider(entry, knocked)
            local dx, dy, dz = entry.x - origin.X, entry.y - origin.Y, entry.z - origin.Z
            if knocked and math.sqrt(dx * dx + dy * dy + dz * dz) <= range and flagOf(entry.model, BUILD.SettingsBeingGripped) ~= true then
                list[#list + 1] = entry
            end
        end
        if Toggles.BL_GripNpcs.Value then
            for _, entry in ipairs(collectTargets('')) do consider(entry, isKnocked(entry)) end
        end
        if Toggles.BL_GripPlayers.Value then
            local hpLimit = Options.BL_GripPlayerHP.Value
            for _, entry in ipairs(collectPlayers()) do
                local flag = flagOf(entry.model, BUILD.SettingsKnocked)
                local knocked = flag
                if flag == nil then knocked = entry.hum.MaxHealth > 0 and entry.hum.Health / entry.hum.MaxHealth * 100 <= hpLimit end
                consider(entry, knocked)
            end
        end
        return list
    end

    local gripped = setmetatable({}, { __mode = 'k' })

    local function gripOnce()
        local _, _, root = getCharacter()
        if not root then return false end
        local origin = root.Position
        local now = os.clock()
        local fresh = {}
        for _, entry in ipairs(gripCandidates(origin)) do
            if not (gripped[entry.model] and now - gripped[entry.model] < 8) then fresh[#fresh + 1] = entry end
        end
        local target = Pure.pickNearest(fresh, origin.X, origin.Y, origin.Z)
        if not target then return false end
        if not rt.tryMove('grip') then return false end
        local acted = false
        local mine = myGripping()
        if mine ~= nil and mine ~= BUILD.GripNone then
            rt.releaseMove('grip')
            return false
        end
        local tp = target.root.Position
        local sx, sy, sz = Pure.standPosition(tp.X, tp.Y, tp.Z, origin.X, origin.Z, Options.BL_GripDistance.Value, 0)
        if travelTo('grip', CFrame.new(Vector3.new(sx, sy, sz), Vector3.new(tp.X, sy, tp.Z))) then
            acted = true
            for _ = 1, 3 do
                if not (target.model.Parent and getCharacter()) then break end
                DataEvent:FireServer(BUILD.GripAction)
                task.wait(0.35)
                local mineNow = myGripping()
                if flagOf(target.model, BUILD.SettingsBeingGripped) == true or (mineNow ~= nil and mineNow ~= BUILD.GripNone) then
                    break
                end
            end
            gripped[target.model] = os.clock()
        end
        rt.releaseMove('grip')
        return acted
    end

    Toggles.BL_AutoGrip:OnChanged(function()
        gripRun = gripRun + 1
        local mine = gripRun
        if not Toggles.BL_AutoGrip.Value then return end
        if not DataEvent then
            Library:Notify('Auto Grip unavailable: DataEvent missing')
            Toggles.BL_AutoGrip:SetValue(false)
            return
        end
        task.spawn(function()
            local warned = false
            while gripRun == mine and Toggles.BL_AutoGrip.Value do
                local wait = 0.5
                if getCharacter() and not rt.safety.active then
                    local ok, acted = pcall(gripOnce)
                    if not ok and not warned then
                        warned = true
                        Library:Notify('Auto Grip error: ' .. tostring(acted))
                    end
                    if ok and acted then wait = 0.2 end
                end
                task.wait(wait)
            end
        end)
    end)

    onCleanup(function()
        combatRun.npc, combatRun.player = combatRun.npc + 1, combatRun.player + 1
        attackRun, gripRun = attackRun + 1, gripRun + 1
    end)
end

-- ================================================================
--  AUTO PARRY
--  Evidence (BL_ParryLog_1795480783.txt): during enemy attacks Settings.MeleeCooldown and Settings.CurrentSkill
--  never changed, only animations played. The trigger is therefore the enemy's AnimationTrack: a non-looped
--  track at or above the chosen priority and within a length window, from an enemy in range that is facing me.
--  UNVERIFIED: that this game's attack animations use such a priority and length (the log now records priority,
--  length and the animation that preceded each hit I take, and the game's own Block calls, so it can be tuned).
--  "Learn" adds an animation id to the trigger list after it was the latest enemy animation before two of my hits.
-- ================================================================

ParryGrp:AddLabel('Trigger: enemy attack animation (see tooltip). Combat NPCs; players optional.')
ParryGrp:AddToggle('BL_AutoParry', { Text = 'Auto Parry', Default = false,
    Tooltip = 'Calls Block when a nearby enemy starts an attack animation, holds, then EndBlock. Pauses your own swings while held. Untested in game.' })
ParryGrp:AddToggle('BL_ParryOnAnim', { Text = 'Trigger: enemy attack animation', Default = true })
ParryGrp:AddDropdown('BL_ParryMinPriority', { Text = 'Min Animation Priority', Default = 'Action', Values = { 'Idle', 'Movement', 'Action', 'Action2', 'Action3', 'Action4' },
    Tooltip = 'Animations below this priority, looped ones, and the engine default (Core) ones are not treated as attacks.' })
ParryGrp:AddSlider('BL_ParryMinLen', { Text = 'Min Animation Length (s)', Default = 0.2, Min = 0.05, Max = 2, Rounding = 2 })
ParryGrp:AddSlider('BL_ParryMaxLen', { Text = 'Max Animation Length (s)', Default = 3, Min = 0.5, Max = 10, Rounding = 1 })
ParryGrp:AddSlider('BL_ParryRange', { Text = 'Trigger Range (studs)', Default = 18, Min = 5, Max = 60, Rounding = 0 })
ParryGrp:AddToggle('BL_ParryFacing', { Text = 'Only when the enemy faces me', Default = true })
ParryGrp:AddSlider('BL_ParryDelay', { Text = 'Delay After Trigger (s) - uncalibrated', Default = 0, Min = 0, Max = 1, Rounding = 2 })
ParryGrp:AddSlider('BL_ParryHold', { Text = 'Hold Block (s) - uncalibrated', Default = 0.45, Min = 0.1, Max = 1.5, Rounding = 2 })
ParryGrp:AddToggle('BL_ParryHoldAnim', { Text = 'Hold until the animation ends (max 1.5 s)', Default = false })
ParryGrp:AddToggle('BL_ParryPlayers', { Text = 'Also parry other players', Default = false })
ParryGrp:AddToggle('BL_ParryLearn', { Text = 'Learn attack animations from hits I take', Default = true })
ParryGrp:AddInput('BL_ParryInclude', { Default = '', Text = 'Always parry animation ids', Placeholder = '123456, 789012' })
ParryGrp:AddInput('BL_ParryExclude', { Default = '', Text = 'Never parry animation ids', Placeholder = '123456, 789012' })
ParryGrp:AddToggle('BL_ParryOnMelee', { Text = 'Trigger: enemy MeleeCooldown on (never fired in the log)', Default = false })
ParryGrp:AddToggle('BL_ParryOnSkill', { Text = 'Trigger: enemy CurrentSkill set', Default = true })
ParryGrp:AddToggle('BL_ParryLog', { Text = 'Log animations, hits and my blocks', Default = false })

do
    local function logParry(text)
        if not Toggles.BL_ParryLog.Value then return end
        local log = parry.log
        log[#log + 1] = string.format('%.3f %s', os.clock(), text)
        if #log > 5000 then table.remove(log, 1) end
    end

    local function endBlock()
        parry.blocking = false
        parry.holdUntil = 0
        if not DataFunction then return end
        local ok, result = pcall(function() return DataFunction:InvokeServer(BUILD.EndBlockAction) end)
        logParry('EndBlock -> ' .. tostring(ok) .. ' ' .. tostring(result))
    end

    -- Extends the hold if a block is already up, otherwise raises one.
    local function requestBlock(duration)
        parry.holdUntil = math.max(parry.holdUntil, os.clock() + duration)
        if parry.blocking or not DataFunction or not getCharacter() then return end
        parry.blocking = true
        task.spawn(function()
            local ok, result = pcall(function() return DataFunction:InvokeServer(BUILD.BlockAction, BUILD.BlockArg) end)
            logParry('Block -> ' .. tostring(ok) .. ' ' .. tostring(result))
            if not (ok and result == true) then
                parry.blocking = false
                parry.holdUntil = 0
                return
            end
            while os.clock() < parry.holdUntil do task.wait(0.03) end
            endBlock()
        end)
    end

    local function minRank()
        local name = Options.BL_ParryMinPriority.Value
        local ok, value = pcall(function() return Enum.AnimationPriority[name].Value end)
        if ok and type(value) == 'number' then return value end
        return ({ Idle = 0, Movement = 1, Action = 2, Action2 = 3, Action3 = 4, Action4 = 5 })[name] or 2
    end

    local function parryConfig()
        return {
            minRank = minRank(), minLength = Options.BL_ParryMinLen.Value, maxLength = Options.BL_ParryMaxLen.Value,
            include = Pure.parseIdSet(Options.BL_ParryInclude.Value), exclude = Pure.parseIdSet(Options.BL_ParryExclude.Value),
            learned = parry.learned,
        }
    end

    local function trigger(model, why, length)
        local _, _, myRoot = getCharacter()
        local root = model:FindFirstChild('HumanoidRootPart')
        if not myRoot or not root then return end
        local distance = (root.Position - myRoot.Position).Magnitude
        if distance > Options.BL_ParryRange.Value then
            logParry(string.format('skip %s %s: %dm out of range', model.Name, why, math.floor(distance)))
            return
        end
        if Toggles.BL_ParryFacing.Value then
            local look = root.CFrame.LookVector
            if not Pure.isFacing(root.Position.X, root.Position.Z, look.X, look.Z, myRoot.Position.X, myRoot.Position.Z, 0.2) then
                logParry(string.format('skip %s %s: not facing me', model.Name, why))
                return
            end
        end
        local delay = Options.BL_ParryDelay.Value
        local hold = Options.BL_ParryHold.Value
        if Toggles.BL_ParryHoldAnim.Value and length then hold = math.max(hold, math.min(length - delay, 1.5)) end
        logParry(string.format('PARRY %s %s (%dm) delay=%.2f hold=%.2f', model.Name, why, math.floor(distance), delay, hold))
        if delay <= 0 then
            requestBlock(hold)
        else
            task.delay(delay, function()
                if Toggles.BL_AutoParry.Value then requestBlock(hold) end
            end)
        end
    end

    local function onEnemyAnimation(model, track)
        local anim = track.Animation
        local info = {
            id = anim and anim.AnimationId, looped = track.Looped, length = track.Length,
            priority = track.Priority and track.Priority.Value,
        }
        local isAttack, why = Pure.isAttackAnimation(info, parryConfig())
        local _, _, myRoot = getCharacter()
        local root = model:FindFirstChild('HumanoidRootPart')
        local distance = (myRoot and root) and (root.Position - myRoot.Position).Magnitude or math.huge
        local now = os.clock()
        local recent = parry.recent
        recent[#recent + 1] = { t = now, id = Pure.animId(info.id), name = model.Name, length = info.length, looped = info.looped,
            rank = Pure.priorityRank(info.priority), dist = distance, attack = isAttack }
        while #recent > 0 and now - recent[1].t > 2 do table.remove(recent, 1) end
        logParry(string.format('enemy %s: anim id=%s prio=%s looped=%s len=%.2f dist=%d -> %s (%s)', model.Name,
            tostring(Pure.animId(info.id)), tostring(info.priority), tostring(info.looped), tonumber(info.length) or -1,
            distance == math.huge and -1 or math.floor(distance), isAttack and 'ATTACK' or 'ignore', why))
        if isAttack and Toggles.BL_AutoParry.Value and Toggles.BL_ParryOnAnim.Value then
            trigger(model, 'anim ' .. tostring(Pure.animId(info.id)), info.length)
        end
    end

    local function onSettingsTrigger(model, what, enabled)
        if not enabled or not Toggles.BL_AutoParry.Value then
            logParry(string.format('enemy %s: %s [trigger off]', model.Name, what))
            return
        end
        trigger(model, what, nil)
    end

    local function unwatch(model)
        local entry = parry.watched[model]
        if not entry then return end
        for _, conn in ipairs(entry) do conn:Disconnect() end
        parry.watched[model] = nil
    end

    local function watch(model, withSettings)
        if parry.watched[model] then return end
        local entry = {}
        parry.watched[model] = entry
        entry[#entry + 1] = model.AncestryChanged:Connect(function(_, parent)
            if not parent then unwatch(model) end
        end)
        task.spawn(function()
            local hum = model:WaitForChild('Humanoid', 10)
            if not hum or parry.watched[model] ~= entry then return end
            local animator = hum:FindFirstChildOfClass('Animator') or hum:WaitForChild('Animator', 3)
            if parry.watched[model] ~= entry then return end
            local source = animator or hum
            entry[#entry + 1] = source.AnimationPlayed:Connect(function(track) onEnemyAnimation(model, track) end)
            if not withSettings then return end
            local settings = model:WaitForChild(BUILD.SettingsFolder, 10)
            if not settings or parry.watched[model] ~= entry then return end
            local melee = settings:FindFirstChild(BUILD.SettingsMeleeCooldown)
            local skill = settings:FindFirstChild(BUILD.SettingsCurrentSkill)
            if melee and melee:IsA('BoolValue') then
                entry[#entry + 1] = melee:GetPropertyChangedSignal('Value'):Connect(function()
                    if melee.Value == true then onSettingsTrigger(model, 'MeleeCooldown=true', Toggles.BL_ParryOnMelee.Value) end
                end)
            end
            if skill and skill:IsA('StringValue') then
                entry[#entry + 1] = skill:GetPropertyChangedSignal('Value'):Connect(function()
                    if skill.Value ~= '' then onSettingsTrigger(model, 'CurrentSkill=' .. skill.Value, Toggles.BL_ParryOnSkill.Value) end
                end)
            end
        end)
    end

    local function isPlayerCharacter(model)
        local player = Players:FindFirstChild(model.Name)
        return player ~= nil and player ~= LocalPlayer and player.Character == model
    end

    -- `fresh` models may still be replicating their children, so wait briefly for the NPC value; the initial
    -- scan only looks at what is already there.
    local function watchIfEnemy(model, fresh)
        if not model:IsA('Model') then return end
        if Toggles.BL_ParryPlayers.Value and isPlayerCharacter(model) then
            watch(model, false)
            return
        end
        local function check(value)
            if value and value:IsA('StringValue') and value.Value == BUILD.NPCCombat then watch(model, true) end
        end
        if not fresh then
            check(model:FindFirstChild(BUILD.NPCValueName))
            return
        end
        task.spawn(function() check(model:WaitForChild(BUILD.NPCValueName, 5)) end)
    end

    local function active()
        return Toggles.BL_AutoParry.Value or Toggles.BL_ParryLog.Value
    end

    local function spy(action, ...)
        if action ~= BUILD.BlockAction and action ~= BUILD.EndBlockAction then return end
        local args = {}
        for i = 1, select('#', ...) do args[i] = tostring((select(i, ...))) end
        logParry('GAME ' .. action .. ' ' .. table.concat(args, ' '))
    end

    local function refreshWatch()
        if active() then
            for _, child in ipairs(workspace:GetChildren()) do watchIfEnemy(child, false) end
        else
            for model in pairs(parry.watched) do unwatch(model) end
        end
        if not Toggles.BL_ParryPlayers.Value then
            for model, entry in pairs(parry.watched) do
                if isPlayerCharacter(model) then unwatch(model) end
            end
        end
        if Toggles.BL_ParryLog.Value and installHook() then hook.spy = spy else hook.spy = nil end
    end

    connect(workspace.ChildAdded, function(child)
        if active() then watchIfEnemy(child, true) end
    end)
    Toggles.BL_AutoParry:OnChanged(function()
        if Toggles.BL_AutoParry.Value and not DataFunction then
            Library:Notify('Auto Parry unavailable: DataFunction missing')
            Toggles.BL_AutoParry:SetValue(false)
            return
        end
        refreshWatch()
    end)
    Toggles.BL_ParryLog:OnChanged(refreshWatch)
    Toggles.BL_ParryPlayers:OnChanged(refreshWatch)

    -- ---------------- hits I take: log them and learn which animation caused them ----------------
    local function onDamaged(amount)
        local now = os.clock()
        local cfg = parryConfig()
        for i = #parry.recent, 1, -1 do
            local r = parry.recent[i]
            if now - r.t > 0.9 then break end
            local plausible = not r.looped and r.id and r.rank >= 0 and r.length >= cfg.minLength and r.length <= cfg.maxLength
                and r.dist <= Options.BL_ParryRange.Value * 1.5
            if plausible then
                logParry(string.format('HIT -%.1f hp, %.2fs after %s anim id=%s prio=%s len=%.2f (%s)', amount, now - r.t, r.name,
                    r.id, tostring(r.rank), r.length, r.attack and 'was ATTACK' or 'was ignored'))
                if Toggles.BL_ParryLearn.Value and not r.attack and Pure.learnAttack(parry.counts, r.id, 2) then
                    parry.learned[r.id] = true
                    Library:Notify('Auto Parry learned attack animation ' .. r.id)
                    logParry('LEARNED ' .. r.id)
                end
                return
            end
        end
        logParry(string.format('HIT -%.1f hp with no recent enemy animation', amount))
    end

    local healthConn
    local function watchMyHealth(char)
        if healthConn then healthConn:Disconnect() healthConn = nil end
        task.spawn(function()
            local hum = char:WaitForChild('Humanoid', 10)
            if not hum or LocalPlayer.Character ~= char then return end
            local last = hum.Health
            healthConn = hum.HealthChanged:Connect(function(health)
                if health < last - 0.01 and active() then onDamaged(last - health) end
                last = health
            end)
        end)
    end
    connect(LocalPlayer.CharacterAdded, watchMyHealth)
    if LocalPlayer.Character then watchMyHealth(LocalPlayer.Character) end

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
    ParryGrp:AddButton({ Text = 'Print Learned Animations', Func = function()
        local ids = {}
        for id in pairs(parry.learned) do ids[#ids + 1] = id end
        table.sort(ids)
        Library:Notify(#ids > 0 and ('Learned: ' .. table.concat(ids, ', ')) or 'Nothing learned yet', 8)
    end })
    ParryGrp:AddButton({ Text = 'Clear Learned Animations', Func = function() parry.learned, parry.counts = {}, {} end })

    onCleanup(function()
        if healthConn then healthConn:Disconnect() end
        for model in pairs(parry.watched) do unwatch(model) end
        if parry.blocking then task.spawn(endBlock) end
    end)
end

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
    { toggle = 'BL_EspFruits',   color = 'BL_EspFruitsColor',   label = 'Fruits (from Auto Fruits)', default = Color3.fromRGB(255, 140, 60) },
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
local lootIds = {}       -- ID values that sit next to an Active flag (loose items)
local itemScanStarted = false
local function registerItem(inst)
    if inst.Name == BUILD.ItemDetectorName and inst:IsA('ClickDetector') then
        itemDetectors[inst] = true
    elseif inst.Name == BUILD.LootIdName and inst:IsA('ValueBase') then
        local holder = inst.Parent
        if holder and holder:FindFirstChild(BUILD.LootActiveName) then lootIds[inst] = true end
    elseif inst.Name == BUILD.LootActiveName and inst:IsA('BoolValue') then
        local holder = inst.Parent
        local idValue = holder and holder:FindFirstChild(BUILD.LootIdName)
        if idValue and idValue:IsA('ValueBase') then lootIds[idValue] = true end
    end
end
local function ensureItemScan()
    if itemScanStarted then return end
    itemScanStarted = true
    connect(workspace.DescendantAdded, registerItem)
    connect(workspace.DescendantRemoving, function(inst) itemDetectors[inst] = nil lootIds[inst] = nil end)
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
    if Toggles.BL_EspFruits.Value then
        for _, fruit in ipairs(rt.fruits) do
            if fruit.part and fruit.part.Parent then add(fruit.part, fruit.part, nil, fruit.part.Name .. ' (fruit)', 'BL_EspFruitsColor') end
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
--  COLLECTING: harvest items, loot drops, fruits
--  One verified-pickup routine serves all three. A pickup counts only when the item changes state afterwards
--  (gone, hidden, detector disabled); otherwise it is retried, then put on a cooldown and counted as a failure.
--  UNVERIFIED in game: that this game's items change state on pickup (the harvest log records before/after so it
--  can be checked), the loot object layout (inferred from the click handler at L8201-8202) and the fruit return shape.
-- ================================================================

UtilGrp:AddInput('BL_HarvestFilter', { Default = '', Text = 'Harvest name contains', Placeholder = 'empty = any item' })
UtilGrp:AddSlider('BL_HarvestInterval', { Text = 'Harvest Interval (s) - uncalibrated', Default = 1.5, Min = 0.5, Max = 5, Rounding = 1 })
UtilGrp:AddSlider('BL_HarvestSkip', { Text = 'Skip Collected Item For (s) - uncalibrated', Default = 30, Min = 0, Max = 300, Rounding = 0 })
UtilGrp:AddSlider('BL_HarvestAttempts', { Text = 'Pickup Attempts Per Item', Default = 4, Min = 1, Max = 10, Rounding = 0 })
UtilGrp:AddSlider('BL_HarvestVerify', { Text = 'Wait For Item To Change (s)', Default = 1.2, Min = 0.3, Max = 4, Rounding = 1 })
UtilGrp:AddSlider('BL_HarvestFailCooldown', { Text = 'Retry Failed Item After (s)', Default = 20, Min = 3, Max = 300, Rounding = 0 })

local collect = { log = {}, stats = { ok = 0, fail = 0 } }

local function logCollect(text)
    local log = collect.log
    log[#log + 1] = string.format('%.3f %s', os.clock(), text)
    if #log > 2000 then table.remove(log, 1) end
end

-- Builds a function that triggers whatever the object offers: ClickDetector, ProximityPrompt, or the PickUp
-- remote when it carries ID and Active values. Returns nil, 'nothing to activate' when none exists.
local function makeActivator(inst)
    local click, prompt, idValue
    local function inspect(node)
        if node:IsA('ClickDetector') then click = click or node
        elseif node:IsA('ProximityPrompt') then prompt = prompt or node
        elseif node.Name == BUILD.LootIdName and node:IsA('ValueBase') then idValue = idValue or node end
    end
    inspect(inst)
    for _, node in ipairs(inst:GetDescendants()) do inspect(node) end
    if not (click or prompt or idValue) then return nil, 'nothing to activate' end
    return function()
        if click and type(fireclickdetector) == 'function' then fireclickdetector(click) end
        if prompt and type(fireproximityprompt) == 'function' then fireproximityprompt(prompt) end
        if idValue and DataEvent then DataEvent:FireServer(BUILD.PickUpAction, idValue.Value, BUILD.PickUpArg) end
    end, (click and 'click ' or '') .. (prompt and 'prompt ' or '') .. (idValue and 'pickup-remote' or '')
end

-- Snapshot of an item's pickup-relevant state; `holder` is the object, `part` a BasePart of it.
local function itemSnapshot(holder, part)
    local present = holder.Parent ~= nil and part.Parent ~= nil
    if not present then return { present = false } end
    local active = true
    local click = holder:FindFirstChildWhichIsA('ClickDetector', true)
    if click then active = click.MaxActivationDistance > 0 and click.Parent ~= nil end
    local flag = holder:FindFirstChild(BUILD.LootActiveName)
    if flag and flag:IsA('BoolValue') and flag.Value == false then active = false end
    return { present = true, transparency = part.Transparency, active = active, y = part.Position.Y }
end

-- Moves next to `part`, activates, and waits for the item to change. Yields.
-- Returns ok, attemptsUsed, reason. Always re-pins the character next to the item before each attempt.
local function collectWithVerify(owner, holder, part, activate, attempts, verifyTime)
    local before = itemSnapshot(holder, part)
    for attempt = 1, attempts do
        local _, _, root = getCharacter()
        if not root then return false, attempt - 1, 'no character' end
        if rt.safety.active then return false, attempt - 1, 'safety retreat' end
        if not part.Parent then return true, attempt - 1, 'gone' end
        local pos = part.Position
        if attempt == 1 or (root.Position - pos).Magnitude > 6 then
            if not travelTo(owner, CFrame.new(pos + Vector3.new(0, 3, 0))) then return false, attempt - 1, 'move refused' end
        end
        activate()
        local waited = 0
        while waited < verifyTime do
            task.wait(0.1)
            waited = waited + 0.1
            if not getCharacter() then return false, attempt, 'died' end
            local changed, why = Pure.itemChanged(before, itemSnapshot(holder, part))
            if changed then return true, attempt, why end
        end
    end
    return false, attempts, 'no change'
end

local function saveCollectLog()
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('writefile/makefolder missing on this executor')
        return
    end
    local folder = 'YazuDumper'
    pcall(function() if type(isfolder) ~= 'function' or not isfolder(folder) then makefolder(folder) end end)
    local path = folder .. '/BL_CollectLog_' .. tostring(os.time()) .. '.txt'
    local header = string.format('collected ok=%d failed=%d', collect.stats.ok, collect.stats.fail)
    local ok, err = pcall(writefile, path, header .. '\n' .. table.concat(collect.log, '\n'))
    Library:Notify(ok and ('Saved ' .. path .. ' (' .. #collect.log .. ' lines)') or ('Write error: ' .. tostring(err)))
end

-- ---------------- Harvest ----------------
local cooldownUntil = setmetatable({}, { __mode = 'k' })   -- holder instance -> os.clock() until which it is skipped
local visitedSpot = {}                                      -- known-position key -> os.clock() of last visit

-- The detector's owner is usually the item model; when it sits directly on a part, the part's model names the item.
local function itemName(holder)
    if holder:IsA('BasePart') and holder.Parent and holder.Parent ~= workspace and holder.Parent:IsA('Model') then
        return holder.Parent.Name
    end
    return holder.Name
end

local function nearestHarvestable()
    ensureItemScan()
    local _, _, root = getCharacter()
    if not root then return nil end
    local filter = Options.BL_HarvestFilter.Value
    local candidates, now = {}, os.clock()
    for detector in pairs(itemDetectors) do
        local holder = detector.Parent
        local part = holder and adorneeOf(holder)
        local label = holder and itemName(holder)
        if part and Pure.nameMatches(label, filter) then
            local p = part.Position
            remember('items', cellKey(label, p.X, p.Z), label, p.X, p.Y, p.Z)
            if not (cooldownUntil[holder] and now < cooldownUntil[holder]) then
                candidates[#candidates + 1] = { detector = detector, holder = holder, part = part, x = p.X, y = p.Y, z = p.Z }
            end
        end
    end
    local origin = root.Position
    return (Pure.pickNearest(candidates, origin.X, origin.Y, origin.Z))
end

-- Returns acted, ok. acted is false when nothing was loaded (or movement was busy).
local function harvestOnce()
    if type(fireclickdetector) ~= 'function' then
        Library:Notify('fireclickdetector missing on this executor')
        return false
    end
    local pick = nearestHarvestable()
    if not pick then return false end
    if not rt.tryMove('harvest') then return false end
    local activate = makeActivator(pick.holder)
    local ok, used, why = false, 0, 'no activator'
    if activate then
        ok, used, why = collectWithVerify('harvest', pick.holder, pick.part, activate, Options.BL_HarvestAttempts.Value, Options.BL_HarvestVerify.Value)
    end
    rt.releaseMove('harvest')
    local now = os.clock()
    if ok then
        collect.stats.ok = collect.stats.ok + 1
        cooldownUntil[pick.holder] = now + Options.BL_HarvestSkip.Value
    else
        collect.stats.fail = collect.stats.fail + 1
        cooldownUntil[pick.holder] = now + Options.BL_HarvestFailCooldown.Value
    end
    logCollect(string.format('harvest %s: %s after %d attempt(s) (%s)', itemName(pick.holder), ok and 'OK' or 'FAILED', used, why))
    return true, ok
end

-- Nothing loaded: travel to a remembered or seeded item position so StreamingEnabled loads it.
local function travelToKnownItem()
    local _, _, root = getCharacter()
    if not root then return false end
    local now, skip = os.clock(), {}
    for key, at in pairs(visitedSpot) do
        if now - at < Options.BL_HarvestSkip.Value then skip[key] = true end
    end
    local origin = root.Position
    local pick = Pure.pickNearest(Pure.filterKnown(rt.known.items, Options.BL_HarvestFilter.Value, skip), origin.X, origin.Y, origin.Z)
    if not pick then return false end
    visitedSpot[pick.key] = now
    if not rt.tryMove('harvest') then return false end
    travelTo('harvest', CFrame.new(Vector3.new(pick.x, pick.y + 3, pick.z)))
    task.wait(1.2)
    rt.releaseMove('harvest')
    logCollect('travelled to remembered item spot: ' .. pick.name)
    return true
end

UtilGrp:AddButton({ Text = 'Harvest Nearest Item', Func = function()
    local acted, ok = harvestOnce()
    if not acted then Library:Notify('No harvestable item loaded (StreamingEnabled hides far ones)')
    elseif not ok then Library:Notify('Item did not change after the attempts; see Save Collect Log') end
end })
UtilGrp:AddToggle('BL_AutoHarvest', { Text = 'Auto Harvest (verified pickup)', Default = false,
    Tooltip = 'Moves next to the item, fires the click, waits for the item to change, retries. Untested in game.' })

do
    local run = 0
    Toggles.BL_AutoHarvest:OnChanged(function()
        run = run + 1
        local mine = run
        if not Toggles.BL_AutoHarvest.Value then return end
        task.spawn(function()
            local warned = false
            while run == mine and Toggles.BL_AutoHarvest.Value do
                local wait = Options.BL_HarvestInterval.Value
                if getCharacter() and not rt.safety.active then
                    local called, acted = pcall(harvestOnce)
                    if not called then
                        if not warned then warned = true Library:Notify('Auto Harvest error: ' .. tostring(acted)) end
                    elseif acted then
                        warned = false
                    else
                        local moved = false
                        local ok2, res = pcall(travelToKnownItem)
                        moved = ok2 and res
                        if not moved and not warned then
                            warned = true
                            Library:Notify('Auto Harvest: nothing loaded or remembered; move toward resources once')
                        end
                    end
                end
                task.wait(wait)
            end
        end)
    end)
    onCleanup(function() run = run + 1 end)
end

-- ---------------- Loot drops (includes quest rewards and other players' drops) ----------------
UtilGrp:AddSlider('BL_LootInterval', { Text = 'Loot Interval (s)', Default = 1, Min = 0.3, Max = 5, Rounding = 1 })
UtilGrp:AddSlider('BL_LootRange', { Text = 'Loot Range (studs)', Default = 200, Min = 20, Max = 1500, Rounding = 0 })
UtilGrp:AddToggle('BL_AutoLoot', { Text = 'Auto Loot Drops (verified pickup)', Default = false,
    Tooltip = 'Picks up loose items: objects with an ID value and an Active flag (the PickUp click handler). Untested in game.' })

local function nearestLoot()
    ensureItemScan()
    local _, _, root = getCharacter()
    if not root then return nil end
    local candidates, now = {}, os.clock()
    for idValue in pairs(lootIds) do
        local holder = idValue.Parent
        local part = holder and adorneeOf(holder)
        local flag = holder and holder:FindFirstChild(BUILD.LootActiveName)
        local active = not (flag and flag:IsA('BoolValue') and flag.Value == false)
        if part and active and not (cooldownUntil[holder] and now < cooldownUntil[holder]) then
            local p = part.Position
            candidates[#candidates + 1] = { holder = holder, part = part, x = p.X, y = p.Y, z = p.Z }
        end
    end
    local origin = root.Position
    local pick, distance = Pure.pickNearest(candidates, origin.X, origin.Y, origin.Z)
    if pick and distance <= Options.BL_LootRange.Value then return pick end
    return nil
end

local function lootOnce()
    local pick = nearestLoot()
    if not pick then return false end
    if not rt.tryMove('loot') then return false end
    local activate = makeActivator(pick.holder)
    local ok, used, why = false, 0, 'no activator'
    if activate then
        ok, used, why = collectWithVerify('loot', pick.holder, pick.part, activate, Options.BL_HarvestAttempts.Value, Options.BL_HarvestVerify.Value)
    end
    rt.releaseMove('loot')
    if ok then collect.stats.ok = collect.stats.ok + 1 else collect.stats.fail = collect.stats.fail + 1 end
    cooldownUntil[pick.holder] = os.clock() + (ok and 60 or Options.BL_HarvestFailCooldown.Value)
    logCollect(string.format('loot %s: %s after %d attempt(s) (%s)', pick.holder.Name, ok and 'OK' or 'FAILED', used, why))
    return true
end

do
    local run = 0
    Toggles.BL_AutoLoot:OnChanged(function()
        run = run + 1
        local mine = run
        if not Toggles.BL_AutoLoot.Value then return end
        if not DataEvent then
            Library:Notify('Auto Loot unavailable: DataEvent missing')
            Toggles.BL_AutoLoot:SetValue(false)
            return
        end
        task.spawn(function()
            local warned = false
            while run == mine and Toggles.BL_AutoLoot.Value do
                if getCharacter() and not rt.safety.active then
                    local called, err = pcall(lootOnce)
                    if not called and not warned then
                        warned = true
                        Library:Notify('Auto Loot error: ' .. tostring(err))
                    end
                end
                task.wait(Options.BL_LootInterval.Value)
            end
        end)
    end)
    onCleanup(function() run = run + 1 end)
end

-- ---------------- Fruits ----------------
UtilGrp:AddSlider('BL_FruitInterval', { Text = 'Fruit Scan Interval (s)', Default = 3, Min = 1, Max = 30, Rounding = 0 })
UtilGrp:AddToggle('BL_AutoFruits', { Text = 'Auto Fruits (NearbyFruitsPlease)', Default = false,
    Tooltip = 'Asks the server for nearby fruits, walks to each and tries click / prompt / pickup. Return shape UNVERIFIED; see the log.' })

local function shapeOf(value, depth)
    local t = typeof(value)
    if t == 'Instance' then return 'Instance(' .. value.ClassName .. ':' .. value.Name .. ')' end
    if t ~= 'table' then return t end
    if depth >= 2 then return 'table' end
    local parts, n = {}, 0
    for k, v in pairs(value) do
        n = n + 1
        if n <= 4 then parts[#parts + 1] = '[' .. shapeOf(k, depth + 1) .. ']=' .. shapeOf(v, depth + 1) end
    end
    return 'table{' .. table.concat(parts, ', ') .. (n > 4 and ', ...' or '') .. '} n=' .. n
end

-- Collects Instances and positions from whatever NearbyFruitsPlease returns (keys and values, depth <= 3).
local function parseFruits(result)
    local out, seen = {}, {}
    local function walk(value, depth)
        if depth > 3 then return end
        local t = typeof(value)
        if t == 'Instance' then
            if not seen[value] then
                seen[value] = true
                local part = adorneeOf(value)
                if part then out[#out + 1] = { inst = value, part = part, x = part.Position.X, y = part.Position.Y, z = part.Position.Z } end
            end
        elseif t == 'Vector3' then
            out[#out + 1] = { x = value.X, y = value.Y, z = value.Z }
        elseif t == 'CFrame' then
            local p = value.Position
            out[#out + 1] = { x = p.X, y = p.Y, z = p.Z }
        elseif t == 'table' then
            for k, v in pairs(value) do
                walk(k, depth + 1)
                walk(v, depth + 1)
            end
        end
    end
    walk(result, 0)
    return out
end

local function fruitPass(state)
    if not DataFunction then return end
    local ok, result = pcall(function() return DataFunction:InvokeServer(BUILD.FruitsFunction) end)
    if not ok then
        logCollect('fruits: call failed: ' .. tostring(result))
        return
    end
    local shape = shapeOf(result, 0)
    if shape ~= state.lastShape then
        state.lastShape = shape
        logCollect('fruits: return shape ' .. shape)
    end
    local list = parseFruits(result)
    local shown = {}
    for _, fruit in ipairs(list) do
        if fruit.part then shown[#shown + 1] = fruit end
    end
    rt.fruits = shown
    if #list == 0 then return end
    local now = os.clock()
    local _, _, root = getCharacter()
    if not root then return end
    local origin = root.Position
    local pending = {}
    for _, fruit in ipairs(list) do
        if fruit.inst and fruit.inst.Parent and not (cooldownUntil[fruit.inst] and now < cooldownUntil[fruit.inst]) then
            pending[#pending + 1] = fruit
        end
    end
    local pick = Pure.pickNearest(pending, origin.X, origin.Y, origin.Z)
    if not pick then return end
    if not rt.tryMove('fruit') then return end
    local activate, note = makeActivator(pick.inst)
    local done, used, why = false, 0, note
    if activate then
        done, used, why = collectWithVerify('fruit', pick.inst, pick.part, activate, Options.BL_HarvestAttempts.Value, Options.BL_HarvestVerify.Value)
    end
    rt.releaseMove('fruit')
    if done then collect.stats.ok = collect.stats.ok + 1 else collect.stats.fail = collect.stats.fail + 1 end
    cooldownUntil[pick.inst] = os.clock() + (done and 60 or Options.BL_HarvestFailCooldown.Value)
    logCollect(string.format('fruit %s: %s after %d attempt(s) (%s)', pick.inst.Name, done and 'OK' or 'FAILED', used, tostring(why)))
end

do
    local run = 0
    Toggles.BL_AutoFruits:OnChanged(function()
        run = run + 1
        local mine = run
        if not Toggles.BL_AutoFruits.Value then return end
        if not DataFunction then
            Library:Notify('Auto Fruits unavailable: DataFunction missing')
            Toggles.BL_AutoFruits:SetValue(false)
            return
        end
        task.spawn(function()
            local state, warned = {}, false
            while run == mine and Toggles.BL_AutoFruits.Value do
                if getCharacter() and not rt.safety.active then
                    local called, err = pcall(fruitPass, state)
                    if not called and not warned then
                        warned = true
                        Library:Notify('Auto Fruits error: ' .. tostring(err))
                    end
                end
                task.wait(Options.BL_FruitInterval.Value)
            end
        end)
    end)
    onCleanup(function() run = run + 1 end)
end

UtilGrp:AddButton({ Text = 'Save Collect Log', Func = saveCollectLog })

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
--  QUESTS
--  Mirrors the game's own dialogue flow (L6826-6832): GetQuestProgress(name) and, when the status is "Start",
--  StartQuest(name, 2). Quest names are not in the dump (they come from NPC dialogue modules at runtime), so they
--  are typed in or found with Discover Quest Names. Every status string the server returns is logged, because
--  only "Start" is known. UNVERIFIED in game: whether the server needs you near the quest giver (use Name@Npc).
-- ================================================================

AutoGrp:AddInput('BL_QuestNames', { Default = '', Text = 'Quest names', Placeholder = 'Quest, Quest@Npc Name' })
AutoGrp:AddSlider('BL_QuestInterval', { Text = 'Quest Check Interval (s)', Default = 8, Min = 2, Max = 120, Rounding = 0 })
AutoGrp:AddToggle('BL_AutoQuest', { Text = 'Auto Quest (accept and turn in)', Default = false,
    Tooltip = 'Calls GetQuestProgress for each listed quest and StartQuest when the status is Start. Statuses are logged. Untested in game.' })

local questLog = {}
local function logQuest(text)
    questLog[#questLog + 1] = string.format('%.3f %s', os.clock(), text)
    if #questLog > 2000 then table.remove(questLog, 1) end
end

-- Dialog NPC position: the loaded model when there is one, otherwise the position recorded in the dump.
local function dialogNpcCFrame(name)
    for _, child in ipairs(workspace:GetChildren()) do
        if child.Name == name and child:IsA('Model') and npcKind(child) == BUILD.NPCDialog then
            local cf = pivotOf(child)
            if cf then return cf end
        end
    end
    for _, seed in ipairs(BUILD.Seeds.npcs) do
        if seed.name == name then return CFrame.new(Vector3.new(seed.x, seed.y, seed.z)) end
    end
    return nil
end

local function questPass(state)
    local list = Pure.parseQuestList(Options.BL_QuestNames.Value)
    if #list == 0 then
        if not state.warned then
            state.warned = true
            Library:Notify('Auto Quest: no quest names set; type some or press Discover Quest Names')
        end
        return
    end
    for _, entry in ipairs(list) do
        if not Toggles.BL_AutoQuest.Value then return end
        if entry.npc and rt.tryMove('quest') then
            local cf = dialogNpcCFrame(entry.npc)
            if cf then
                travelTo('quest', cf + Vector3.new(0, 3, 0))
                task.wait(0.8)
            else
                logQuest('no position known for NPC ' .. entry.npc)
            end
            rt.releaseMove('quest')
        end
        local ok, status, extra = pcall(function() return DataFunction:InvokeServer(BUILD.QuestProgressAction, entry.quest) end)
        logQuest(string.format('%s -> ok=%s status=%s extra=%s', entry.quest, tostring(ok), tostring(status), tostring(extra)))
        if ok and status == BUILD.QuestStatusStart then
            local ok2, result = pcall(function() return DataFunction:InvokeServer(BUILD.QuestStartAction, entry.quest, BUILD.QuestStartArg) end)
            logQuest(string.format('%s StartQuest -> ok=%s result=%s', entry.quest, tostring(ok2), tostring(result)))
        end
        task.wait(0.4)
    end
end

do
    local run = 0
    Toggles.BL_AutoQuest:OnChanged(function()
        run = run + 1
        local mine = run
        if not Toggles.BL_AutoQuest.Value then return end
        if not DataFunction then
            Library:Notify('Auto Quest unavailable: DataFunction missing')
            Toggles.BL_AutoQuest:SetValue(false)
            return
        end
        task.spawn(function()
            local state, warnedError = {}, false
            while run == mine and Toggles.BL_AutoQuest.Value do
                if getCharacter() and not rt.safety.active then
                    local called, err = pcall(questPass, state)
                    if not called and not warnedError then
                        warnedError = true
                        Library:Notify('Auto Quest error: ' .. tostring(err))
                    end
                end
                task.wait(Options.BL_QuestInterval.Value)
            end
        end)
    end)
    onCleanup(function() run = run + 1 end)
end

local function ensureFolder()
    local folder = 'YazuDumper'
    pcall(function() if type(isfolder) ~= 'function' or not isfolder(folder) then makefolder(folder) end end)
    return folder
end

-- Walks every loaded ModuleScript table for keys or string values mentioning "quest".
local function discoverQuests()
    if type(getloadedmodules) ~= 'function' then
        Library:Notify('getloadedmodules missing on this executor')
        return
    end
    local lines, candidates, order = {}, {}, {}
    local nodes = 0
    local function addCandidate(name)
        if type(name) == 'string' and name ~= '' and #name <= 60 and not candidates[name] and #order < 60 then
            candidates[name] = true
            order[#order + 1] = name
        end
    end
    local function walk(value, path, depth, seen)
        if depth > 5 or nodes > 20000 or seen[value] then return end
        seen[value] = true
        for k, v in pairs(value) do
            nodes = nodes + 1
            local keyText = tostring(k)
            local isQuestKey = string.find(string.lower(keyText), 'quest', 1, true) ~= nil
            if type(v) == 'string' and (isQuestKey or string.find(string.lower(v), 'quest', 1, true)) then
                lines[#lines + 1] = path .. '.' .. keyText .. ' = ' .. v
                if isQuestKey then addCandidate(v) end
            elseif isQuestKey and #lines < 400 then
                lines[#lines + 1] = path .. '.' .. keyText .. ' (' .. typeof(v) .. ')'
                if type(v) == 'table' then
                    for innerKey in pairs(v) do addCandidate(innerKey) end
                end
            end
            if type(v) == 'table' then walk(v, path .. '.' .. keyText, depth + 1, seen) end
        end
    end
    local okModules, modules = pcall(getloadedmodules)
    if not okModules or type(modules) ~= 'table' then
        Library:Notify('getloadedmodules failed: ' .. tostring(modules))
        return
    end
    for _, module in ipairs(modules) do
        if nodes > 20000 then break end
        local ok, data = pcall(require, module)
        if ok and type(data) == 'table' then walk(data, module.Name, 0, {}) end
    end
    if Options.BL_QuestNames.Value == '' and #order > 0 then Options.BL_QuestNames:SetValue(table.concat(order, ', ')) end
    lines[#lines + 1] = 'candidates: ' .. table.concat(order, ', ')
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('Found ' .. #order .. ' candidate names (writefile missing; see the field)')
        return
    end
    local path = ensureFolder() .. '/BL_Quests_' .. tostring(os.time()) .. '.txt'
    local ok, err = pcall(writefile, path, table.concat(lines, '\n'))
    Library:Notify(ok and ('Found ' .. #order .. ' candidate names; saved ' .. path) or ('Write error: ' .. tostring(err)), 8)
end

AutoGrp:AddButton({ Text = 'Discover Quest Names', Func = function() task.spawn(discoverQuests) end })
AutoGrp:AddButton({ Text = 'Save Quest Log', Func = function()
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('writefile/makefolder missing on this executor')
        return
    end
    local path = ensureFolder() .. '/BL_QuestLog_' .. tostring(os.time()) .. '.txt'
    local ok, err = pcall(writefile, path, table.concat(questLog, '\n'))
    Library:Notify(ok and ('Saved ' .. path .. ' (' .. #questLog .. ' lines)') or ('Write error: ' .. tostring(err)))
end })

-- ================================================================
--  AUTO PROGRESSION: one switch for the grind loop
-- ================================================================

local PROGRESSION_TOGGLES = { 'BL_AutoQuest', 'BL_AutoFarm', 'BL_AutoGrip', 'BL_AutoLoot', 'BL_AutoParry', 'BL_AutoSafety' }
AutoGrp:AddToggle('BL_AutoProgress', { Text = 'Auto Progression (grind loop)', Default = false,
    Tooltip = 'Turns on Auto Quest, Auto Farm, Auto Grip, Auto Loot, Auto Parry and Auto Safety together; off turns them off.',
    Callback = function(state)
        for _, idx in ipairs(PROGRESSION_TOGGLES) do
            local toggle = Toggles[idx]
            if toggle and toggle.Value ~= state then toggle:SetValue(state) end
        end
    end })

-- ================================================================
--  SERVER HOP: lowest population
--  The server list URL is from memory, UNVERIFIED here; the page order is not trusted, the lowest count across the
--  fetched pages is picked.
-- ================================================================

ServerGrp:AddSlider('BL_HopPages', { Text = 'Server Pages To Scan', Default = 2, Min = 1, Max = 10, Rounding = 0 })
ServerGrp:AddSlider('BL_HopMinPlayers', { Text = 'Skip Servers Below Players', Default = 1, Min = 0, Max = 20, Rounding = 0 })
ServerGrp:AddToggle('BL_HopReexec', { Text = 'Re-run script after hop', Default = true })
ServerGrp:AddInput('BL_HopScript', { Default = "loadstring(game:HttpGet('" .. BUILD.ReexecUrl .. "'))()", Text = 'Script to re-run', Placeholder = 'queued with queue_on_teleport' })

local function fetchServers(pages)
    local HttpService = game:GetService('HttpService')
    local servers, cursor = {}, nil
    for _ = 1, pages do
        local url = BUILD.ServerListBase .. tostring(game.PlaceId) .. BUILD.ServerListQuery .. (cursor and ('&cursor=' .. cursor) or '')
        local okGet, body = pcall(function() return game:HttpGet(url) end)
        if not okGet then return servers, 'request failed: ' .. tostring(body) end
        local okJson, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not okJson or type(data) ~= 'table' or type(data.data) ~= 'table' then return servers, 'unexpected response' end
        for _, s in ipairs(data.data) do
            servers[#servers + 1] = { id = s.id, playing = s.playing, maxPlayers = s.maxPlayers }
        end
        cursor = data.nextPageCursor
        if type(cursor) ~= 'string' then break end
    end
    return servers
end

local function hopLowest()
    local servers, err = fetchServers(Options.BL_HopPages.Value)
    if #servers == 0 then
        Library:Notify('Server hop: no server list (' .. tostring(err) .. ')', 8)
        return
    end
    local pick = Pure.pickServer(servers, game.JobId, Options.BL_HopMinPlayers.Value)
    if not pick then
        Library:Notify('Server hop: no other server matched in ' .. #servers .. ' scanned', 8)
        return
    end
    if Toggles.BL_HopReexec.Value and type(queue_on_teleport) == 'function' then
        pcall(queue_on_teleport, Options.BL_HopScript.Value)
    end
    Library:Notify(string.format('Hopping to a server with %d/%s players', pick.playing, tostring(pick.maxPlayers)), 6)
    local ok, teleportError = pcall(function()
        game:GetService('TeleportService'):TeleportToPlaceInstance(game.PlaceId, pick.id, LocalPlayer)
    end)
    if not ok then Library:Notify('Teleport failed: ' .. tostring(teleportError), 8) end
end

ServerGrp:AddButton({ Text = 'Hop To Lowest Population', Func = function() task.spawn(hopLowest) end })
ServerGrp:AddButton({ Text = 'Show Lowest Populations', Func = function()
    task.spawn(function()
        local servers, err = fetchServers(Options.BL_HopPages.Value)
        if #servers == 0 then Library:Notify('No server list (' .. tostring(err) .. ')', 8) return end
        table.sort(servers, function(a, b) return (a.playing or 0) < (b.playing or 0) end)
        local parts = {}
        for i = 1, math.min(5, #servers) do parts[#parts + 1] = tostring(servers[i].playing) .. '/' .. tostring(servers[i].maxPlayers) end
        Library:Notify('Lowest of ' .. #servers .. ' scanned: ' .. table.concat(parts, ', '), 10)
    end)
end })

-- ================================================================
--  TELEPORTS
-- ================================================================

TpGrp:AddDropdown('BL_ChakraPoint', { Text = 'Chakra Point', Values = {}, AllowNull = true })
TpGrp:AddButton({ Text = 'Teleport To Chakra Point', Func = function()
    local key = Options.BL_ChakraPoint.Value
    local point = key and State.BL_ChakraMap and State.BL_ChakraMap[key]
    if not (point and point.Parent and teleportTo(pivotOf(point))) then
        Library:Notify('Chakra point not available (press Refresh Lists)')
    end
end })
TpGrp:AddDropdown('BL_Npc', { Text = 'Dialog NPC', Values = {}, AllowNull = true })
TpGrp:AddButton({ Text = 'Teleport To NPC', Func = function()
    local entry = State.BL_NpcMap and State.BL_NpcMap[Options.BL_Npc.Value]
    local cf
    if entry and entry.seed then
        cf = CFrame.new(Vector3.new(entry.seed.x, entry.seed.y, entry.seed.z))
    elseif entry and entry.model and entry.model.Parent then
        cf = pivotOf(entry.model)
    end
    if not (cf and teleportTo(cf)) then
        Library:Notify('NPC position unknown (press Refresh Lists)')
    end
end })
TpGrp:AddDropdown('BL_Player', { Text = 'Player', Values = {}, AllowNull = true })
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

    -- Loaded Dialog NPCs first, then the dump's recorded positions for the ones streaming has unloaded.
    local npcMap, npcNames = {}, {}
    eachNpc(function(model, kind)
        if kind == BUILD.NPCDialog and not npcMap[model.Name] then
            npcMap[model.Name] = { model = model }
            npcNames[#npcNames + 1] = model.Name
        end
    end)
    for _, seed in ipairs(BUILD.Seeds.npcs) do
        if not npcMap[seed.name] then
            npcMap[seed.name] = { seed = seed }
            npcNames[#npcNames + 1] = seed.name
        end
    end
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

-- ================================================================
--  MOVEMENT DIAGNOSTICS
--  Nothing in this module moves the character unless a toggle is on.
--  SaveManager:LoadAutoloadConfig() in main.lua restores toggles from a
--  saved config AFTER every module loads, so a stale saved toggle (Fly,
--  Desync, Null Strike, ...) can start pulling you on execute. The audit
--  below lists any such toggle that is on, using index names taken from
--  features/misc.lua and this file.
-- ================================================================

local MOVEMENT_TOGGLES = {
    -- misc.lua
    'FlyToggle', 'NoClipToggle', 'BetterNoClip', 'GhostMode', 'FreeCamToggle', 'ClickTeleport',
    'InfiniteJump', 'WalkspeedToggle', 'JumpPowerToggle', 'SpinBotEnabled',
    'NullStrikeEnabled', 'DesyncEnabled', 'PassiveLagEnabled', 'StateSpoofEnabled',
    'HitConfusionEnabled', 'BaitEnabled',
    -- this file
    'BL_Fly', 'BL_Noclip', 'BL_Speed', 'BL_AutoFarm', 'BL_AutoTarget', 'BL_AutoAttack', 'BL_AutoGrip', 'BL_AutoHarvest',
    'BL_AutoLoot', 'BL_AutoFruits', 'BL_AutoQuest', 'BL_AutoSafety', 'BL_AutoProgress', 'BL_AutoParry',
}

local function enabledMovementToggles()
    local on = {}
    for _, idx in ipairs(MOVEMENT_TOGGLES) do
        local toggle = Toggles[idx]
        if toggle and toggle.Value == true then on[#on + 1] = idx end
    end
    return on
end

local MOVER_CLASSES = {
    BodyVelocity = true, BodyGyro = true, BodyPosition = true, BodyThrust = true, BodyForce = true,
    BodyAngularVelocity = true, RocketPropulsion = true, LinearVelocity = true, VectorForce = true,
    AlignPosition = true, AlignOrientation = true,
}

local function movementReport()
    local lines = { 'Bloodlines movement report, os.time ' .. tostring(os.time()) }
    local on = enabledMovementToggles()
    lines[#lines + 1] = 'Toggles on: ' .. (#on > 0 and table.concat(on, ', ') or '(none)')
    lines[#lines + 1] = 'Block BanMe hook installed: ' .. tostring(hook.installed) .. ', BanMe reports blocked so far: ' .. tostring(hook.blockedBans)
    lines[#lines + 1] = 'BanMe reasons: ' .. banReasonsText()
    local char, hum, root = getCharacter()
    if not char then
        lines[#lines + 1] = 'No living character.'
        return lines
    end
    local okState, state = pcall(function() return hum:GetState() end)
    lines[#lines + 1] = string.format('Humanoid: state=%s WalkSpeed=%s JumpPower=%s PlatformStand=%s Sit=%s',
        okState and tostring(state) or '?', tostring(hum.WalkSpeed), tostring(hum.JumpPower), tostring(hum.PlatformStand), tostring(hum.Sit))
    local v = root.AssemblyLinearVelocity
    lines[#lines + 1] = string.format('Root: Anchored=%s position=(%.1f, %.1f, %.1f) velocity=(%.1f, %.1f, %.1f)',
        tostring(root.Anchored), root.Position.X, root.Position.Y, root.Position.Z, v.X, v.Y, v.Z)
    lines[#lines + 1] = 'Workspace.Gravity: ' .. tostring(workspace.Gravity)
    local movers = 0
    for _, inst in ipairs(char:GetDescendants()) do
        if MOVER_CLASSES[inst.ClassName] then
            movers = movers + 1
            lines[#lines + 1] = 'Mover on character: ' .. inst:GetFullName() .. ' (' .. inst.ClassName .. ')'
        end
    end
    if movers == 0 then lines[#lines + 1] = 'Movers on character: none' end
    return lines
end

SafeGrp:AddButton({ Text = 'Save Movement Report', Func = function()
    local lines = movementReport()
    for _, line in ipairs(lines) do print('[Bloodlines] ' .. line) end
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('Report printed to the console (writefile missing)')
        return
    end
    local folder = 'YazuDumper'
    pcall(function() if type(isfolder) ~= 'function' or not isfolder(folder) then makefolder(folder) end end)
    local path = folder .. '/BL_MoveReport_' .. tostring(os.time()) .. '.txt'
    local ok, err = pcall(writefile, path, table.concat(lines, '\n'))
    Library:Notify(ok and ('Saved ' .. path) or ('Write error: ' .. tostring(err)))
end })
SafeGrp:AddButton({ Text = 'Turn Off Movement Toggles', Func = function()
    local on = enabledMovementToggles()
    for _, idx in ipairs(on) do Toggles[idx]:SetValue(false) end
    Library:Notify(#on > 0 and ('Turned off: ' .. table.concat(on, ', ')) or 'No movement toggle was on')
end })

-- Records position, velocity and humanoid state every frame, so a pull that lasts only a moment
-- is still captured. Velocity-consistent drift looks like a physics force; a frame that jumps
-- away from the previous frame's prediction is a snap (server correction or a direct CFrame write).
SafeGrp:AddSlider('BL_RecordSeconds', { Text = 'Record Length (s)', Default = 15, Min = 5, Max = 60, Rounding = 0 })
SafeGrp:AddSlider('BL_SnapThreshold', { Text = 'Snap Threshold (studs)', Default = 8, Min = 2, Max = 50, Rounding = 0 })

local recorder = { conn = nil }
local function finishRecording(samples, seconds, bansBefore, reasonsBefore)
    if recorder.conn then recorder.conn:Disconnect() recorder.conn = nil end
    local analysis = Pure.analyzeTrack(samples, Options.BL_SnapThreshold.Value)
    local lines = {
        'Bloodlines movement recording, os.time ' .. tostring(os.time()),
        string.format('Length %.1fs, frames %d, max speed %.1f studs/s, max single-frame step %.1f studs',
            seconds, analysis.frames, analysis.maxSpeed, analysis.maxStep),
        'BanMe reports dropped during recording: ' .. tostring(hook.blockedBans - bansBefore),
    }
    local reasonParts = {}
    for key, count in pairs(hook.reasons) do
        local gained = count - (reasonsBefore[key] or 0)
        if gained > 0 then reasonParts[#reasonParts + 1] = key .. ' x' .. gained end
    end
    table.sort(reasonParts)
    lines[#lines + 1] = 'BanMe reasons during recording: ' .. (#reasonParts > 0 and table.concat(reasonParts, ', ') or '(none)')
    local on = enabledMovementToggles()
    lines[#lines + 1] = 'Toggles on: ' .. (#on > 0 and table.concat(on, ', ') or '(none)')
    lines[#lines + 1] = string.format('Snaps (frame position differs from velocity prediction by more than %d studs): %d',
        Options.BL_SnapThreshold.Value, #analysis.snaps)
    for i = 1, math.min(#analysis.snaps, 40) do
        local snap = analysis.snaps[i]
        lines[#lines + 1] = string.format('  snap t=%.2f err=%.1f delta=(%.1f, %.1f, %.1f)', snap.t, snap.err, snap.dx, snap.dy, snap.dz)
    end
    lines[#lines + 1] = 'Samples every 0.1s: t x y z vx vy vz state'
    local nextAt = 0
    for _, s in ipairs(samples) do
        if s.t >= nextAt then
            nextAt = s.t + 0.1
            lines[#lines + 1] = string.format('%.2f %.1f %.1f %.1f %.1f %.1f %.1f %s', s.t, s.x, s.y, s.z, s.vx, s.vy, s.vz, s.state)
        end
    end
    for _, line in ipairs(lines) do print('[Bloodlines] ' .. line) end
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('Recording printed to the console (writefile missing)')
        return
    end
    local folder = 'YazuDumper'
    pcall(function() if type(isfolder) ~= 'function' or not isfolder(folder) then makefolder(folder) end end)
    local path = folder .. '/BL_MoveRecord_' .. tostring(os.time()) .. '.txt'
    local ok, err = pcall(writefile, path, table.concat(lines, '\n'))
    Library:Notify(ok and ('Saved ' .. path .. ' (' .. #analysis.snaps .. ' snaps)') or ('Write error: ' .. tostring(err)), 8)
end

SafeGrp:AddButton({ Text = 'Record Movement', Func = function()
    if recorder.conn then Library:Notify('Already recording') return end
    local seconds = Options.BL_RecordSeconds.Value
    local samples, elapsed = {}, 0
    local bansBefore = hook.blockedBans
    local reasonsBefore = {}
    for key, count in pairs(hook.reasons) do reasonsBefore[key] = count end
    Library:Notify('Recording movement for ' .. seconds .. 's')
    recorder.conn = RunService.Heartbeat:Connect(function(dt)
        elapsed = elapsed + dt
        local _, hum, root = getCharacter()
        if root and #samples < 20000 then
            local v = root.AssemblyLinearVelocity
            local p = root.Position
            local okState, state = pcall(function() return hum:GetState() end)
            samples[#samples + 1] = { t = elapsed, x = p.X, y = p.Y, z = p.Z, vx = v.X, vy = v.Y, vz = v.Z,
                state = okState and string.gsub(tostring(state), 'Enum.HumanoidStateType.', '') or '?' }
        end
        if elapsed >= seconds then finishRecording(samples, elapsed, bansBefore, reasonsBefore) end
    end)
end })
onCleanup(function()
    if recorder.conn then recorder.conn:Disconnect() recorder.conn = nil end
end)

task.delay(3, function()
    local on = enabledMovementToggles()
    if #on > 0 then
        Library:Notify('Saved config has movement toggles ON: ' .. table.concat(on, ', ') .. ' (Bloodlines > Safety > Turn Off Movement Toggles)', 12)
    end
end)

end
