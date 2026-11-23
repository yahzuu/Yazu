-- ================================================================
--  features/game_dumper.lua
--  Game-model dumper: remotes, mobs, player data, HUD text,
--  interactables, tags, instance tree, remote call sites,
--  ModuleScript shapes.
--
--  Reads only what the client can see. Contains no game-specific
--  values except OLD_REFERENCES, which are copied from the existing
--  features/bloodlines.lua and are checked, not trusted.
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService        = Services.RunService
local Players           = Services.Players
local CollectionService = Services.CollectionService
local LocalPlayer       = Services.LocalPlayer

-- ================================================================
--  CONFIG (limits only; nothing here is build-dependent)
-- ================================================================

local LIMITS = {
    MaxLinesPerSection = 6000,
    MaxGroupsPerNode   = 80,
    MaxChildrenShown   = 40,
    MaxHudTexts        = 400,
    MaxModuleDepth     = 4,
    MaxModuleKeys      = 120,
    MaxScripts         = 1500,
    MaxCallSiteLines   = 4000,
    RequireTimeout     = 3,
    YieldEvery         = 200,
    MaxTreeLinesPerRoot  = 1200,
    MaxLinesPerModule    = 300,
    WindowBefore         = 8,
    WindowAfter          = 25,
    MaxWindowsPerKeyword = 6,
    MaxSourceScripts     = 4,
    TreeDepth = {
        Workspace         = 4,
        ReplicatedStorage = 7,
        ReplicatedFirst   = 4,
        StarterPlayer     = 4,
        StarterGui        = 4,
        StarterPack       = 4,
        Lighting          = 2,
        Teams             = 2,
    },
}

local TREE_ORDER = {
    'Workspace', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer',
    'StarterGui', 'StarterPack', 'Lighting', 'Teams',
}

local ROOT_NAMES = {
    'Workspace', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterGui',
    'StarterPack', 'StarterPlayer', 'Players', 'Lighting', 'Teams',
}

-- Source: user's existing features/bloodlines.lua. Unverified on the
-- current build; the oldrefs section reports FOUND or MISSING for each.
local OLD_MAIN_PLACE_ID = 10266164381
local OLD_REFERENCES = {
    { path = { 'ReplicatedStorage', 'Events', 'DataEvent' },
      note = 'RemoteEvent; old file hooks it for banme and listens for InDanger/OutOfDanger' },
    { path = { 'Workspace', 'ChakraPoints' },
      note = 'old file reads child.PointName.Value for teleports' },
    { path = { 'ReplicatedStorage', 'DefaultChatSystemChatEvents', 'OnMessageDoneFiltering' },
      note = 'legacy chat event used by old chat logger' },
}
local OLD_KILL_BRICK_NAMES = { 'LavarossaVoid', 'Void' }

local CAPABILITY_NAMES = {
    'decompile', 'getgc', 'getconnections', 'hookmetamethod', 'hookfunction',
    'getrawmetatable', 'getnamecallmethod', 'checkcaller', 'fireproximityprompt',
    'fireclickdetector', 'firetouchinterest', 'firesignal', 'isnetworkowner',
    'sethiddenproperty', 'gethiddenproperty', 'setclipboard', 'writefile',
    'appendfile', 'readfile', 'makefolder', 'isfolder', 'request',
    'http_request', 'identifyexecutor', 'getgenv', 'getnilinstances',
    'getinstances', 'getscripts', 'getloadedmodules', 'getsenv', 'cloneref',
    'compareinstances', 'Drawing', 'queue_on_teleport', 'setfpscap',
}

local SKIP_SCRIPT_ANCESTORS = { PlayerModule = true, RbxCharacterSounds = true }

local CALLSITE_PATTERNS = { 'FireServer', 'InvokeServer', 'OnClientEvent', 'OnClientInvoke' }

-- ================================================================
--  FILESYSTEM (lazy; nothing runs at load time)
-- ================================================================

local FOLDER_ROOT    = 'YazuDumper'
local FOLDER_SESSION = FOLDER_ROOT .. '/Game_' .. tostring(os.time())
local folderReady    = false

local function writeOut(filename, text)
    if type(writefile) ~= 'function' or type(makefolder) ~= 'function' then
        Library:Notify('writefile/makefolder not supported on this executor')
        return nil
    end
    if not folderReady then
        local ok, err = pcall(function()
            if type(isfolder) ~= 'function' or not isfolder(FOLDER_ROOT) then
                makefolder(FOLDER_ROOT)
            end
            makefolder(FOLDER_SESSION)
        end)
        if not ok then
            Library:Notify('Folder creation failed: ' .. tostring(err))
            return nil
        end
        folderReady = true
    end
    local path = FOLDER_SESSION .. '/' .. filename
    local ok, err = pcall(writefile, path, text)
    if not ok then
        Library:Notify('Write error: ' .. tostring(err))
        return nil
    end
    return path
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

local function oneLine(value, maxLen)
    local text = tostring(value)
    text = text:gsub('%c+', ' ')
    if #text > maxLen then
        text = text:sub(1, maxLen) .. '...'
    end
    return text
end

local function fmtValue(v)
    local t = typeof(v)
    if t == 'string' then
        return '"' .. oneLine(v, 80) .. '"'
    end
    if t == 'Instance' then
        local ok, name = pcall(function() return v.ClassName .. ' ' .. v:GetFullName() end)
        return '<' .. (ok and name or 'destroyed') .. '>'
    end
    return oneLine(v, 80)
end

local function attrString(inst)
    local ok, attrs = pcall(inst.GetAttributes, inst)
    if not ok or type(attrs) ~= 'table' then return '' end
    local keys = {}
    for k in pairs(attrs) do keys[#keys + 1] = k end
    if #keys == 0 then return '' end
    table.sort(keys)
    local parts = {}
    for i = 1, math.min(#keys, 10) do
        parts[#parts + 1] = keys[i] .. '=' .. fmtValue(attrs[keys[i]])
    end
    local more = ''
    if #keys > 10 then more = ' +' .. (#keys - 10) .. ' more' end
    return ' {' .. table.concat(parts, ', ') .. more .. '}'
end

local function describe(inst)
    local text = inst.Name .. ' [' .. inst.ClassName .. ']'
    if inst:IsA('ValueBase') then
        text = text .. ' = ' .. fmtValue(prop(inst, 'Value'))
    end
    return text .. attrString(inst)
end

-- Wraps line() with its own budget so one huge subtree cannot starve the rest.
local function budgeted(line, limit)
    local used, cut = 0, false
    local function limited(text)
        if used >= limit then
            cut = true
            return
        end
        used = used + 1
        line(text)
    end
    return limited, function() return cut end
end

local function optionValue(name, fallback)
    local opt = Options and Options[name]
    if opt and type(opt.Value) == 'string' and opt.Value ~= '' then
        return opt.Value
    end
    return fallback
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

-- Calls fn(inst) for every descendant of every root. Per-instance errors
-- (destroyed mid-scan, unreadable property) are counted, not fatal.
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

local function noteSkipped(line, skipped, firstErr)
    if skipped > 0 then
        line('-- instances skipped (destroyed or unreadable): ' .. skipped .. '  first error: ' .. tostring(firstErr))
    end
end

local function relPath(inst, root)
    local full, base = inst:GetFullName(), root:GetFullName()
    if full:sub(1, #base + 1) == base .. '.' then
        return full:sub(#base + 2)
    end
    return full
end

local function positionOf(inst)
    local p = inst.Parent
    if not p then return 'nil' end
    if p:IsA('BasePart') then return tostring(p.Position) end
    if p:IsA('Attachment') then return tostring(p.WorldPosition) end
    if p:IsA('Model') then return tostring(p:GetPivot().Position) end
    return 'n/a'
end

-- Prints the children of inst grouped by (ClassName, Name); identical
-- siblings collapse to one line with a count and only the first expands.
local SKIP_DESCEND = { Terrain = true, Camera = true }

local function dumpTree(line, inst, depth, maxDepth, indent)
    local children = inst:GetChildren()
    if #children == 0 then return end
    local groups, order = {}, {}
    for _, child in ipairs(children) do
        local key = child.ClassName .. '|' .. child.Name
        local g = groups[key]
        if not g then
            g = { first = child, count = 0 }
            groups[key] = g
            order[#order + 1] = key
        end
        g.count = g.count + 1
    end
    table.sort(order)
    local shown = 0
    for _, key in ipairs(order) do
        if shown >= LIMITS.MaxGroupsPerNode then
            line(indent .. '... ' .. (#order - shown) .. ' more groups not shown')
            break
        end
        shown = shown + 1
        local g = groups[key]
        local text = describe(g.first)
        if g.count > 1 then
            text = text .. '  x' .. g.count .. ' (first shown)'
        end
        local expand = depth < maxDepth and not SKIP_DESCEND[g.first.ClassName]
        if not expand then
            local n = #g.first:GetChildren()
            if n > 0 then text = text .. '  (+' .. n .. ' children not expanded)' end
        end
        line(indent .. text)
        if expand then
            dumpTree(line, g.first, depth + 1, maxDepth, indent .. '  ')
        end
        pace()
    end
end

-- ================================================================
--  SECTION: session / executor / workspace
-- ================================================================

local function sectionSession(line)
    line('Generated     : ' .. os.date('%Y-%m-%d %H:%M:%S'))
    line('PlaceId       : ' .. tostring(game.PlaceId))
    line('GameId        : ' .. tostring(game.GameId))
    line('PlaceVersion  : ' .. tostring(game.PlaceVersion))
    line('PlayerCount   : ' .. tostring(#Players:GetPlayers()))
    line('')
    line('Workspace.StreamingEnabled      : ' .. tostring(prop(workspace, 'StreamingEnabled')))
    line('Workspace.StreamingMinRadius    : ' .. tostring(prop(workspace, 'StreamingMinRadius')))
    line('Workspace.StreamingTargetRadius : ' .. tostring(prop(workspace, 'StreamingTargetRadius')))
    line('Workspace.Gravity               : ' .. tostring(prop(workspace, 'Gravity')))
    line('')
    local exName, exVer = 'unknown', ''
    if type(identifyexecutor) == 'function' then
        local ok, a, b = pcall(identifyexecutor)
        if ok then exName, exVer = tostring(a), tostring(b or '') end
    end
    line('Executor      : ' .. exName .. ' ' .. exVer)

    local genv
    if type(getgenv) == 'function' then
        local ok, e = pcall(getgenv)
        if ok and type(e) == 'table' then genv = e end
    end
    local fenv = getfenv(1)
    local present, missing = {}, {}
    for _, name in ipairs(CAPABILITY_NAMES) do
        local value = fenv[name]
        if value == nil and genv then value = genv[name] end
        local t = type(value)
        if t == 'nil' then
            missing[#missing + 1] = name
        else
            present[#present + 1] = name .. ':' .. t
        end
    end
    line('Present       : ' .. table.concat(present, ', '))
    line('Missing       : ' .. table.concat(missing, ', '))
end

-- ================================================================
--  SECTION: paths referenced by the existing bloodlines.lua
-- ================================================================

local function sectionOldReferences(line)
    line('PlaceId == ' .. OLD_MAIN_PLACE_ID .. ' (old MAIN_PLACE_ID): ' .. tostring(game.PlaceId == OLD_MAIN_PLACE_ID))
    line('')
    for _, ref in ipairs(OLD_REFERENCES) do
        local node, failedAt = game, nil
        for _, segment in ipairs(ref.path) do
            node = node:FindFirstChild(segment)
            if not node then failedAt = segment break end
        end
        local label = table.concat(ref.path, '.')
        if node then
            line('FOUND   ' .. label .. ' [' .. node.ClassName .. '] children=' .. #node:GetChildren())
        else
            line('MISSING ' .. label .. ' (stopped at "' .. tostring(failedAt) .. '")')
        end
        line('        old-file note: ' .. ref.note)
    end
    line('')
    for _, name in ipairs(OLD_KILL_BRICK_NAMES) do
        local found = workspace:FindFirstChild(name, true)
        if found then
            line('FOUND   kill brick name "' .. name .. '" -> ' .. found:GetFullName() .. ' [' .. found.ClassName .. ']')
        else
            line('MISSING kill brick name "' .. name .. '" (not currently loaded, or renamed)')
        end
    end
end

-- ================================================================
--  SECTION: remotes
-- ================================================================

local function sectionRemotes(line)
    local list = {}
    local skipped, firstErr = eachDescendant(getRoots(ROOT_NAMES), function(inst)
        if inst:IsA('BaseRemoteEvent') or inst:IsA('RemoteFunction') then
            list[#list + 1] = { class = inst.ClassName, path = inst:GetFullName(), name = inst.Name }
        end
    end)
    table.sort(list, function(a, b) return a.path < b.path end)
    line('remote count: ' .. #list)
    local byName = {}
    for _, r in ipairs(list) do
        byName[r.name] = (byName[r.name] or 0) + 1
        line(string.format('%-22s %s', r.class, r.path))
    end
    local dups = {}
    for name, n in pairs(byName) do
        if n > 1 then dups[#dups + 1] = name .. ' x' .. n end
    end
    if #dups > 0 then
        table.sort(dups)
        line('')
        line('names that appear more than once: ' .. table.concat(dups, ', '))
    end
    noteSkipped(line, skipped, firstErr)
end

-- ================================================================
--  SECTION: mobs / NPCs
-- ================================================================

local function looksLikeHealthName(name)
    local l = name:lower()
    return l:find('health', 1, true) ~= nil or l:match('^hp') ~= nil or l:match('hp$') ~= nil
end

local function printMobGroup(line, key, g)
    local model, hum = g.sample, g.humanoid
    line(string.format('%s  x%d', key, g.count))
    local parentList = {}
    for p, n in pairs(g.parents) do parentList[#parentList + 1] = p .. ' (' .. n .. ')' end
    table.sort(parentList)
    line('  parents : ' .. table.concat(parentList, ', '))
    line('  sample  : ' .. model:GetFullName())
    line(string.format('  humanoid: Health=%s MaxHealth=%s WalkSpeed=%s RigType=%s DisplayName=%s',
        tostring(prop(hum, 'Health')), tostring(prop(hum, 'MaxHealth')),
        tostring(prop(hum, 'WalkSpeed')), tostring(prop(hum, 'RigType')),
        fmtValue(prop(hum, 'DisplayName'))))
    local root = model:FindFirstChild('HumanoidRootPart') or model.PrimaryPart
    if root then
        line('  position: ' .. tostring(root.Position) .. ' (at dump time)')
    else
        line('  position: no HumanoidRootPart or PrimaryPart')
    end
    local attrs = attrString(model)
    if attrs ~= '' then line('  model attributes:' .. attrs) end
    local hattrs = attrString(hum)
    if hattrs ~= '' then line('  humanoid attributes:' .. hattrs) end
    local okTags, tags = pcall(CollectionService.GetTags, CollectionService, model)
    if okTags and type(tags) == 'table' and #tags > 0 then
        line('  tags    : ' .. table.concat(tags, ', '))
    end
    local children = model:GetChildren()
    line('  children (' .. #children .. '):')
    for i = 1, math.min(#children, LIMITS.MaxChildrenShown) do
        line('    ' .. describe(children[i]))
    end
    if #children > LIMITS.MaxChildrenShown then
        line('    ... ' .. (#children - LIMITS.MaxChildrenShown) .. ' more')
    end
    line('')
end

local function sectionMobs(line)
    line('Only models currently loaded on this client appear. If StreamingEnabled is true,')
    line('stand near the mobs you care about before dumping.')
    line('')
    line('-- A. Humanoid models that are not player characters, grouped by model name')
    local groups, order = {}, {}
    local skipped, firstErr = eachDescendant({ workspace }, function(inst)
        if not inst:IsA('Humanoid') then return end
        local model = inst.Parent
        if not model or not model:IsA('Model') then return end
        if Players:GetPlayerFromCharacter(model) then return end
        local g = groups[model.Name]
        if not g then
            g = { count = 0, sample = model, humanoid = inst, parents = {} }
            groups[model.Name] = g
            order[#order + 1] = model.Name
        end
        g.count = g.count + 1
        local parentPath = model.Parent and model.Parent:GetFullName() or 'nil'
        g.parents[parentPath] = (g.parents[parentPath] or 0) + 1
    end)
    table.sort(order)
    line('groups: ' .. #order)
    line('')
    for _, key in ipairs(order) do
        local ok, err = pcall(printMobGroup, line, key, groups[key])
        if not ok then line(key .. ': print failed: ' .. tostring(err)) end
    end
    noteSkipped(line, skipped, firstErr)

    line('')
    line('-- B. Non-Humanoid entities with health-like values or attributes (heuristic: name contains "health" or starts/ends with "hp")')
    local hits, hitOrder = {}, {}
    local function addHit(key, sample, valueText)
        local g = hits[key]
        if not g then
            g = { count = 0, sample = sample, valueText = valueText }
            hits[key] = g
            hitOrder[#hitOrder + 1] = key
        end
        g.count = g.count + 1
    end
    local skipped2, firstErr2 = eachDescendant({ workspace }, function(inst)
        if inst:IsA('ValueBase') and looksLikeHealthName(inst.Name) then
            local owner = inst.Parent
            if not owner or owner == workspace then return end
            if owner:FindFirstChildOfClass('Humanoid') then return end
            if Players:GetPlayerFromCharacter(owner) then return end
            addHit(owner.Name .. ' / value ' .. inst.Name .. ' [' .. inst.ClassName .. ']', inst, fmtValue(prop(inst, 'Value')))
        elseif inst:IsA('Model') and not inst:FindFirstChildOfClass('Humanoid') and not Players:GetPlayerFromCharacter(inst) then
            local ok, attrs = pcall(inst.GetAttributes, inst)
            if ok and type(attrs) == 'table' then
                for attrName, attrValue in pairs(attrs) do
                    if looksLikeHealthName(attrName) then
                        addHit(inst.Name .. ' / attribute ' .. attrName, inst, fmtValue(attrValue))
                    end
                end
            end
        end
    end)
    table.sort(hitOrder)
    if #hitOrder == 0 then line('none found') end
    for i, key in ipairs(hitOrder) do
        if i > 60 then line('... ' .. (#hitOrder - 60) .. ' more') break end
        local g = hits[key]
        line(string.format('%s  x%d  e.g. %s = %s', key, g.count, g.sample:GetFullName(), g.valueText))
    end
    noteSkipped(line, skipped2, firstErr2)
end

-- ================================================================
--  SECTION: LocalPlayer data, character, backpack, HUD text
-- ================================================================

local function sectionPlayer(line)
    if not LocalPlayer then line('LocalPlayer is nil') return end

    line('-- LocalPlayer attributes:' .. (attrString(LocalPlayer) ~= '' and attrString(LocalPlayer) or ' none'))
    line('')
    line('-- LocalPlayer children (PlayerGui, Backpack, PlayerScripts listed separately)')
    local special = { PlayerGui = true, Backpack = true, PlayerScripts = true }
    for _, child in ipairs(LocalPlayer:GetChildren()) do
        if not special[child.Name] then
            line(describe(child))
            dumpTree(line, child, 1, 4, '  ')
        end
    end

    line('')
    line('-- Character')
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass('Humanoid')
        if hum then
            line(string.format('Humanoid: Health=%s MaxHealth=%s WalkSpeed=%s JumpPower=%s JumpHeight=%s UseJumpPower=%s HipHeight=%s RigType=%s',
                tostring(prop(hum, 'Health')), tostring(prop(hum, 'MaxHealth')),
                tostring(prop(hum, 'WalkSpeed')), tostring(prop(hum, 'JumpPower')),
                tostring(prop(hum, 'JumpHeight')), tostring(prop(hum, 'UseJumpPower')),
                tostring(prop(hum, 'HipHeight')), tostring(prop(hum, 'RigType'))))
        end
        local attrs = attrString(char)
        if attrs ~= '' then line('Character attributes:' .. attrs) end
        dumpTree(line, char, 1, 3, '  ')
    else
        line('no Character at dump time')
    end

    line('')
    line('-- Backpack')
    local backpack = LocalPlayer:FindFirstChildOfClass('Backpack')
    if backpack and #backpack:GetChildren() > 0 then
        for _, tool in ipairs(backpack:GetChildren()) do
            line(describe(tool))
            dumpTree(line, tool, 1, 3, '  ')
        end
    else
        line('empty or missing')
    end

    line('')
    line('-- PlayerScripts')
    local scripts = LocalPlayer:FindFirstChildOfClass('PlayerScripts')
    if scripts then dumpTree(line, scripts, 1, 2, '  ') else line('missing') end

    line('')
    line('-- PlayerGui: ScreenGuis')
    local gui = LocalPlayer:FindFirstChildOfClass('PlayerGui')
    if not gui then line('PlayerGui missing') return end
    for _, g in ipairs(gui:GetChildren()) do
        line(string.format('%s [%s] Enabled=%s descendants=%d',
            g.Name, g.ClassName, tostring(prop(g, 'Enabled')), #g:GetDescendants()))
    end

    line('')
    line('-- PlayerGui: visible-or-hidden text (path relative to PlayerGui)')
    local count = 0
    local skipped, firstErr = eachDescendant({ gui }, function(inst)
        if count >= LIMITS.MaxHudTexts then return end
        if inst:IsA('TextLabel') or inst:IsA('TextButton') or inst:IsA('TextBox') then
            local text = inst.Text
            if type(text) == 'string' and not text:match('^%s*$') then
                count = count + 1
                line(string.format('%s [%s] Visible=%s "%s"',
                    relPath(inst, gui), inst.ClassName, tostring(prop(inst, 'Visible')), oneLine(text, 100)))
            end
        end
    end)
    if count >= LIMITS.MaxHudTexts then line('... text list capped at ' .. LIMITS.MaxHudTexts) end
    noteSkipped(line, skipped, firstErr)
end

-- ================================================================
--  SECTION: interactables (ProximityPrompt / ClickDetector)
-- ================================================================

local function sectionInteract(line)
    local groups, order = {}, {}
    local skipped, firstErr = eachDescendant({ workspace }, function(inst)
        local key, detail
        if inst:IsA('ProximityPrompt') then
            key = string.format('ProximityPrompt | ActionText=%s | ObjectText=%s',
                fmtValue(inst.ActionText), fmtValue(inst.ObjectText))
            detail = string.format('HoldDuration=%s MaxActivationDistance=%s RequiresLineOfSight=%s Enabled=%s',
                tostring(inst.HoldDuration), tostring(inst.MaxActivationDistance),
                tostring(inst.RequiresLineOfSight), tostring(inst.Enabled))
        elseif inst:IsA('ClickDetector') then
            key = 'ClickDetector | parent=' .. (inst.Parent and inst.Parent.Name or 'nil')
            detail = 'MaxActivationDistance=' .. tostring(inst.MaxActivationDistance)
        else
            return
        end
        local g = groups[key]
        if not g then
            g = { count = 0, sample = inst, detail = detail }
            groups[key] = g
            order[#order + 1] = key
        end
        g.count = g.count + 1
    end)
    table.sort(order)
    line('groups: ' .. #order)
    for i, key in ipairs(order) do
        if i > 300 then line('... ' .. (#order - 300) .. ' more groups') break end
        local g = groups[key]
        line(string.format('%s  x%d', key, g.count))
        line('  ' .. g.detail)
        line('  sample: ' .. g.sample:GetFullName() .. '  at ' .. positionOf(g.sample))
    end
    noteSkipped(line, skipped, firstErr)
end

-- ================================================================
--  SECTION: CollectionService tags
-- ================================================================

local function sectionTags(line)
    local ok, tags = pcall(CollectionService.GetAllTags, CollectionService)
    if not ok or type(tags) ~= 'table' then
        line('GetAllTags unavailable: ' .. tostring(tags))
        return
    end
    table.sort(tags)
    local emptyCount, guidCount = 0, 0
    for _, tag in ipairs(tags) do
        local tagged = CollectionService:GetTagged(tag)
        if #tagged == 0 then
            emptyCount = emptyCount + 1
        elseif tag:match('^%x+%-%x+%-%x+%-%x+%-%x+$') then
            guidCount = guidCount + 1
        else
            local samples = {}
            for i = 1, math.min(#tagged, 3) do
                samples[#samples + 1] = tagged[i]:GetFullName()
            end
            line(string.format('%-32s count=%d  e.g. %s', tag, #tagged, table.concat(samples, ' | ')))
        end
    end
    line('-- total tags: ' .. #tags .. ', hidden: ' .. emptyCount .. ' with no tagged instance, ' .. guidCount .. ' GUID-named (tween ids)')
end

-- ================================================================
--  SECTION: instance tree
-- ================================================================

local function sectionTree(line)
    for _, name in ipairs(TREE_ORDER) do
        local svc = getService(name)
        if svc then
            local depth = LIMITS.TreeDepth[name]
            line('')
            line('### ' .. name .. ' (depth ' .. depth .. ')')
            local rootLine, wasCut = budgeted(line, LIMITS.MaxTreeLinesPerRoot)
            dumpTree(rootLine, svc, 1, depth, '  ')
            if wasCut() then
                line('  !! ' .. name .. ' tree cut at ' .. LIMITS.MaxTreeLinesPerRoot .. ' lines')
            end
        end
    end
end

-- ================================================================
--  SECTION: remote call sites (needs decompile)
-- ================================================================

local function hasSkippedAncestor(inst)
    local node = inst
    while node and node ~= game do
        if SKIP_SCRIPT_ANCESTORS[node.Name] then return true end
        node = node.Parent
    end
    return false
end

local function collectScripts()
    local roots = getRoots({ 'ReplicatedStorage', 'ReplicatedFirst' })
    if LocalPlayer then
        roots[#roots + 1] = LocalPlayer
        if LocalPlayer.Character then roots[#roots + 1] = LocalPlayer.Character end
    end
    local list, seen = {}, {}
    eachDescendant(roots, function(inst)
        if (inst:IsA('LocalScript') or inst:IsA('ModuleScript')) and not seen[inst] and not hasSkippedAncestor(inst) then
            seen[inst] = true
            list[#list + 1] = inst
        end
    end)
    table.sort(list, function(a, b) return a:GetFullName() < b:GetFullName() end)
    return list
end

local function sectionCallSites(line)
    if type(decompile) ~= 'function' then
        line('decompile() is not available on this executor; call sites cannot be indexed.')
        line('Fallback: use the Remote Spy while performing the action in game.')
        return
    end
    local scripts = collectScripts()
    line('scripts found: ' .. #scripts .. ' (limit ' .. LIMITS.MaxScripts .. ')')
    line('patterns: ' .. table.concat(CALLSITE_PATTERNS, ', '))
    line('')
    local scanned, noSource, emitted = 0, 0, 0
    for i = 1, math.min(#scripts, LIMITS.MaxScripts) do
        local inst = scripts[i]
        local ok, src = pcall(decompile, inst)
        scanned = scanned + 1
        if not ok or type(src) ~= 'string' or #src == 0 then
            noSource = noSource + 1
        else
            local hits, prev, prevN, n = {}, '', 0, 0
            for text in (src .. '\n'):gmatch('(.-)\n') do
                n = n + 1
                for _, pattern in ipairs(CALLSITE_PATTERNS) do
                    if text:find(pattern, 1, true) then
                        hits[#hits + 1] = { n = n, text = text, prev = prev, prevN = prevN }
                        break
                    end
                end
                if text:match('%S') then prev, prevN = text, n end
            end
            if #hits > 0 then
                line(string.format('%s (%s, %d bytes)', inst:GetFullName(), inst.ClassName, #src))
                local lastPrinted = 0
                for _, h in ipairs(hits) do
                    if emitted >= LIMITS.MaxCallSiteLines then break end
                    emitted = emitted + 1
                    if h.prevN > lastPrinted then
                        line('  L' .. h.prevN .. ': ' .. oneLine((h.prev:gsub('^%s+', '')), 160))
                    end
                    line('  L' .. h.n .. ': ' .. oneLine((h.text:gsub('^%s+', '')), 220))
                    lastPrinted = h.n
                end
                line('')
            end
        end
        RunService.Heartbeat:Wait()
    end
    line(string.format('scanned=%d, no decompiled source=%d, hit lines emitted=%d', scanned, noSource, emitted))
end

-- ================================================================
--  SECTION: ModuleScript shapes (runs require on each module)
-- ================================================================

local function fnInfo(f)
    if type(debug) ~= 'table' or type(debug.getinfo) ~= 'function' then return '' end
    local ok, info = pcall(debug.getinfo, f)
    if not ok or type(info) ~= 'table' then return '' end
    return string.format(' (name=%s params=%s src=%s line=%s)',
        tostring(info.name), tostring(info.numparams or info.nparams),
        tostring(info.short_src or info.source), tostring(info.linedefined or info.currentline))
end

local function keyText(k)
    if type(k) == 'string' then return k end
    return '[' .. tostring(k) .. ']'
end

local shapeEntry
shapeEntry = function(line, key, value, indent, depth, seen)
    local t = typeof(value)
    if type(value) == 'function' then
        line(indent .. key .. ': function' .. fnInfo(value))
        return
    end
    if type(value) ~= 'table' then
        line(indent .. key .. ': ' .. t .. ' = ' .. fmtValue(value))
        return
    end
    if seen[value] then
        line(indent .. key .. ': table (already shown above)')
        return
    end
    seen[value] = true
    local keys, arrayLen = {}, #value
    for k in pairs(value) do
        if not (type(k) == 'number' and k >= 1 and k <= arrayLen and k % 1 == 0) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    line(indent .. key .. ': table (' .. arrayLen .. ' array entries, ' .. #keys .. ' other keys)')
    if depth >= LIMITS.MaxModuleDepth then return end
    local shownArray = arrayLen
    if arrayLen > 5 then shownArray = 3 end
    for i = 1, shownArray do
        shapeEntry(line, '[' .. i .. ']', value[i], indent .. '  ', depth + 1, seen)
    end
    if arrayLen > shownArray then
        line(indent .. '  ... ' .. (arrayLen - shownArray) .. ' more array entries')
    end
    for i, k in ipairs(keys) do
        if i > LIMITS.MaxModuleKeys then
            line(indent .. '  ... ' .. (#keys - LIMITS.MaxModuleKeys) .. ' more keys')
            break
        end
        shapeEntry(line, keyText(k), value[k], indent .. '  ', depth + 1, seen)
    end
end

local function requireWithTimeout(mod, seconds)
    local done, ok, result = false, false, nil
    task.spawn(function()
        ok, result = pcall(require, mod)
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < seconds do
        RunService.Heartbeat:Wait()
    end
    if not done then return false, 'timed out after ' .. seconds .. 's' end
    return ok, result
end

local function sectionModules(line)
    line('Each module is passed to require(); a module already required by the game returns its cached value.')
    line('Modules that fail or hang are reported and skipped.')
    line('')
    local modules = {}
    local skipped, firstErr = eachDescendant(getRoots({ 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer' }), function(inst)
        if inst:IsA('ModuleScript') then modules[#modules + 1] = inst end
    end)
    table.sort(modules, function(a, b) return a:GetFullName() < b:GetFullName() end)
    line('modules: ' .. #modules)
    line('')
    for _, mod in ipairs(modules) do
        line('## ' .. mod:GetFullName())
        local ok, result = requireWithTimeout(mod, LIMITS.RequireTimeout)
        if not ok then
            line('  require failed: ' .. oneLine(result, 200))
        else
            local modLine, modCut = budgeted(line, LIMITS.MaxLinesPerModule)
            shapeEntry(modLine, '<return>', result, '  ', 1, {})
            if modCut() then
                line('  !! module output cut at ' .. LIMITS.MaxLinesPerModule .. ' lines')
            end
        end
        line('')
    end
    noteSkipped(line, skipped, firstErr)
end

-- ================================================================
--  SECTION: source windows (decompiled code around keywords)
-- ================================================================

local DEFAULT_SCRIPT_MATCH = 'ClientGui.LocalScript'
local DEFAULT_KEYWORDS     = 'CheckMeleeHit,startSkill,GetQuestProgress,StartQuest'

local function splitKeywords(text)
    local list = {}
    for word in tostring(text):gmatch('[^,]+') do
        word = word:match('^%s*(.-)%s*$')
        if word ~= '' then list[#list + 1] = word end
    end
    return list
end

local function sectionSource(line)
    if type(decompile) ~= 'function' then
        line('decompile() is not available on this executor.')
        return
    end
    local needle   = optionValue('GD_ScriptMatch', DEFAULT_SCRIPT_MATCH)
    local keywords = splitKeywords(optionValue('GD_Keywords', DEFAULT_KEYWORDS))
    line('script path contains : ' .. needle)
    line('keywords             : ' .. table.concat(keywords, ', '))
    line('window               : ' .. LIMITS.WindowBefore .. ' lines before, ' .. LIMITS.WindowAfter .. ' after, up to ' .. LIMITS.MaxWindowsPerKeyword .. ' windows per keyword')
    line('')

    local matched = {}
    for _, inst in ipairs(collectScripts()) do
        if inst:GetFullName():find(needle, 1, true) then
            matched[#matched + 1] = inst
            if #matched >= LIMITS.MaxSourceScripts then break end
        end
    end
    if #matched == 0 then
        line('no script path contains "' .. needle .. '"')
        return
    end

    for _, inst in ipairs(matched) do
        local ok, src = pcall(decompile, inst)
        if not ok or type(src) ~= 'string' or #src == 0 then
            line('######## ' .. inst:GetFullName() .. ': no decompiled source')
        else
            local lines = {}
            for text in (src .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = text end
            line('######## ' .. inst:GetFullName() .. ' (' .. #lines .. ' lines)')
            for _, kw in ipairs(keywords) do
                line('-- keyword: ' .. kw)
                local shown, lastEnd = 0, 0
                for n = 1, #lines do
                    if lines[n]:find(kw, 1, true) and n > lastEnd then
                        if shown >= LIMITS.MaxWindowsPerKeyword then
                            line('  ... more hits not shown')
                            break
                        end
                        local from = math.max(1, n - LIMITS.WindowBefore)
                        local to   = math.min(#lines, n + LIMITS.WindowAfter)
                        if from <= lastEnd then from = lastEnd + 1 end
                        line('  ---- lines ' .. from .. '-' .. to)
                        for i = from, to do
                            line(string.format('%6d  %s', i, lines[i]:sub(1, 240)))
                        end
                        lastEnd = to
                        shown = shown + 1
                    end
                end
                RunService.Heartbeat:Wait()
            end
            line('')
        end
    end
end

-- ================================================================
--  RUNNER
-- ================================================================

local SECTIONS = {
    session  = { title = 'SESSION / EXECUTOR / WORKSPACE',                                run = sectionSession },
    oldrefs  = { title = 'PATHS REFERENCED BY EXISTING features/bloodlines.lua (user file, unverified)', run = sectionOldReferences },
    remotes  = { title = 'REMOTES (RemoteEvent / UnreliableRemoteEvent / RemoteFunction)', run = sectionRemotes },
    mobs     = { title = 'MOBS / NPCS',                                                    run = sectionMobs },
    player   = { title = 'LOCALPLAYER DATA / CHARACTER / BACKPACK / HUD TEXT',             run = sectionPlayer },
    interact = { title = 'INTERACTABLES (ProximityPrompt / ClickDetector)',                run = sectionInteract },
    tags     = { title = 'COLLECTIONSERVICE TAGS',                                         run = sectionTags },
    tree     = { title = 'INSTANCE TREE',                                                  run = sectionTree },
    calls    = { title = 'REMOTE CALL SITES (decompiled LocalScripts and ModuleScripts)',  run = sectionCallSites },
    modules  = { title = 'MODULESCRIPT RETURN SHAPES (runs require)',                      run = sectionModules },
    source   = { title = 'DECOMPILED SOURCE WINDOWS AROUND KEYWORDS',                      run = sectionSource },
}

local FULL_ORDER = { 'session', 'oldrefs', 'remotes', 'mobs', 'player', 'interact', 'tags', 'tree', 'calls' }

local function runSection(out, section)
    local started = os.clock()
    local emitted, truncated = 0, false
    local function line(text)
        if emitted >= LIMITS.MaxLinesPerSection then
            truncated = true
            return
        end
        emitted = emitted + 1
        out[#out + 1] = text
    end
    out[#out + 1] = string.rep('=', 72)
    out[#out + 1] = '== ' .. section.title
    out[#out + 1] = string.rep('=', 72)
    local ok, err = pcall(section.run, line)
    if not ok then out[#out + 1] = '!! section failed: ' .. tostring(err) end
    if truncated then
        out[#out + 1] = '!! truncated at ' .. LIMITS.MaxLinesPerSection .. ' lines'
    end
    out[#out + 1] = string.format('-- done in %.1fs, %d lines', os.clock() - started, emitted)
    out[#out + 1] = ''
end

local busy = false

local function runDump(keys, filename)
    if busy then
        Library:Notify('A dump is already running')
        return
    end
    busy = true
    task.spawn(function()
        local out = { '-- Yazu game model dump', '-- sections: ' .. table.concat(keys, ', '), '' }
        local ok, err = pcall(function()
            for _, key in ipairs(keys) do
                runSection(out, SECTIONS[key])
            end
        end)
        if not ok then out[#out + 1] = '!! runner failed: ' .. tostring(err) end
        local path = writeOut(filename, table.concat(out, '\n'))
        busy = false
        if path then
            Library:Notify('Saved ' .. path)
        end
    end)
end

-- ================================================================
--  UI
-- ================================================================

local Grp = Tabs.Dumper:AddRightGroupbox('Game Model Dump')

Grp:AddLabel('Output: workspace/' .. FOLDER_SESSION)

Grp:AddButton({ Text = 'Full Dump (everything except modules)', Func = function()
    runDump(FULL_ORDER, 'Game_Dump.txt')
end })
Grp:AddButton({ Text = 'Remotes + Old Path Check', Func = function()
    runDump({ 'session', 'oldrefs', 'remotes' }, 'Dump_Remotes.txt')
end })
Grp:AddButton({ Text = 'Mobs / NPCs', Func = function()
    runDump({ 'session', 'mobs' }, 'Dump_Mobs.txt')
end })
Grp:AddButton({ Text = 'Player Data + HUD Text', Func = function()
    runDump({ 'player' }, 'Dump_Player.txt')
end })
Grp:AddButton({ Text = 'Interactables + Tags', Func = function()
    runDump({ 'interact', 'tags' }, 'Dump_Interact.txt')
end })
Grp:AddButton({ Text = 'Instance Tree', Func = function()
    runDump({ 'tree' }, 'Dump_Tree.txt')
end })
Grp:AddButton({ Text = 'Remote Call Sites (decompile)', Func = function()
    runDump({ 'calls' }, 'Dump_CallSites.txt')
end })
Grp:AddButton({ Text = 'Module Shapes (runs require)', Func = function()
    runDump({ 'modules' }, 'Dump_Modules.txt')
end })
Grp:AddInput('GD_ScriptMatch', {
    Default = DEFAULT_SCRIPT_MATCH, Text = 'Script path contains',
    Placeholder = 'e.g. ClientGui.LocalScript', Finished = true,
})
Grp:AddInput('GD_Keywords', {
    Default = DEFAULT_KEYWORDS, Text = 'Keywords (comma separated)',
    Placeholder = 'e.g. CheckMeleeHit,StartQuest', Finished = true,
})
Grp:AddButton({ Text = 'Source Windows (uses the two inputs above)', Func = function()
    runDump({ 'source' }, 'Dump_Source.txt')
end })

end -- return function
