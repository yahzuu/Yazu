-- ================================================================
--  Yazu | features/mm2.lua
--  PlaceId 142823291, GameId 66654135 (dump PlaceVersion 1467)
--  Paths come from that dump. Anything not seen there is marked UNCONFIRMED.
-- ================================================================

-- >>> PURE  (no Roblox globals; tests/mm2_test.luau)
local Pure = {}

-- Rarity sort order from ReplicatedStorage.Database.Sync.Rarities (lower = rarer).
Pure.RARITY_SORT = { Unique = 70, Ancient = 75, Godly = 80, Legendary = 85, Rare = 90,
    Uncommon = 95, Common = 100, Halloween = 104, Christmas = 105, Classic = 110 }
Pure.RARITY_ORDER = { 'Unique', 'Ancient', 'Godly', 'Legendary', 'Rare', 'Uncommon', 'Common',
    'Halloween', 'Christmas', 'Classic' }

local function sortOf(r) return Pure.RARITY_SORT[r] or 999 end

-- inv: what Remotes.Extras.GetFullInventory returns (the game's View Profile
--      uses it, ViewProfileModule L104): inv.Weapons.Owned / inv.Pets.Owned are
--      { [itemId] = amount }, other categories are { itemId, ... },
--      inv.Uniques = { { BaseItem = id, ... } } (InventoryModule L146-L200).
-- db:  Sync tables { Weapons = { [id] = { ItemName, Rarity } }, Pets = {...} }.
-- Returns { counts = { [rarity] = n }, items = sorted list, total = n, other = { [cat] = n } }.
function Pure.summarize(inv, db)
    local counts, items, total, other = {}, {}, 0, {}
    inv = inv or {}
    local function add(cat, id, amount)
        local info = db[cat] and db[cat][id]
        local name = info and (info.ItemName or info.Name) or tostring(id)
        local rarity = info and info.Rarity or 'Common'
        amount = tonumber(amount) or 1
        counts[rarity] = (counts[rarity] or 0) + amount
        total = total + amount
        items[#items + 1] = { name = name, rarity = rarity, amount = amount, cat = cat,
            chroma = string.find(name, 'Chroma', 1, true) ~= nil }
    end
    for _, cat in ipairs({ 'Weapons', 'Pets' }) do
        local owned = inv[cat] and inv[cat].Owned
        if type(owned) == 'table' then
            for id, amount in pairs(owned) do add(cat, id, amount) end
        end
    end
    for _, u in ipairs(inv.Uniques or {}) do
        if type(u) == 'table' and u.BaseItem then add('Weapons', u.BaseItem, 1) end
    end
    for _, cat in ipairs({ 'Effects', 'Perks', 'Emotes', 'Radios' }) do
        local owned = inv[cat] and inv[cat].Owned
        if type(owned) == 'table' then
            local n = 0
            for _ in pairs(owned) do n = n + 1 end
            other[cat] = n
        end
    end
    table.sort(items, function(a, b)
        local sa, sb = sortOf(a.rarity), sortOf(b.rarity)
        if sa ~= sb then return sa < sb end
        if a.chroma ~= b.chroma then return a.chroma end
        return a.name < b.name
    end)
    return { counts = counts, items = items, total = total, other = other }
end

-- Items worth calling out: Unique / Ancient / Godly or any Chroma.
function Pure.highlights(summary, limit)
    local out = {}
    for _, it in ipairs(summary.items) do
        if sortOf(it.rarity) <= 80 or it.chroma then
            out[#out + 1] = it
            if limit and #out >= limit then break end
        end
    end
    return out
end

-- A rough "rich score" for ranking a server: rarer items count more.
function Pure.score(summary)
    local w = { Unique = 50, Ancient = 25, Godly = 10, Legendary = 1 }
    local s = 0
    for r, n in pairs(summary.counts) do s = s + (w[r] or 0) * n end
    for _, it in ipairs(summary.items) do if it.chroma then s = s + 15 * it.amount end end
    return s
end

-- servers: { { id = jobId, playing = n, maxPlayers = n } } from
-- games.roblox.com/v1/games/<placeId>/servers/Public.
-- mode: 'random' | 'smallest' | 'largest'. Never the current server or a full one.
function Pure.pickServer(servers, mode, currentJobId, rand)
    local ok = {}
    for _, s in ipairs(servers or {}) do
        if s.id ~= currentJobId and type(s.playing) == 'number' and type(s.maxPlayers) == 'number'
            and s.playing < s.maxPlayers then
            ok[#ok + 1] = s
        end
    end
    if #ok == 0 then return nil end
    if mode == 'smallest' then
        table.sort(ok, function(a, b) return a.playing < b.playing end)
        return ok[1]
    elseif mode == 'largest' then
        table.sort(ok, function(a, b) return a.playing > b.playing end)
        return ok[1]
    end
    local r = rand or math.random
    return ok[r(1, #ok)]
end
-- <<< PURE

return function(State, Tabs, Services, Library)

local Tab = Tabs.MM2
if not Tab then return end

local Players      = Services.Players
local LocalPlayer  = Services.LocalPlayer
local RepStorage   = game:GetService('ReplicatedStorage')
local TeleportService = game:GetService('TeleportService')
local HttpService  = game:GetService('HttpService')
local GuiService   = game:GetService('GuiService')

local cleanups = {}
local function onCleanup(fn) cleanups[#cleanups + 1] = fn end
if type(Library.OnUnload) == 'function' then
    Library:OnUnload(function() for i = #cleanups, 1, -1 do pcall(cleanups[i]) end end)
end
local function connect(signal, fn)
    local c = signal:Connect(fn)
    onCleanup(function() c:Disconnect() end)
    return c
end
local function on(name) return Toggles and Toggles[name] and Toggles[name].Value == true end
local function opt(name, fallback)
    local o = Options and Options[name]
    if o and o.Value ~= nil then return o.Value end
    return fallback
end
local function notify(text, t) pcall(function() Library:Notify(text, t or 4) end) end

-- ================================================================
--  GAME DATA
-- ================================================================
-- ReplicatedStorage.Remotes.Extras.GetFullInventory  RemoteFunction(playerName)
-- ReplicatedStorage.Database.Sync                   item database (Weapons, Pets, Rarities)
local function getRemote()
    local r = RepStorage:FindFirstChild('Remotes')
    local e = r and r:FindFirstChild('Extras')
    return e and e:FindFirstChild('GetFullInventory')
end
local db
local function getDb()
    if db then return db end
    local d = RepStorage:FindFirstChild('Database')
    local s = d and d:FindFirstChild('Sync')
    if not s then return nil end
    local ok, res = pcall(require, s)
    if ok and type(res) == 'table' then db = res end
    return db
end

local cache = {} -- name -> { at, summary }
local function inventoryOf(name, fresh)
    local c = cache[name]
    if c and not fresh and os.clock() - c.at < 60 then return c.summary end
    local rf = getRemote()
    local d = getDb()
    if not (rf and d) then return nil, 'inventory remote or item database not found' end
    local ok, inv = pcall(rf.InvokeServer, rf, name)
    if not ok or type(inv) ~= 'table' then return nil, 'server did not answer: ' .. tostring(inv) end
    local s = Pure.summarize(inv, { Weapons = d.Weapons or {}, Pets = d.Pets or {} })
    cache[name] = { at = os.clock(), summary = s }
    return s
end

-- ================================================================
--  INVENTORY PANEL
-- ================================================================
local guiParent
do
    local ok, h = pcall(function() return gethui and gethui() end)
    if ok and h then guiParent = h else
        local ok2, cg = pcall(function() return game:GetService('CoreGui') end)
        guiParent = ok2 and cg or LocalPlayer:WaitForChild('PlayerGui')
    end
end
local screen = Instance.new('ScreenGui')
screen.Name = 'YazuMM2'
screen.ResetOnSpawn = false
screen.DisplayOrder = 60
screen.Parent = guiParent
onCleanup(function() screen:Destroy() end)

local panel = Instance.new('Frame')
panel.Size = UDim2.fromOffset(340, 380)
panel.Position = UDim2.new(1, -360, 0.5, -190)
panel.BackgroundColor3 = Color3.fromRGB(16, 14, 22)
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
panel.Visible = false
panel.Parent = screen
do
    local c = Instance.new('UICorner'); c.CornerRadius = UDim.new(0, 10); c.Parent = panel
    local s = Instance.new('UIStroke'); s.Color = Color3.fromRGB(255, 120, 200); s.Transparency = 0.35; s.Parent = panel
end
local title = Instance.new('TextLabel')
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(12, 6)
title.Size = UDim2.new(1, -50, 0, 26)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = 'Inventory'
title.Parent = panel
local close = Instance.new('TextButton')
close.Size = UDim2.fromOffset(26, 26)
close.Position = UDim2.new(1, -34, 0, 6)
close.BackgroundTransparency = 1
close.Text = 'x'
close.Font = Enum.Font.GothamBold
close.TextSize = 16
close.TextColor3 = Color3.fromRGB(255, 140, 180)
close.Parent = panel
connect(close.MouseButton1Click, function() panel.Visible = false end)
local scroll = Instance.new('ScrollingFrame')
scroll.Position = UDim2.fromOffset(10, 38)
scroll.Size = UDim2.new(1, -20, 1, -48)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.Parent = panel
local body = Instance.new('TextLabel')
body.BackgroundTransparency = 1
body.Size = UDim2.new(1, -6, 0, 10)
body.AutomaticSize = Enum.AutomaticSize.Y
body.Font = Enum.Font.Code
body.TextSize = 13
body.TextWrapped = true
body.RichText = true
body.TextXAlignment = Enum.TextXAlignment.Left
body.TextYAlignment = Enum.TextYAlignment.Top
body.TextColor3 = Color3.fromRGB(230, 230, 240)
body.Parent = scroll

local HEX = { Unique = 'fa8c00', Ancient = '9a5cff', Godly = 'ff00b3', Legendary = 'dc0005', Rare = '00c800',
    Uncommon = '00ffff', Common = '9a9a9a', Halloween = 'e06a10', Christmas = '1ec3be', Classic = 'e6c800' }
local function esc(s) return (tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end

local function render(name, s)
    local L = {}
    local cnt = {}
    for _, r in ipairs(Pure.RARITY_ORDER) do
        if s.counts[r] then cnt[#cnt + 1] = string.format('<font color="#%s">%s %d</font>', HEX[r] or 'ffffff', r, s.counts[r]) end
    end
    L[#L + 1] = string.format('<b>%d items</b>   score %d', s.total, Pure.score(s))
    L[#L + 1] = table.concat(cnt, '  ')
    local o = {}
    for cat, n in pairs(s.other) do o[#o + 1] = cat .. ' ' .. n end
    table.sort(o)
    if #o > 0 then L[#L + 1] = table.concat(o, '  ') end
    L[#L + 1] = ''
    local showAll = on('MM2_ShowAll')
    for _, it in ipairs(s.items) do
        local rare = (Pure.RARITY_SORT[it.rarity] or 999) <= 80 or it.chroma
        if showAll or rare then
            L[#L + 1] = string.format('<font color="#%s">%s</font>%s%s', HEX[it.rarity] or 'ffffff', esc(it.name),
                it.amount > 1 and (' x' .. it.amount) or '', it.cat == 'Pets' and '  (pet)' or '')
        end
    end
    if not showAll then L[#L + 1] = '<font color="#808090">(Godly and rarer + chromas. Turn on "Show every item" for all.)</font>' end
    title.Text = name .. "'s inventory"
    body.Text = table.concat(L, '\n')
    panel.Visible = true
end

local function plainText(name, s)
    local L = { name .. "'s inventory (" .. s.total .. ' items)' }
    for _, it in ipairs(s.items) do
        L[#L + 1] = string.format('%s [%s]%s', it.name, it.rarity, it.amount > 1 and (' x' .. it.amount) or '')
    end
    return table.concat(L, '\n')
end

-- ================================================================
--  SERVERS
-- ================================================================
local function fetchServers(maxPages)
    local list, cursor = {}, nil
    for _ = 1, maxPages or 3 do
        local url = string.format('https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s',
            game.PlaceId, cursor and ('&cursor=' .. cursor) or '')
        local ok, raw = pcall(function() return game:HttpGet(url) end)
        if not ok then return list, 'could not reach the server list' end
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if not ok2 or type(data) ~= 'table' then return list, 'bad server list reply' end
        for _, s in ipairs(data.data or {}) do list[#list + 1] = s end
        cursor = data.nextPageCursor
        if not cursor then break end
    end
    return list
end

local function hop(mode)
    task.spawn(function()
        notify('Looking for a server...', 3)
        local list, err = fetchServers(3)
        local pick = Pure.pickServer(list, mode, game.JobId)
        if not pick then notify('No server found' .. (err and (': ' .. err) or ''), 5) return end
        notify(string.format('Joining server with %d/%d players', pick.playing, pick.maxPlayers), 4)
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, pick.id, LocalPlayer) end)
    end)
end

local function rejoin()
    if #Players:GetPlayers() <= 1 then
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    else
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end
end

-- ================================================================
--  UI
-- ================================================================
local InvGrp    = Tab:AddLeftGroupbox('Player inventory')
local ServerGrp = Tab:AddRightGroupbox('Servers')
local MiscGrp   = Tab:AddRightGroupbox('Quality of life')

InvGrp:AddDropdown('MM2_Player', { Text = 'Player', SpecialType = 'Player', Default = 1 })
InvGrp:AddButton({ Text = 'View inventory', Func = function()
    local name = opt('MM2_Player')
    if type(name) ~= 'string' or name == '' then notify('Pick a player first', 3) return end
    task.spawn(function()
        local s, err = inventoryOf(name, true)
        if not s then notify('Inventory: ' .. tostring(err), 5) return end
        render(name, s)
    end)
end })
InvGrp:AddButton({ Text = 'Copy inventory to clipboard', Func = function()
    local name = opt('MM2_Player')
    task.spawn(function()
        local s, err = inventoryOf(name)
        if not s then notify('Inventory: ' .. tostring(err), 5) return end
        if setclipboard then setclipboard(plainText(name, s)); notify('Copied ' .. name .. "'s inventory", 3)
        else notify('Your executor has no setclipboard', 4) end
    end)
end })
InvGrp:AddToggle('MM2_ShowAll', { Text = 'Show every item (not just godlies)', Default = false })
InvGrp:AddButton({ Text = 'Rank everyone in this server', Func = function()
    task.spawn(function()
        local rows = {}
        for _, p in ipairs(Players:GetPlayers()) do
            local s = inventoryOf(p.Name)
            if s then
                local h = Pure.highlights(s, 3)
                local names = {}
                for _, it in ipairs(h) do names[#names + 1] = it.name end
                rows[#rows + 1] = { p.Name, Pure.score(s), s.counts.Godly or 0, s.counts.Ancient or 0, table.concat(names, ', ') }
            end
            task.wait(0.4) -- gentle on the server
        end
        table.sort(rows, function(a, b) return a[2] > b[2] end)
        local L = {}
        for i, r in ipairs(rows) do
            L[#L + 1] = string.format('%d. <b>%s</b>  score %d  <font color="#ff00b3">G %d</font> <font color="#9a5cff">A %d</font>\n   %s',
                i, esc(r[1]), r[2], r[3], r[4], esc(r[5]))
        end
        title.Text = 'Server ranking'
        body.Text = #L > 0 and table.concat(L, '\n') or 'No inventories came back.'
        panel.Visible = true
    end)
end })

ServerGrp:AddButton({ Text = 'Rejoin this server', Func = function() pcall(rejoin) end })
ServerGrp:AddButton({ Text = 'Server hop (random)', Func = function() hop('random') end })
ServerGrp:AddButton({ Text = 'Join smallest server', Func = function() hop('smallest') end })
ServerGrp:AddButton({ Text = 'Join fullest server', Func = function() hop('largest') end })
ServerGrp:AddButton({ Text = 'Copy server id', Func = function()
    if setclipboard then setclipboard(game.JobId); notify('Server id copied', 3) end
end })
ServerGrp:AddInput('MM2_JobId', { Text = 'Join server id', Default = '', Placeholder = 'paste a server id', Finished = true,
    Callback = function(v)
        if type(v) == 'string' and #v > 10 then
            pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, v, LocalPlayer) end)
        end
    end })
ServerGrp:AddToggle('MM2_AutoRejoin', { Text = 'Auto rejoin when disconnected', Default = false })

MiscGrp:AddToggle('MM2_AntiAfk', { Text = 'Anti AFK kick', Default = true })
MiscGrp:AddToggle('MM2_FpsBoost', { Text = 'FPS boost (hide particles, shadows)', Default = false })

-- ================================================================
--  LOOPS / HOOKS
-- ================================================================
connect(LocalPlayer.Idled, function()
    if not on('MM2_AntiAfk') then return end
    pcall(function()
        local vu = game:GetService('VirtualUser')
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
    end)
end)

connect(GuiService.ErrorMessageChanged, function()
    if not on('MM2_AutoRejoin') then return end
    task.wait(2)
    pcall(rejoin)
end)

local boosted = {}
local function applyBoost()
    local onNow = on('MM2_FpsBoost')
    local L = game:GetService('Lighting')
    if onNow then
        boosted.shadows = boosted.shadows == nil and L.GlobalShadows or boosted.shadows
        L.GlobalShadows = false
        for _, d in ipairs(workspace:GetDescendants()) do
            if (d:IsA('ParticleEmitter') or d:IsA('Trail') or d:IsA('Smoke') or d:IsA('Fire') or d:IsA('Sparkles')) and d.Enabled then
                d.Enabled = false
                boosted[d] = true
            end
        end
    else
        if boosted.shadows ~= nil then L.GlobalShadows = boosted.shadows end
        for d in pairs(boosted) do
            if typeof(d) == 'Instance' and d.Parent then pcall(function() d.Enabled = true end) end
        end
        boosted = {}
    end
end
if Toggles.MM2_FpsBoost then Toggles.MM2_FpsBoost:OnChanged(applyBoost) end
onCleanup(function() if on('MM2_FpsBoost') then Toggles.MM2_FpsBoost:SetValue(false) end end)

notify('Yazu MM2 loaded', 3)

end
