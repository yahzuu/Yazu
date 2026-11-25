-- ================================================================
--  features/universal_dumper.lua
--  Universal dump bundle for any place: one folder of JSON files,
--  decompiled scripts and a manifest, built to be handed back for
--  tool building.
--
--  Output (toggle "Single file", default on):
--    workspace/YazuDumper/Universal_<PlaceId>_<time>.txt  every part below
--    concatenated, each wrapped in "#### FILE: <name>" / "#### END FILE".
--  With the toggle off, the same parts as separate files in
--    workspace/YazuDumper/Universal_<PlaceId>_<time>/
--  While running, a solid full-screen overlay shows section, item,
--  progress and ETA; Delete or the Cancel button stops it early.
--    manifest.json    place, executor, capabilities, per-section status
--    tree.json        instance tree (grouped siblings, attributes, values, tags)
--    remotes.json     remotes + bindables, client handlers, call sites
--    scripts.json     script index (path, class, hash, size, call-site lines)
--    scripts/*.lua    decompiled LocalScript / ModuleScript sources
--    gc.json          game closures from getgc: constants, upvalues, protos
--    modules.json     ModuleScript return shapes
--    player.json      LocalPlayer data, character, backpack, HUD text
--    world.json       interactables, CollectionService tags, NPC groups
--    animations.json  Animation assets and currently playing tracks
--    env.json         shapes of the game's _G and shared
--
--  Reads only what the client can see. Contains no game-specific
--  values. Every executor function is optional: a missing one marks
--  its section "skipped" in manifest.json with the reason.
-- ================================================================

-- >>> PURE (no Roblox or executor globals below this line until <<< PURE)

local Pure = {}

local JSON_ARRAY = { __jsonArray = true }

function Pure.array(t)
    return setmetatable(t or {}, JSON_ARRAY)
end

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

-- Strings from the game may hold arbitrary bytes. Valid UTF-8 passes
-- through; otherwise every byte >= 0x80 is written as \u00XX so the
-- file stays valid JSON (such a string then reads back as Latin-1).
local function escapeString(s)
    local out = s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', c:byte())
    end)
    if utf8 and utf8.len and utf8.len(out) == nil then
        out = out:gsub('[\128-\255]', function(c)
            return string.format('\\u%04x', c:byte())
        end)
    end
    return '"' .. out .. '"'
end
Pure.escapeString = escapeString

local function encodeNumber(n)
    if n ~= n then return '"NaN"' end
    if n == math.huge then return '"Infinity"' end
    if n == -math.huge then return '"-Infinity"' end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
        return string.format('%d', n)
    end
    return string.format('%.17g', n)
end
Pure.encodeNumber = encodeNumber

local function isArray(t)
    if getmetatable(t) == JSON_ARRAY then return true end
    local n = #t
    if n == 0 then return false end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == n
end

-- Encodes plain Lua data (tables, strings, numbers, booleans, nil).
-- Anything else must be converted by the caller first. Cycles and
-- depth overflow become strings instead of errors.
local function encode(value, buf, depth, seen)
    local t = type(value)
    if value == nil then
        buf[#buf + 1] = 'null'
    elseif t == 'boolean' then
        buf[#buf + 1] = value and 'true' or 'false'
    elseif t == 'number' then
        buf[#buf + 1] = encodeNumber(value)
    elseif t == 'string' then
        buf[#buf + 1] = escapeString(value)
    elseif t == 'table' then
        if seen[value] then
            buf[#buf + 1] = '"<cycle>"'
            return
        end
        if depth > 64 then
            buf[#buf + 1] = '"<depth limit>"'
            return
        end
        seen[value] = true
        if isArray(value) then
            buf[#buf + 1] = '['
            for i = 1, #value do
                if i > 1 then buf[#buf + 1] = ',' end
                encode(value[i], buf, depth + 1, seen)
            end
            buf[#buf + 1] = ']'
        else
            local keys = {}
            for k in pairs(value) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            buf[#buf + 1] = '{'
            for i, k in ipairs(keys) do
                if i > 1 then buf[#buf + 1] = ',' end
                buf[#buf + 1] = escapeString(tostring(k))
                buf[#buf + 1] = ':'
                encode(value[k], buf, depth + 1, seen)
            end
            buf[#buf + 1] = '}'
        end
        seen[value] = nil
    else
        buf[#buf + 1] = escapeString('<' .. t .. '>')
    end
end

function Pure.encode(value)
    local buf = {}
    encode(value, buf, 0, {})
    return table.concat(buf)
end

-- Turns an instance path into a file name that is safe on Windows
-- and unique within one dump (taken = set of names already used).
function Pure.safeFileName(path, taken, maxLen)
    maxLen = maxLen or 150
    local name = tostring(path):gsub('^[%.%s]+', ''):gsub('[%.%s]+$', '')
    name = name:gsub('[<>:"/\\|%?%*%c]', '_'):gsub('%s+', '_')
    if name == '' then name = 'unnamed' end
    if #name > maxLen then name = name:sub(1, maxLen) end
    local base, n = name, 1
    while taken[name:lower()] do
        n = n + 1
        name = base .. '~' .. n
    end
    taken[name:lower()] = true
    return name
end

-- Returns { {line=n, text=...}, ... } for every line containing one of
-- the plain-text needles, capped at limit.
function Pure.findLines(src, needles, limit, maxText)
    local hits, n = {}, 0
    for text in (src .. '\n'):gmatch('(.-)\n') do
        n = n + 1
        for _, needle in ipairs(needles) do
            if text:find(needle, 1, true) then
                if #hits >= limit then return Pure.array(hits), true end
                local trimmed = text:gsub('^%s+', '')
                if #trimmed > maxText then trimmed = trimmed:sub(1, maxText) .. '...' end
                hits[#hits + 1] = { line = n, text = trimmed, match = needle }
                break
            end
        end
    end
    return Pure.array(hits), false
end

-- Converts one value to JSON-safe data. typeofFn is Roblox typeof (or
-- a stub in tests); handlers maps type names to converters for engine
-- types. Unknown types fall back to { t = type, s = tostring }.
function Pure.tagValue(v, typeofFn, handlers, maxStr)
    local lt = type(v)
    if v == nil or lt == 'boolean' then return v end
    if lt == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            return { t = 'number', s = tostring(v) }
        end
        return v
    end
    if lt == 'string' then
        if #v > maxStr then
            return { t = 'string', s = v:sub(1, maxStr), len = #v, cut = true }
        end
        return v
    end
    local rt = typeofFn(v)
    local h = handlers[rt]
    if h then
        local ok, r = pcall(h, v)
        if ok then
            if type(r) == 'table' and r.t == nil then r.t = rt end
            return r
        end
    end
    local ok, s = pcall(tostring, v)
    return { t = rt, s = ok and s or '<tostring failed>' }
end

-- Sibling grouping key used by the tree dump.
function Pure.groupKey(className, name)
    return className .. '|' .. name
end

-- Paths of Roblox's own client code (not the game's).
local CORE_PREFIXES = { 'CoreGui.', 'CorePackages.', '<nil>.CoreGui.', '<nil>.CorePackages.' }
function Pure.isCorePath(path)
    for _, prefix in ipairs(CORE_PREFIXES) do
        if path:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- 75 -> "1:15", 3725 -> "1:02:05"
function Pure.formatDuration(seconds)
    if seconds ~= seconds or seconds < 0 or seconds == math.huge then return '--:--' end
    seconds = math.floor(seconds + 0.5)
    local h, m, sec = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return string.format('%d:%02d:%02d', h, m, sec) end
    return string.format('%d:%02d', m, sec)
end

-- Overall fraction 0..1: sections before idx are done, section idx is
-- frac done. weights[key] defaults to 1.
function Pure.overallProgress(weights, keys, idx, frac)
    local total, done = 0, 0
    for i, key in ipairs(keys) do
        local w = weights[key] or 1
        total = total + w
        if i < idx then
            done = done + w
        elseif i == idx then
            done = done + w * math.clamp(frac or 0, 0, 1)
        end
    end
    if total <= 0 then return 0 end
    return done / total
end

-- Remaining seconds from elapsed time and progress; nil until enough
-- progress exists for a stable estimate.
function Pure.eta(elapsed, progress)
    if progress < 0.02 or elapsed < 1 then return nil end
    return elapsed * (1 - progress) / progress
end

-- <<< PURE

return function(State, Tabs, Services, Library)

local RunService        = Services.RunService
local Players           = Services.Players
local CollectionService = Services.CollectionService
local LocalPlayer       = Services.LocalPlayer

local array, encodeJson = Pure.array, Pure.encode

-- ================================================================
--  CONFIG (limits only; nothing here is build-dependent)
-- ================================================================

local LIMITS = {
    YieldEvery          = 250,
    MaxString           = 400,
    TreeMaxGroups       = 120,
    TreeMaxNodes        = 60000,
    TreeAttrs           = 24,
    TreeDepth = {
        Workspace = 5, ReplicatedStorage = 9, ReplicatedFirst = 6,
        StarterPlayer = 6, StarterGui = 6, StarterPack = 4,
        Lighting = 2, Teams = 2, SoundService = 2, Players = 6,
    },
    MaxScripts          = 3000,
    DecompileTimeout    = 12,
    MaxCallSitesPerScript = 200,
    MaxCallSiteText     = 240,
    MaxMentionsPerRemote = 60,
    MaxGcFunctions      = 40000,
    MaxConstants        = 96,
    MaxUpvalues         = 40,
    MaxUpvalueTableKeys = 24,
    MaxProtos           = 64,
    ModuleDepth         = 5,
    ModuleKeys          = 200,
    ModuleArrayShown    = 4,
    RequireTimeout      = 4,
    MaxHudTexts         = 800,
    MaxTagSamples       = 8,
    MaxNpcGroups        = 300,
    MaxPrompts          = 2000,
    MaxPlayingTracksHumanoids = 200,
    MaxAnimations       = 5000,
    EnvDepth            = 3,
    EnvKeys             = 300,
}

local ROOT_NAMES = {
    'Workspace', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterGui',
    'StarterPack', 'StarterPlayer', 'Players', 'Lighting', 'Teams', 'SoundService',
}

local SCRIPT_ROOT_NAMES = { 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer', 'StarterGui', 'StarterPack', 'Workspace' }

-- Roblox's own client scripts; excluded unless the toggle is on.
local CORE_SCRIPT_ANCESTORS = { PlayerModule = true, RbxCharacterSounds = true, ChatScript = true, BubbleChat = true }

local CALLSITE_NEEDLES = {
    'FireServer', 'InvokeServer', 'OnClientEvent', 'OnClientInvoke',
    ':Fire(', ':Invoke(', 'OnInvoke', '.Event:', 'require(',
}

local REMOTE_CLASSES = {
    RemoteEvent = true, UnreliableRemoteEvent = true, RemoteFunction = true,
    BindableEvent = true, BindableFunction = true,
}

local CAPABILITY_NAMES = {
    'decompile', 'getgc', 'getconnections', 'getcallbackvalue', 'getscripthash',
    'getscriptbytecode', 'getnilinstances', 'getloadedmodules', 'getscripts',
    'getrunningscripts', 'getsenv', 'getrenv', 'getgenv', 'getrawmetatable',
    'hookmetamethod', 'getnamecallmethod', 'islclosure', 'iscclosure',
    'isexecutorclosure', 'checkcaller', 'gethiddenproperty', 'getupvalues',
    'getconstants', 'getprotos', 'getinfo', 'writefile', 'makefolder',
    'isfolder', 'appendfile', 'setclipboard', 'identifyexecutor', 'cloneref',
}

-- ================================================================
--  CAPABILITY RESOLVER
--  Looks a name up in this env, getgenv(), then the debug library.
-- ================================================================

local genv
if type(getgenv) == 'function' then
    local ok, e = pcall(getgenv)
    if ok and type(e) == 'table' then genv = e end
end
local fenv = getfenv(1)

local function cap(...)
    for _, name in ipairs({ ... }) do
        local value
        local lib, field = name:match('^(%w+)%.(%w+)$')
        if lib then
            local t = fenv[lib] or (genv and genv[lib])
            if type(t) == 'table' then value = t[field] end
        else
            value = fenv[name]
            if value == nil and genv then value = genv[name] end
        end
        if value ~= nil then return value end
    end
    return nil
end

local X = {
    decompile         = cap('decompile'),
    getgc             = cap('getgc'),
    getconnections    = cap('getconnections', 'get_signal_cons'),
    getcallbackvalue  = cap('getcallbackvalue'),
    getscripthash     = cap('getscripthash'),
    getnilinstances   = cap('getnilinstances', 'get_nil_instances'),
    getloadedmodules  = cap('getloadedmodules', 'get_loaded_modules'),
    getscripts        = cap('getscripts', 'get_scripts'),
    getrenv           = cap('getrenv'),
    islclosure        = cap('islclosure', 'is_l_closure'),
    isexecutorclosure = cap('isexecutorclosure', 'is_synapse_function', 'isourclosure', 'checkclosure'),
    getconstants      = cap('debug.getconstants', 'getconstants'),
    getupvalues       = cap('debug.getupvalues', 'getupvalues'),
    getprotos         = cap('debug.getprotos', 'getprotos'),
    identifyexecutor  = cap('identifyexecutor', 'getexecutorname'),
    writefile         = cap('writefile'),
    makefolder        = cap('makefolder'),
    isfolder          = cap('isfolder'),
}

local debugInfo = type(debug) == 'table' and debug.info or nil

-- ================================================================
--  FILESYSTEM (lazy; nothing runs at load time)
-- ================================================================

local FOLDER_ROOT = 'YazuDumper'
local session = nil -- { folder, scriptsReady, written = {} }

local function newSession(single)
    local stamp = tostring(game.PlaceId) .. '_' .. tostring(os.time())
    session = {
        folder  = FOLDER_ROOT .. '/Universal_' .. stamp,
        bundle  = FOLDER_ROOT .. '/Universal_' .. stamp .. '.txt',
        single  = single,
        parts   = {},
        ready   = false,
        scripts = false,
        written = {},
    }
end

local function ensureFolder(path)
    if type(X.isfolder) == 'function' then
        local ok, exists = pcall(X.isfolder, path)
        if ok and exists then return true end
    end
    local ok, err = pcall(X.makefolder, path)
    if not ok then return false, err end
    return true
end

local function writeOut(relName, text)
    if type(X.writefile) ~= 'function' or type(X.makefolder) ~= 'function' then
        return nil, 'writefile/makefolder not supported on this executor'
    end
    if session.single then
        -- Single-file mode: keep in memory, flushBundle writes one file.
        session.parts[#session.parts + 1] = { name = relName, text = text }
        session.written[#session.written + 1] = relName
        return session.bundle .. '#' .. relName
    end
    if not session.ready then
        local ok, err = ensureFolder(FOLDER_ROOT)
        if ok then ok, err = ensureFolder(session.folder) end
        if not ok then return nil, 'folder creation failed: ' .. tostring(err) end
        session.ready = true
    end
    if relName:sub(1, 8) == 'scripts/' and not session.scripts then
        local ok, err = ensureFolder(session.folder .. '/scripts')
        if not ok then return nil, 'scripts folder creation failed: ' .. tostring(err) end
        session.scripts = true
    end
    local path = session.folder .. '/' .. relName
    local ok, err = pcall(X.writefile, path, text)
    if not ok then return nil, 'write error: ' .. tostring(err) end
    session.written[#session.written + 1] = relName
    return path
end

local function writeJson(relName, data)
    local ok, text = pcall(encodeJson, data)
    if not ok then return nil, 'json encode failed: ' .. tostring(text) end
    return writeOut(relName, text)
end

-- ================================================================
--  GENERIC HELPERS
-- ================================================================

local paceCount = 0
local function pace()
    paceCount = paceCount + 1
    if paceCount % LIMITS.YieldEvery == 0 then
        RunService.Heartbeat:Wait()
    end
end

local function prop(inst, name)
    local ok, value = pcall(function() return inst[name] end)
    if ok then return value end
    return nil
end

local function getService(name)
    local ok, svc = pcall(game.GetService, game, name)
    if ok then return svc end
    return nil
end

local function getRoots(names)
    local roots = {}
    for _, name in ipairs(names) do
        local svc = getService(name)
        if svc then roots[#roots + 1] = svc end
    end
    return roots
end

local function isA(inst, className)
    local ok, r = pcall(inst.IsA, inst, className)
    return ok and r
end

-- Full path; instances outside the DataModel are prefixed with <nil>.
local function pathOf(inst)
    local ok, full = pcall(inst.GetFullName, inst)
    if not ok then return '<destroyed>' end
    local inGame = false
    pcall(function() inGame = inst == game or inst:IsDescendantOf(game) end)
    if inGame then return full end
    return '<nil>.' .. full
end

local function eachDescendant(roots, fn)
    local skipped, firstErr = 0, nil
    for _, root in ipairs(roots) do
        local ok, list = pcall(root.GetDescendants, root)
        if ok then
            for _, inst in ipairs(list) do
                local callOk, err = pcall(fn, inst)
                if not callOk then
                    skipped = skipped + 1
                    if not firstErr then firstErr = tostring(err) end
                end
                pace()
            end
        end
    end
    return skipped, firstErr
end

local function nilInstances()
    if type(X.getnilinstances) ~= 'function' then return {} end
    local ok, list = pcall(X.getnilinstances)
    if ok and type(list) == 'table' then return list end
    return {}
end

local function runWithTimeout(seconds, fn, ...)
    local args = table.pack(...)
    local done, ok, result = false, false, nil
    task.spawn(function()
        ok, result = pcall(fn, table.unpack(args, 1, args.n))
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < seconds do
        RunService.Heartbeat:Wait()
    end
    if not done then return false, 'timed out after ' .. seconds .. 's' end
    return ok, result
end

-- ================================================================
--  VALUE CONVERSION (engine types to tagged JSON)
-- ================================================================

local function r4(n) return math.floor(n * 10000 + 0.5) / 10000 end

local TYPE_HANDLERS = {
    Vector3 = function(v) return { t = 'Vector3', v = array({ r4(v.X), r4(v.Y), r4(v.Z) }) } end,
    Vector2 = function(v) return { t = 'Vector2', v = array({ r4(v.X), r4(v.Y) }) } end,
    Vector3int16 = function(v) return { v = array({ v.X, v.Y, v.Z }) } end,
    CFrame = function(v)
        local c = { v:GetComponents() }
        for i = 1, #c do c[i] = r4(c[i]) end
        return { t = 'CFrame', v = array(c) }
    end,
    Color3 = function(v) return { t = 'Color3', v = array({ r4(v.R), r4(v.G), r4(v.B) }), hex = v:ToHex() } end,
    BrickColor = function(v) return { t = 'BrickColor', name = v.Name, n = v.Number } end,
    UDim = function(v) return { v = array({ r4(v.Scale), v.Offset }) } end,
    UDim2 = function(v) return { v = array({ r4(v.X.Scale), v.X.Offset, r4(v.Y.Scale), v.Y.Offset }) } end,
    NumberRange = function(v) return { v = array({ v.Min, v.Max }) } end,
    Rect = function(v) return { v = array({ v.Min.X, v.Min.Y, v.Max.X, v.Max.Y }) } end,
    EnumItem = function(v) return { t = 'EnumItem', s = tostring(v), n = v.Value } end,
    Enum = function(v) return { s = tostring(v) } end,
    Instance = function(v)
        local ok, cls = pcall(function() return v.ClassName end)
        return { t = 'Instance', class = ok and cls or '?', path = pathOf(v) }
    end,
    NumberSequence = function(v)
        local k = {}
        for _, kp in ipairs(v.Keypoints) do k[#k + 1] = array({ r4(kp.Time), r4(kp.Value), r4(kp.Envelope) }) end
        return { v = array(k) }
    end,
    ColorSequence = function(v)
        local k = {}
        for _, kp in ipairs(v.Keypoints) do k[#k + 1] = array({ r4(kp.Time), kp.Value:ToHex() }) end
        return { v = array(k) }
    end,
    TweenInfo = function(v)
        return { time = v.Time, style = tostring(v.EasingStyle), dir = tostring(v.EasingDirection),
                 repeats = v.RepeatCount, reverses = v.Reverses, delay = v.DelayTime }
    end,
    RBXScriptSignal = function(v) return { s = tostring(v) } end,
    buffer = function(v) return { len = buffer.len(v) } end,
}

local function tag(v)
    return Pure.tagValue(v, typeof, TYPE_HANDLERS, LIMITS.MaxString)
end

local function attributesOf(inst, limit)
    local ok, attrs = pcall(inst.GetAttributes, inst)
    if not ok or type(attrs) ~= 'table' then return nil end
    local keys = {}
    for k in pairs(attrs) do keys[#keys + 1] = k end
    if #keys == 0 then return nil end
    table.sort(keys)
    local out = {}
    for i = 1, math.min(#keys, limit) do out[keys[i]] = tag(attrs[keys[i]]) end
    if #keys > limit then out['__more'] = #keys - limit end
    return out
end

local function tagsOf(inst)
    local ok, list = pcall(CollectionService.GetTags, CollectionService, inst)
    if ok and type(list) == 'table' and #list > 0 then return array(list) end
    return nil
end

-- ================================================================
--  FUNCTION INSPECTION (debug.info first, executor debug second)
-- ================================================================

local function isExecutorFn(f)
    if type(X.isexecutorclosure) ~= 'function' then return false end
    local ok, r = pcall(X.isexecutorclosure, f)
    return ok and r == true
end

local function isLuaFn(f)
    if type(X.islclosure) == 'function' then
        local ok, r = pcall(X.islclosure, f)
        if ok then return r == true end
    end
    if debugInfo then
        local ok, src = pcall(debugInfo, f, 's')
        if ok then return src ~= '[C]' end
    end
    return true
end

local function fnBasics(f)
    local rec = {}
    if debugInfo then
        local ok, src, line, name = pcall(debugInfo, f, 'sln')
        if ok then
            rec.source, rec.line = src, line
            if name and name ~= '' then rec.name = name end
        end
        local ok2, nparams, vararg = pcall(debugInfo, f, 'a')
        if ok2 then rec.params, rec.vararg = nparams, vararg end
    end
    return rec
end

local function shallowTableShape(t)
    local keys, count = {}, 0
    for k in pairs(t) do
        count = count + 1
        if #keys < LIMITS.MaxUpvalueTableKeys then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    return { t = 'table', count = count, keys = array(keys) }
end

local function inspectFunction(f, deep)
    local rec = fnBasics(f)
    if not deep then return rec end
    if type(X.getconstants) == 'function' then
        local ok, consts = pcall(X.getconstants, f)
        if ok and type(consts) == 'table' then
            local out, n = {}, 0
            for _, c in pairs(consts) do
                local ct = type(c)
                if ct == 'string' or ct == 'number' or ct == 'boolean' then
                    n = n + 1
                    if n > LIMITS.MaxConstants then break end
                    out[#out + 1] = tag(c)
                end
            end
            rec.constants = array(out)
        end
    end
    if type(X.getupvalues) == 'function' then
        local ok, ups = pcall(X.getupvalues, f)
        if ok and type(ups) == 'table' then
            local out, n = {}, 0
            for _, u in pairs(ups) do
                n = n + 1
                if n > LIMITS.MaxUpvalues then break end
                if type(u) == 'table' then
                    out[#out + 1] = shallowTableShape(u)
                elseif type(u) == 'function' then
                    local b = fnBasics(u)
                    b.t = 'function'
                    out[#out + 1] = b
                else
                    out[#out + 1] = tag(u)
                end
            end
            rec.upvalues = array(out)
        end
    end
    if type(X.getprotos) == 'function' then
        local ok, protos = pcall(X.getprotos, f)
        if ok and type(protos) == 'table' then
            local out = {}
            for i, p in ipairs(protos) do
                if i > LIMITS.MaxProtos then break end
                if type(p) == 'function' then out[#out + 1] = fnBasics(p) end
            end
            rec.protos = array(out)
        end
    end
    return rec
end

-- Script instance that owns a closure, via its environment.
local function scriptOfFn(f)
    local ok, env = pcall(getfenv, f)
    if ok and type(env) == 'table' then
        local s = rawget(env, 'script')
        if typeof(s) == 'Instance' then return s end
    end
    return nil
end

-- ================================================================
--  SECTION: tree
-- ================================================================

local function treeNode(inst, depth, maxDepth, budget)
    budget.n = budget.n + 1
    local node = { n = inst.Name, c = inst.ClassName }
    if isA(inst, 'ValueBase') then node.v = tag(prop(inst, 'Value')) end
    node.a = attributesOf(inst, LIMITS.TreeAttrs)
    node.tags = tagsOf(inst)
    local okKids, children = pcall(inst.GetChildren, inst)
    if not okKids or #children == 0 then return node end
    if depth >= maxDepth or budget.n >= LIMITS.TreeMaxNodes or inst.ClassName == 'Terrain' then
        node.unexpanded = #children
        return node
    end
    local groups, order = {}, {}
    for _, child in ipairs(children) do
        local okKey, key = pcall(Pure.groupKey, child.ClassName, child.Name)
        if okKey then
            local g = groups[key]
            if not g then
                g = { first = child, count = 0 }
                groups[key] = g
                order[#order + 1] = key
            end
            g.count = g.count + 1
        end
    end
    table.sort(order)
    local kids = {}
    for i, key in ipairs(order) do
        if i > LIMITS.TreeMaxGroups then
            node.moreGroups = #order - LIMITS.TreeMaxGroups
            break
        end
        local g = groups[key]
        local okChild, child = pcall(treeNode, g.first, depth + 1, maxDepth, budget)
        if okChild then
            if g.count > 1 then child.x = g.count end
            kids[#kids + 1] = child
        end
        pace()
    end
    node.k = array(kids)
    return node
end

local function sectionTree(ctx)
    local budget = { n = 0 }
    local roots = {}
    for ti, name in ipairs(ROOT_NAMES) do
        ctx.progress(ti - 1, #ROOT_NAMES, name)
        local svc = not ctx.cancelled() and getService(name)
        if svc then
            local depth = LIMITS.TreeDepth[name] or 3
            local ok, node = pcall(treeNode, svc, 0, depth, budget)
            roots[#roots + 1] = ok and node or { n = name, error = tostring(node) }
        end
    end
    local nils = {}
    for _, inst in ipairs(nilInstances()) do
        local ok, node = pcall(treeNode, inst, 0, 2, budget)
        if ok then nils[#nils + 1] = node end
        pace()
    end
    ctx.count = budget.n
    ctx.truncated = budget.n >= LIMITS.TreeMaxNodes
    return 'tree.json', {
        schema = 'n=name c=class v=value a=attributes tags k=children x=identical-sibling-count (first expanded) unexpanded=child count not walked',
        depthByRoot = LIMITS.TreeDepth,
        roots = array(roots),
        nilParented = array(nils),
    }
end

-- ================================================================
--  SECTION: scripts (decompile, hash, call sites)
--  Runs before remotes so call sites can be joined to remotes.
-- ================================================================

local function hasCoreAncestor(inst)
    local node = inst
    while node and node ~= game do
        if CORE_SCRIPT_ANCESTORS[node.Name] then return true end
        node = node.Parent
    end
    return false
end

local function toggleOn(name)
    return Toggles and Toggles[name] and Toggles[name].Value == true
end

local function collectScripts()
    local includeCore = toggleOn('UD_IncludeCore')
    local list, seen = {}, {}
    local function add(inst, origin)
        if typeof(inst) ~= 'Instance' or seen[inst] then return end
        if not (isA(inst, 'LocalScript') or isA(inst, 'ModuleScript')) then return end
        if isA(inst, 'Script') and not isA(inst, 'LocalScript') then return end
        if not includeCore and hasCoreAncestor(inst) then return end
        seen[inst] = true
        list[#list + 1] = { inst = inst, origin = origin }
    end
    local roots = getRoots(SCRIPT_ROOT_NAMES)
    if LocalPlayer then roots[#roots + 1] = LocalPlayer end
    eachDescendant(roots, function(inst) add(inst, 'tree') end)
    for _, inst in ipairs(nilInstances()) do
        add(inst, 'nil')
        pcall(function() for _, d in ipairs(inst:GetDescendants()) do add(d, 'nil') end end)
    end
    if type(X.getloadedmodules) == 'function' then
        local ok, mods = pcall(X.getloadedmodules)
        if ok and type(mods) == 'table' then for _, m in ipairs(mods) do add(m, 'loadedmodules') end end
    end
    if type(X.getscripts) == 'function' then
        local ok, scripts = pcall(X.getscripts)
        if ok and type(scripts) == 'table' then for _, s in ipairs(scripts) do add(s, 'getscripts') end end
    end
    local kept = {}
    for _, e in ipairs(list) do
        e.path = pathOf(e.inst)
        if includeCore or not Pure.isCorePath(e.path) then kept[#kept + 1] = e end
    end
    table.sort(kept, function(a, b) return a.path < b.path end)
    return kept, #list - #kept
end

local function remoteNames()
    local names, seen = {}, {}
    local function consider(inst)
        if REMOTE_CLASSES[inst.ClassName] and not seen[inst.Name] then
            seen[inst.Name] = true
            names[#names + 1] = inst.Name
        end
    end
    eachDescendant(getRoots(ROOT_NAMES), consider)
    for _, inst in ipairs(nilInstances()) do pcall(consider, inst) end
    -- Longest first so "DamageRequest" wins over "Damage" on the same line.
    table.sort(names, function(a, b) return #a > #b end)
    return names
end

local function sectionScripts(ctx)
    ctx.progress(0, 1, 'collecting scripts')
    local list, coreSkipped = collectScripts()
    ctx.coreSkipped = coreSkipped
    local names = remoteNames()
    ctx.mentions = {}
    local canDecompile = type(X.decompile) == 'function'
    if not canDecompile then
        ctx.note = 'decompile() missing: index and hashes only, no sources or call sites'
    end
    local taken, index = {}, {}
    local decompiled, failed = 0, 0
    local total = math.min(#list, LIMITS.MaxScripts)
    for i, e in ipairs(list) do
        if i > LIMITS.MaxScripts then
            ctx.truncated = true
            break
        end
        if ctx.cancelled() then break end
        ctx.progress(i - 1, total, e.path)
        local rec = { path = e.path, class = e.inst.ClassName, origin = e.origin }
        if isA(e.inst, 'LocalScript') then rec.enabled = prop(e.inst, 'Enabled') end
        if type(X.getscripthash) == 'function' then
            local ok, h = pcall(X.getscripthash, e.inst)
            if ok then rec.hash = h end
        end
        if canDecompile then
            local ok, src = runWithTimeout(LIMITS.DecompileTimeout, X.decompile, e.inst)
            if ok and type(src) == 'string' and #src > 0 then
                decompiled = decompiled + 1
                local file = 'scripts/' .. Pure.safeFileName(e.path, taken) .. '.lua'
                local header = '-- path:   ' .. e.path .. '\n-- class:  ' .. rec.class ..
                    '\n-- hash:   ' .. tostring(rec.hash) .. '\n-- origin: ' .. e.origin .. '\n\n'
                local written, err = writeOut(file, header .. src)
                rec.file = written and file or nil
                rec.writeError = err
                rec.bytes = #src
                rec.headerLines = 5
                local hits, cut = Pure.findLines(src, CALLSITE_NEEDLES, LIMITS.MaxCallSitesPerScript, LIMITS.MaxCallSiteText)
                rec.callSites = hits
                rec.callSitesCut = cut or nil
                if #names > 0 then
                    local m = Pure.findLines(src, names, LIMITS.MaxCallSitesPerScript, LIMITS.MaxCallSiteText)
                    for _, h in ipairs(m) do
                        local bucket = ctx.mentions[h.match]
                        if not bucket then
                            bucket = {}
                            ctx.mentions[h.match] = bucket
                        end
                        if #bucket < LIMITS.MaxMentionsPerRemote then
                            bucket[#bucket + 1] = { script = e.path, line = h.line, text = h.text }
                        end
                    end
                end
            else
                failed = failed + 1
                rec.decompileError = ok and 'empty result' or tostring(src)
            end
        end
        index[#index + 1] = rec
        if i % 4 == 0 then RunService.Heartbeat:Wait() end
    end
    ctx.count = #index
    return 'scripts.json', {
        note = 'callSites line numbers refer to the decompiled source; add headerLines to get the line in scripts/*.lua',
        decompiler = canDecompile,
        found = #list, decompiled = decompiled, failed = failed,
        coreScriptsSkipped = coreSkipped,
        scripts = array(index),
    }
end

-- ================================================================
--  SECTION: remotes (+ bindables, handlers, joined call sites)
-- ================================================================

local function handlersOf(signal)
    if type(X.getconnections) ~= 'function' then return nil end
    local ok, conns = pcall(X.getconnections, signal)
    if not ok or type(conns) ~= 'table' then return nil end
    local out = {}
    for _, c in ipairs(conns) do
        local rec = {}
        pcall(function() rec.enabled = c.Enabled end)
        pcall(function() rec.foreign = c.ForeignState end)
        local okF, f = pcall(function() return c.Function end)
        if okF and type(f) == 'function' then
            local okI, info = pcall(inspectFunction, f, true)
            if okI then rec.fn = info end
            local s = scriptOfFn(f)
            if s then rec.script = pathOf(s) end
        else
            rec.fn = 'none (C connection or hidden)'
        end
        out[#out + 1] = rec
    end
    return array(out)
end

local function sectionRemotes(ctx, shared)
    local found, seen = {}, {}
    local function consider(inst)
        if not seen[inst] and REMOTE_CLASSES[inst.ClassName] then
            seen[inst] = true
            found[#found + 1] = inst
        end
    end
    local skipped = eachDescendant(getRoots(ROOT_NAMES), consider)
    for _, inst in ipairs(nilInstances()) do
        pcall(consider, inst)
        pcall(function() for _, d in ipairs(inst:GetDescendants()) do consider(d) end end)
    end

    local mentions = shared.mentions or {}
    local out = {}
    for ri, inst in ipairs(found) do
        if ctx.cancelled() then break end
        ctx.progress(ri - 1, #found, inst.Name)
        local rec = {
            path = pathOf(inst), class = inst.ClassName, name = inst.Name,
            attributes = attributesOf(inst, 32),
        }
        local cls = inst.ClassName
        if cls == 'RemoteEvent' or cls == 'UnreliableRemoteEvent' then
            rec.onClientEvent = handlersOf(inst.OnClientEvent)
        elseif cls == 'BindableEvent' then
            rec.event = handlersOf(inst.Event)
        end
        if (cls == 'RemoteFunction' or cls == 'BindableFunction') and type(X.getcallbackvalue) == 'function' then
            local member = cls == 'RemoteFunction' and 'OnClientInvoke' or 'OnInvoke'
            local ok, cb = pcall(X.getcallbackvalue, inst, member)
            if ok and type(cb) == 'function' then
                rec[member] = inspectFunction(cb, true)
                local s = scriptOfFn(cb)
                if s then rec[member].script = pathOf(s) end
            elseif ok then
                rec[member] = 'not set'
            end
        end
        local mine = mentions[inst.Name]
        if mine and #mine > 0 then rec.mentions = array(mine) end
        out[#out + 1] = rec
        pace()
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    ctx.count = #out
    return 'remotes.json', {
        note = 'mentions = decompiled lines that contain the remote name (where scripts look it up; follow the variable to the FireServer line in scripts/*.lua). Remotes sharing a name share mentions. Filled only when the scripts section ran in the same dump.',
        getconnections = type(X.getconnections) == 'function',
        getcallbackvalue = type(X.getcallbackvalue) == 'function',
        skippedInstances = skipped,
        remotes = array(out),
    }
end

-- ================================================================
--  SECTION: gc (game closures)
-- ================================================================

local function sectionGc(ctx)
    if type(X.getgc) ~= 'function' then
        ctx.status, ctx.reason = 'skipped', 'getgc() missing'
        return nil
    end
    local ok, objects = pcall(X.getgc, false)
    if not ok or type(objects) ~= 'table' then
        ctx.status, ctx.reason = 'failed', 'getgc() error: ' .. tostring(objects)
        return nil
    end
    local deep = type(X.getconstants) == 'function' or type(X.getupvalues) == 'function'
    local byScript, scriptOrder, total, executorSkipped = {}, {}, 0, 0
    local includeCore = toggleOn('UD_IncludeCore')
    local coreSkipped = 0
    for gi, f in ipairs(objects) do
        if gi % 500 == 0 then
            if ctx.cancelled() then break end
            ctx.progress(gi, #objects, 'closure ' .. gi .. ' / ' .. #objects)
        end
        if type(f) == 'function' and isLuaFn(f) then
            if isExecutorFn(f) then
                executorSkipped = executorSkipped + 1
            else
                -- The chunk name is the script's full name. getfenv is only a
                -- fallback because it turns off Luau's env optimizations
                -- for every function sharing that environment.
                local key
                if debugInfo then
                    local okS, src = pcall(debugInfo, f, 's')
                    if okS and type(src) == 'string' and src ~= '' then key = src end
                end
                if not key then
                    local s = scriptOfFn(f)
                    if s then key = pathOf(s) end
                end
                if key and not includeCore and Pure.isCorePath(key) then
                    coreSkipped = coreSkipped + 1
                    key = nil
                end
                if key then
                    total = total + 1
                    if total > LIMITS.MaxGcFunctions then
                        ctx.truncated = true
                        break
                    end
                    local bucket = byScript[key]
                    if not bucket then
                        bucket = {}
                        byScript[key] = bucket
                        scriptOrder[#scriptOrder + 1] = key
                    end
                    local okI, info = pcall(inspectFunction, f, deep)
                    if okI then
                        info.source = nil
                        bucket[#bucket + 1] = info
                    end
                end
            end
        end
        pace()
    end
    table.sort(scriptOrder)
    local scripts = {}
    for _, key in ipairs(scriptOrder) do
        local fns = byScript[key]
        table.sort(fns, function(a, b) return (a.line or 0) < (b.line or 0) end)
        scripts[#scripts + 1] = { script = key, functions = array(fns) }
    end
    ctx.count = total
    return 'gc.json', {
        note = 'Lua closures alive at dump time, grouped by chunk name (the owning script full name at load time). Only functions the game created; executor closures are skipped when isexecutorclosure exists. Constants and upvalues are values at dump time.',
        deepInspection = deep,
        executorClosuresSkipped = executorSkipped,
        coreClosuresSkipped = coreSkipped,
        isexecutorclosure = type(X.isexecutorclosure) == 'function',
        scripts = array(scripts),
    }
end

-- ================================================================
--  SECTION: modules
-- ================================================================

local shape
shape = function(value, depth, seen)
    if type(value) == 'function' then
        local b = fnBasics(value)
        b.t = 'function'
        b.source = nil
        return b
    end
    if type(value) ~= 'table' then return tag(value) end
    if seen[value] then return { t = 'table', ref = 'shown above' } end
    seen[value] = true
    local arrayLen = #value
    local keys = {}
    for k in pairs(value) do
        if not (type(k) == 'number' and k >= 1 and k <= arrayLen and k % 1 == 0) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local rec = { t = 'table', arrayLen = arrayLen, keyCount = #keys }
    local mt = getmetatable(value)
    if type(mt) == 'table' then rec.hasMetatable = true end
    if depth >= LIMITS.ModuleDepth then return rec end
    if arrayLen > 0 then
        local items = {}
        for i = 1, math.min(arrayLen, LIMITS.ModuleArrayShown) do items[i] = shape(value[i], depth + 1, seen) end
        rec.items = array(items)
    end
    local fields = {}
    for i, k in ipairs(keys) do
        if i > LIMITS.ModuleKeys then
            rec.moreKeys = #keys - LIMITS.ModuleKeys
            break
        end
        fields[tostring(k)] = shape(value[k], depth + 1, seen)
    end
    if #keys > 0 then rec.fields = fields end
    return rec
end

local function sectionModules(ctx)
    local requireAll = toggleOn('UD_RequireAll')
    local loaded = {}
    if type(X.getloadedmodules) == 'function' then
        local ok, mods = pcall(X.getloadedmodules)
        if ok and type(mods) == 'table' then for _, m in ipairs(mods) do loaded[m] = true end end
    end
    local targets, seen = {}, {}
    local function add(m)
        if typeof(m) == 'Instance' and not seen[m] and isA(m, 'ModuleScript') then
            if requireAll or loaded[m] then
                if toggleOn('UD_IncludeCore') or not (hasCoreAncestor(m) or Pure.isCorePath(pathOf(m))) then
                    seen[m] = true
                    targets[#targets + 1] = m
                end
            end
        end
    end
    for m in pairs(loaded) do add(m) end
    if requireAll then
        eachDescendant(getRoots({ 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer' }), add)
        if LocalPlayer then eachDescendant({ LocalPlayer }, add) end
    end
    if #targets == 0 and not requireAll and type(X.getloadedmodules) ~= 'function' then
        ctx.status, ctx.reason = 'skipped', 'getloadedmodules() missing; turn on "Require unloaded modules" to require every module instead'
        return nil
    end
    local entries = {}
    for mi, m in ipairs(targets) do
        if ctx.cancelled() then break end
        ctx.progress(mi - 1, #targets, pathOf(m))
        local rec = { path = pathOf(m), alreadyLoaded = loaded[m] == true }
        local ok, result = runWithTimeout(LIMITS.RequireTimeout, require, m)
        if ok then
            local okS, s = pcall(shape, result, 0, {})
            rec.returns = okS and s or ('shape failed: ' .. tostring(s))
        else
            rec.error = tostring(result)
        end
        entries[#entries + 1] = rec
        if mi % 4 == 0 then RunService.Heartbeat:Wait() end
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    ctx.count = #entries
    return 'modules.json', {
        note = requireAll and 'Required every ModuleScript found (unloaded ones ran their code now).'
            or 'Only modules the game already required (cached return values; no new code ran).',
        modules = array(entries),
    }
end

-- ================================================================
--  SECTION: player
-- ================================================================

local function valuesUnder(root, limit)
    local out = {}
    eachDescendant({ root }, function(inst)
        if #out >= limit then return end
        if inst:IsA('ValueBase') then
            out[#out + 1] = { path = pathOf(inst), class = inst.ClassName, v = tag(prop(inst, 'Value')), a = attributesOf(inst, 16) }
        end
    end)
    return array(out)
end

local function sectionPlayer(ctx)
    if not LocalPlayer then
        ctx.status, ctx.reason = 'skipped', 'no LocalPlayer'
        return nil
    end
    local data = {
        userId = LocalPlayer.UserId, name = LocalPlayer.Name, displayName = LocalPlayer.DisplayName,
        team = LocalPlayer.Team and LocalPlayer.Team.Name or nil,
        attributes = attributesOf(LocalPlayer, 200),
        values = valuesUnder(LocalPlayer, 3000),
    }
    local char = LocalPlayer.Character
    if char then
        local c = { path = pathOf(char), attributes = attributesOf(char, 200), tags = tagsOf(char) }
        local hum = char:FindFirstChildOfClass('Humanoid')
        if hum then
            c.humanoid = {
                health = hum.Health, maxHealth = hum.MaxHealth, walkSpeed = hum.WalkSpeed,
                jumpPower = prop(hum, 'JumpPower'), jumpHeight = prop(hum, 'JumpHeight'),
                useJumpPower = prop(hum, 'UseJumpPower'), hipHeight = hum.HipHeight,
                rigType = tostring(hum.RigType), state = tostring(hum:GetState()),
                attributes = attributesOf(hum, 64),
            }
        end
        local parts = {}
        for _, d in ipairs(char:GetChildren()) do
            parts[#parts + 1] = { n = d.Name, c = d.ClassName, a = attributesOf(d, 16) }
        end
        c.children = array(parts)
        c.values = valuesUnder(char, 500)
        data.character = c
    end
    local backpack = LocalPlayer:FindFirstChildOfClass('Backpack')
    local tools = {}
    local function addTool(t, where)
        tools[#tools + 1] = { name = t.Name, where = where, toolTip = prop(t, 'ToolTip'),
            attributes = attributesOf(t, 64), values = valuesUnder(t, 100) }
    end
    if backpack then for _, t in ipairs(backpack:GetChildren()) do if t:IsA('Tool') then addTool(t, 'backpack') end end end
    if char then for _, t in ipairs(char:GetChildren()) do if t:IsA('Tool') then addTool(t, 'equipped') end end end
    data.tools = array(tools)

    local hud = {}
    local gui = LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if gui then
        eachDescendant({ gui }, function(inst)
            if #hud >= LIMITS.MaxHudTexts then return end
            if inst:IsA('TextLabel') or inst:IsA('TextButton') or inst:IsA('TextBox') then
                local text = prop(inst, 'Text')
                if type(text) == 'string' and text:match('%S') then
                    hud[#hud + 1] = { path = pathOf(inst), text = tag(text), visible = prop(inst, 'Visible') }
                end
            end
        end)
    end
    data.hudText = array(hud)
    ctx.count = #data.values
    return 'player.json', data
end

-- ================================================================
--  SECTION: world (interactables, tags, NPC groups)
-- ================================================================

local function positionOf(inst)
    local p = inst.Parent
    if not p then return nil end
    if p:IsA('BasePart') then return tag(p.Position) end
    if p:IsA('Attachment') then return tag(p.WorldPosition) end
    if p:IsA('Model') then return tag(p:GetPivot().Position) end
    return nil
end

local function sectionWorld(ctx)
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then playerChars[p.Character] = true end
    end
    local prompts, clicks, touchGroups, npcGroups, npcOrder = {}, {}, {}, {}, {}
    eachDescendant({ workspace }, function(inst)
        local cls = inst.ClassName
        if cls == 'ProximityPrompt' and #prompts < LIMITS.MaxPrompts then
            prompts[#prompts + 1] = {
                path = pathOf(inst), actionText = inst.ActionText, objectText = inst.ObjectText,
                holdDuration = inst.HoldDuration, maxDistance = inst.MaxActivationDistance,
                lineOfSight = inst.RequiresLineOfSight, key = tostring(inst.KeyboardKeyCode),
                enabled = inst.Enabled, pos = positionOf(inst), a = attributesOf(inst, 16),
            }
        elseif cls == 'ClickDetector' and #clicks < LIMITS.MaxPrompts then
            clicks[#clicks + 1] = { path = pathOf(inst), maxDistance = inst.MaxActivationDistance, pos = positionOf(inst) }
        elseif cls == 'TouchTransmitter' then
            local parent = inst.Parent
            local key = parent and (parent.Parent and parent.Parent.Name or '?') .. '/' .. parent.Name or '?'
            local g = touchGroups[key]
            if not g then
                g = { key = key, count = 0, sample = pathOf(inst) }
                touchGroups[key] = g
            end
            g.count = g.count + 1
        elseif cls == 'Humanoid' then
            local model = inst.Parent
            if model and not playerChars[model] then
                local key = model.Name .. ' @ ' .. (model.Parent and pathOf(model.Parent) or 'nil')
                local g = npcGroups[key]
                if not g then
                    if #npcOrder >= LIMITS.MaxNpcGroups then return end
                    g = { name = model.Name, container = model.Parent and pathOf(model.Parent) or nil,
                          count = 0, sample = pathOf(model), maxHealth = inst.MaxHealth,
                          walkSpeed = inst.WalkSpeed, attributes = attributesOf(model, 32),
                          humanoidAttributes = attributesOf(inst, 32), tags = tagsOf(model) }
                    npcGroups[key] = g
                    npcOrder[#npcOrder + 1] = key
                end
                g.count = g.count + 1
            end
        end
    end)
    local touches = {}
    for _, g in pairs(touchGroups) do touches[#touches + 1] = g end
    table.sort(touches, function(a, b) return a.count > b.count end)
    local npcs = {}
    for _, key in ipairs(npcOrder) do npcs[#npcs + 1] = npcGroups[key] end
    table.sort(npcs, function(a, b) return a.count > b.count end)

    local tagsOut = {}
    local okT, allTags = pcall(CollectionService.GetAllTags, CollectionService)
    if okT and type(allTags) == 'table' then
        table.sort(allTags)
        for _, tg in ipairs(allTags) do
            local okI, tagged = pcall(CollectionService.GetTagged, CollectionService, tg)
            if okI then
                local samples = {}
                for i = 1, math.min(#tagged, LIMITS.MaxTagSamples) do
                    samples[i] = { path = pathOf(tagged[i]), class = tagged[i].ClassName }
                end
                tagsOut[#tagsOut + 1] = { tag = tg, count = #tagged, samples = array(samples) }
            end
        end
    end

    local okS, streaming = pcall(function() return workspace.StreamingEnabled end)
    ctx.count = #prompts + #clicks + #npcs
    return 'world.json', {
        streamingEnabled = okS and streaming or nil,
        note = 'With StreamingEnabled, only parts near the camera exist on the client; move around and dump again for far areas.',
        proximityPrompts = array(prompts), clickDetectors = array(clicks),
        touchParts = array(touches), npcGroups = array(npcs), collectionTags = array(tagsOut),
    }
end

-- ================================================================
--  SECTION: animations
-- ================================================================

local function sectionAnimations(ctx)
    local byId, order = {}, {}
    local roots = getRoots({ 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer', 'StarterPack', 'Workspace' })
    if LocalPlayer then roots[#roots + 1] = LocalPlayer end
    eachDescendant(roots, function(inst)
        if inst.ClassName == 'Animation' and #order < LIMITS.MaxAnimations then
            local id = tostring(inst.AnimationId)
            local g = byId[id]
            if not g then
                g = { id = id, names = {}, paths = {} }
                byId[id] = g
                order[#order + 1] = id
            end
            g.names[inst.Name] = true
            if #g.paths < 6 then g.paths[#g.paths + 1] = pathOf(inst) end
        end
    end)
    local assets = {}
    table.sort(order)
    for _, id in ipairs(order) do
        local g = byId[id]
        local names = {}
        for n in pairs(g.names) do names[#names + 1] = n end
        table.sort(names)
        assets[#assets + 1] = { id = id, names = array(names), paths = array(g.paths) }
    end

    local playing, humanoids = {}, 0
    eachDescendant({ workspace }, function(inst)
        if inst.ClassName ~= 'Animator' or humanoids >= LIMITS.MaxPlayingTracksHumanoids then return end
        local okT, tracks = pcall(inst.GetPlayingAnimationTracks, inst)
        if okT and #tracks > 0 then
            humanoids = humanoids + 1
            local list = {}
            for _, tr in ipairs(tracks) do
                list[#list + 1] = {
                    name = tr.Name, id = tr.Animation and tostring(tr.Animation.AnimationId) or nil,
                    length = tr.Length, timePosition = tr.TimePosition, speed = tr.Speed,
                    looped = tr.Looped, priority = tostring(tr.Priority), weight = tr.WeightCurrent,
                }
            end
            local owner = inst:FindFirstAncestorOfClass('Model')
            playing[#playing + 1] = { owner = owner and pathOf(owner) or pathOf(inst), tracks = array(list) }
        end
    end)
    ctx.count = #assets
    return 'animations.json', {
        note = 'playing = tracks running at the moment of the dump; perform the action and dump again to catch short ones.',
        assets = array(assets), playing = array(playing),
    }
end

-- ================================================================
--  SECTION: env (game-side _G and shared)
-- ================================================================

local function sectionEnv(ctx)
    if type(X.getrenv) ~= 'function' then
        ctx.status, ctx.reason = 'skipped', 'getrenv() missing'
        return nil
    end
    local ok, renv = pcall(X.getrenv)
    if not ok or type(renv) ~= 'table' then
        ctx.status, ctx.reason = 'failed', 'getrenv() error: ' .. tostring(renv)
        return nil
    end
    local saved = { LIMITS.ModuleDepth, LIMITS.ModuleKeys }
    LIMITS.ModuleDepth, LIMITS.ModuleKeys = LIMITS.EnvDepth, LIMITS.EnvKeys
    local okG, g = pcall(shape, rawget(renv, '_G'), 0, {})
    local okS, s = pcall(shape, rawget(renv, 'shared'), 0, {})
    LIMITS.ModuleDepth, LIMITS.ModuleKeys = saved[1], saved[2]
    ctx.count = 2
    return 'env.json', {
        G = okG and g or tostring(g),
        shared = okS and s or tostring(s),
    }
end

-- ================================================================
--  SECTION TABLE
-- ================================================================

local SECTIONS = {
    tree       = sectionTree,
    scripts    = sectionScripts,
    remotes    = sectionRemotes,
    gc         = sectionGc,
    modules    = sectionModules,
    player     = sectionPlayer,
    world      = sectionWorld,
    animations = sectionAnimations,
    env        = sectionEnv,
}

local FULL_ORDER = { 'scripts', 'remotes', 'gc', 'modules', 'player', 'world', 'animations', 'env', 'tree' }

local function executorInfo()
    local name, ver = 'unknown', ''
    if type(X.identifyexecutor) == 'function' then
        local ok, a, b = pcall(X.identifyexecutor)
        if ok then name, ver = tostring(a), tostring(b or '') end
    end
    local present, missing = {}, {}
    for _, n in ipairs(CAPABILITY_NAMES) do
        local v = cap(n, 'debug.' .. n)
        if v == nil then missing[#missing + 1] = n else present[#present + 1] = n end
    end
    return { name = name, version = ver, present = array(present), missing = array(missing) }
end

-- Writes every buffered part into one text file. manifest.json goes
-- first so the reader sees section status before the bulk.
local function flushBundle()
    local ok, err = ensureFolder(FOLDER_ROOT)
    if not ok then return nil, 'folder creation failed: ' .. tostring(err) end
    local parts = session.parts
    table.sort(parts, function(a, b)
        local am, bm = a.name == 'manifest.json', b.name == 'manifest.json'
        if am ~= bm then return am end
        local as, bs = a.name:sub(1, 8) == 'scripts/', b.name:sub(1, 8) == 'scripts/'
        if as ~= bs then return bs end
        return a.name < b.name
    end)
    local out = {
        '#### YAZU UNIVERSAL DUMP (single file)',
        '#### Each part starts with a line "#### FILE: <name> (<bytes> bytes)" and ends with "#### END FILE: <name>".',
        '#### Parts: ' .. #parts,
        '',
    }
    for _, part in ipairs(parts) do
        out[#out + 1] = '#### FILE: ' .. part.name .. ' (' .. #part.text .. ' bytes)'
        out[#out + 1] = part.text
        out[#out + 1] = '#### END FILE: ' .. part.name
        out[#out + 1] = ''
    end
    local text = table.concat(out, '\n')
    local wok, werr = pcall(X.writefile, session.bundle, text)
    if not wok then return nil, 'write error: ' .. tostring(werr) end
    return session.bundle, #text
end

-- ================================================================
--  OVERLAY (solid screen + progress + ETA while dumping)
-- ================================================================

local UserInputService = Services.UserInputService or game:GetService('UserInputService')

local OVERLAY = {
    Background = Color3.fromRGB(12, 12, 16),
    Panel      = Color3.fromRGB(24, 24, 32),
    Accent     = Color3.fromRGB(255, 120, 190),
    Text       = Color3.fromRGB(235, 235, 245),
    SubText    = Color3.fromRGB(150, 150, 170),
}

local SECTION_WEIGHTS = { scripts = 50, gc = 15, modules = 10, tree = 10, remotes = 6, world = 3, player = 2, animations = 2, env = 1 }

local function overlayParent()
    local gethui = cap('gethui', 'get_hidden_gui')
    if type(gethui) == 'function' then
        local ok, h = pcall(gethui)
        if ok and typeof(h) == 'Instance' then return h end
    end
    local core = getService('CoreGui')
    if core then
        local ok = pcall(function() local probe = Instance.new('Folder'); probe.Parent = core; probe:Destroy() end)
        if ok then return core end
    end
    return LocalPlayer and LocalPlayer:FindFirstChildOfClass('PlayerGui') or nil
end

local function label(parent, props)
    local l = Instance.new('TextLabel')
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamMedium
    l.TextColor3 = OVERLAY.Text
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextTruncate = Enum.TextTruncate.AtEnd
    for k, v in pairs(props) do l[k] = v end
    l.Parent = parent
    return l
end

-- Returns { set(fields), destroy() }. If the GUI cannot be created the
-- methods are no-ops and the dump still runs (Notify is used instead).
local function createOverlay(onCancel)
    local ok, ui = pcall(function()
        local parent = overlayParent()
        if not parent then error('no GUI parent') end
        local gui = Instance.new('ScreenGui')
        gui.Name = 'YazuUniversalDump'
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2147483647
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

        local bg = Instance.new('Frame')
        bg.Size = UDim2.fromScale(1, 1)
        bg.BackgroundColor3 = OVERLAY.Background
        bg.BorderSizePixel = 0
        bg.Active = true
        bg.Parent = gui

        local panel = Instance.new('Frame')
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.Position = UDim2.fromScale(0.5, 0.5)
        panel.Size = UDim2.fromOffset(560, 230)
        panel.BackgroundColor3 = OVERLAY.Panel
        panel.BorderSizePixel = 0
        panel.Parent = bg
        local corner = Instance.new('UICorner'); corner.CornerRadius = UDim.new(0, 10); corner.Parent = panel

        local title   = label(panel, { Text = 'Yazu Universal Dump', TextSize = 22, Position = UDim2.fromOffset(24, 18), Size = UDim2.new(1, -48, 0, 28) })
        local section = label(panel, { Text = 'starting...', TextSize = 16, Position = UDim2.fromOffset(24, 56), Size = UDim2.new(1, -48, 0, 22) })
        local item    = label(panel, { Text = '', TextSize = 13, TextColor3 = OVERLAY.SubText, Position = UDim2.fromOffset(24, 82), Size = UDim2.new(1, -48, 0, 18) })

        local barBg = Instance.new('Frame')
        barBg.Position = UDim2.fromOffset(24, 114)
        barBg.Size = UDim2.new(1, -48, 0, 14)
        barBg.BackgroundColor3 = OVERLAY.Background
        barBg.BorderSizePixel = 0
        barBg.Parent = panel
        local c2 = Instance.new('UICorner'); c2.CornerRadius = UDim.new(0, 7); c2.Parent = barBg
        local fill = Instance.new('Frame')
        fill.Size = UDim2.fromScale(0, 1)
        fill.BackgroundColor3 = OVERLAY.Accent
        fill.BorderSizePixel = 0
        fill.Parent = barBg
        local c3 = Instance.new('UICorner'); c3.CornerRadius = UDim.new(0, 7); c3.Parent = fill

        local timing = label(panel, { Text = '', TextSize = 15, Position = UDim2.fromOffset(24, 138), Size = UDim2.new(1, -48, 0, 20) })
        label(panel, { Text = 'Delete = cancel (files written so far are kept)', TextSize = 12, TextColor3 = OVERLAY.SubText, Position = UDim2.fromOffset(24, 196), Size = UDim2.new(1, -200, 0, 16) })

        local cancel = Instance.new('TextButton')
        cancel.AnchorPoint = Vector2.new(1, 1)
        cancel.Position = UDim2.new(1, -20, 1, -16)
        cancel.Size = UDim2.fromOffset(110, 30)
        cancel.BackgroundColor3 = OVERLAY.Background
        cancel.TextColor3 = OVERLAY.Text
        cancel.Font = Enum.Font.GothamMedium
        cancel.TextSize = 14
        cancel.Text = 'Cancel'
        cancel.AutoButtonColor = true
        cancel.Parent = panel
        local c4 = Instance.new('UICorner'); c4.CornerRadius = UDim.new(0, 6); c4.Parent = cancel

        gui.Parent = parent
        return { gui = gui, title = title, section = section, item = item, fill = fill, timing = timing, cancel = cancel }
    end)

    local conns = {}
    if ok then
        conns[#conns + 1] = ui.cancel.MouseButton1Click:Connect(onCancel)
    end
    if UserInputService then
        conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input)
            if input.KeyCode == Enum.KeyCode.Delete then onCancel() end
        end)
    end

    local overlay = { ok = ok }
    function overlay.set(f)
        if not ok then return end
        pcall(function()
            if f.title then ui.title.Text = f.title end
            if f.section then ui.section.Text = f.section end
            if f.item then ui.item.Text = f.item end
            if f.frac then ui.fill.Size = UDim2.fromScale(math.clamp(f.frac, 0, 1), 1) end
            if f.timing then ui.timing.Text = f.timing end
        end)
    end
    function overlay.destroy()
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        conns = {}
        if ok then pcall(function() ui.gui:Destroy() end) end
    end
    return overlay
end

-- ================================================================
--  RUNNER
-- ================================================================

local busy = false
local cancelRequested = false
local activeCleanup = nil -- restores rendering and removes the overlay

local function setRendering(enabled)
    pcall(function() RunService:Set3dRenderingEnabled(enabled) end)
end

if type(Library.OnUnload) == 'function' then
    Library:OnUnload(function()
        cancelRequested = true
        if activeCleanup then activeCleanup() end
    end)
end

local function runDump(keys)
    if busy then
        Library:Notify('A universal dump is already running')
        return
    end
    busy = true
    cancelRequested = false
    newSession(toggleOn('UD_SingleFile'))

    local overlay = createOverlay(function() cancelRequested = true end)
    local paused3d = toggleOn('UD_Pause3D')
    if paused3d then setRendering(false) end
    local cleaned = false
    activeCleanup = function()
        if cleaned then return end
        cleaned = true
        if paused3d then setRendering(true) end
        overlay.destroy()
        activeCleanup = nil
    end

    task.spawn(function()
        local t0 = os.clock()
        local lastDraw = 0
        local function draw(force, idx, key, frac, item, done, total)
            local now = os.clock()
            if not force and now - lastDraw < 0.1 then return end
            lastDraw = now
            local p = Pure.overallProgress(SECTION_WEIGHTS, keys, idx, frac)
            local elapsed = now - t0
            local eta = Pure.eta(elapsed, p)
            local counts = (done and total and total > 1) and ('  (' .. done .. ' / ' .. total .. ')') or ''
            overlay.set({
                section = string.format('Section %d/%d: %s%s', idx, #keys, key, counts),
                item = item and tostring(item) or '',
                frac = p,
                timing = string.format('%d%%    elapsed %s    ETA %s', math.floor(p * 100),
                    Pure.formatDuration(elapsed), eta and Pure.formatDuration(eta) or 'estimating...'),
            })
        end

        local manifest = {
            tool = 'Yazu universal_dumper', schemaVersion = 2,
            generated = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            placeId = game.PlaceId, gameId = game.GameId, placeVersion = game.PlaceVersion,
            jobId = game.JobId, playerCount = #Players:GetPlayers(),
            executor = executorInfo(), limits = LIMITS,
            includeCoreScripts = toggleOn('UD_IncludeCore'),
            requestedSections = array(keys), sections = {},
        }
        local runOk, runErr = pcall(function()
            local shared = {}
            for i, key in ipairs(keys) do
                if cancelRequested then
                    manifest.sections[key] = { status = 'cancelled', reason = 'cancelled before start' }
                else
                    if not overlay.ok then
                        Library:Notify(string.format('[Universal] %d/%d %s...', i, #keys, key), 2)
                    end
                    draw(true, i, key, 0, '')
                    local ctx = { status = 'ok' }
                    ctx.progress = function(done, total, item)
                        draw(false, i, key, (total and total > 0) and done / total or 0, item, done, total)
                    end
                    ctx.cancelled = function() return cancelRequested end
                    local started = os.clock()
                    local ok, file, data = pcall(SECTIONS[key], ctx, shared)
                    if not ok then
                        ctx.status, ctx.reason = 'failed', tostring(file)
                    else
                        if cancelRequested and ctx.status == 'ok' then
                            ctx.status, ctx.reason = 'partial', 'cancelled mid-section; file holds what was gathered'
                        end
                        if file and data ~= nil then
                            draw(true, i, key, 1, 'writing ' .. file)
                            local written, err = writeJson(file, data)
                            if written then ctx.file = file else ctx.status, ctx.reason = 'failed', err end
                        end
                    end
                    if key == 'scripts' then
                        shared.mentions = ctx.mentions
                        ctx.mentions = nil
                    end
                    manifest.sections[key] = {
                        status = ctx.status, reason = ctx.reason, note = ctx.note, file = ctx.file,
                        count = ctx.count, truncated = ctx.truncated or nil, coreSkipped = ctx.coreSkipped,
                        seconds = math.floor((os.clock() - started) * 10) / 10,
                    }
                end
            end
        end)
        if not runOk then manifest.runnerError = tostring(runErr) end
        manifest.cancelled = cancelRequested or nil
        manifest.totalSeconds = math.floor((os.clock() - t0) * 10) / 10

        local scriptFiles = 0
        for _, f in ipairs(session.written) do if f:sub(1, 8) == 'scripts/' then scriptFiles = scriptFiles + 1 end end
        manifest.scriptFilesWritten = scriptFiles
        manifest.singleFile = session.single or nil
        local path, err = writeJson('manifest.json', manifest)
        if path and session.single then
            overlay.set({ item = 'writing single file...' })
            path, err = flushBundle()
            session.parts = {}
        end
        if activeCleanup then activeCleanup() end
        busy = false
        local took = Pure.formatDuration(manifest.totalSeconds)
        if path then
            Library:Notify((cancelRequested and 'Universal dump cancelled, partial saved: ' or 'Universal dump saved (' .. took .. '): ')
                .. 'workspace/' .. (session.single and session.bundle or session.folder), 8)
        else
            Library:Notify('Universal dump: manifest write failed: ' .. tostring(err), 8)
        end
    end)
end

-- ================================================================
--  UI
-- ================================================================

local Grp = Tabs.Dumper:AddRightGroupbox('Universal Dump')

Grp:AddLabel('Output: workspace/' .. FOLDER_ROOT .. '/Universal_<place>_<time>(.txt)', true)

Grp:AddButton({ Text = 'Universal Dump (everything)', Func = function() runDump(FULL_ORDER) end })
Grp:AddButton({ Text = 'Scripts + Remotes', Func = function() runDump({ 'scripts', 'remotes' }) end })
Grp:AddButton({ Text = 'GC Closures (constants / upvalues)', Func = function() runDump({ 'gc' }) end })
Grp:AddButton({ Text = 'Module Shapes', Func = function() runDump({ 'modules' }) end })
Grp:AddButton({ Text = 'Player + World + Animations', Func = function() runDump({ 'player', 'world', 'animations' }) end })
Grp:AddButton({ Text = 'Instance Tree (JSON)', Func = function() runDump({ 'tree' }) end })

Grp:AddToggle('UD_IncludeCore', { Text = 'Include Roblox core scripts', Default = false })
Grp:AddToggle('UD_RequireAll', { Text = 'Require unloaded modules (runs their code)', Default = false })
Grp:AddToggle('UD_SingleFile', { Text = 'Single file (one .txt to send)', Default = true })
Grp:AddToggle('UD_Pause3D', { Text = 'Pause 3D rendering while dumping', Default = true })

Grp:AddButton({ Text = 'Copy last output path', Func = function()
    if not session then
        Library:Notify('No dump run yet')
        return
    end
    local setclip = cap('setclipboard', 'toclipboard')
    local target = session.single and session.bundle or session.folder
    if type(setclip) == 'function' and pcall(setclip, target) then
        Library:Notify('Copied: ' .. target)
    else
        Library:Notify('workspace/' .. target)
    end
end })

end -- return function
