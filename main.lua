-- ================================================================
--  Yazu | main.lua  —  THE ONLY FILE USERS EXECUTE
--  All other files are loaded from your GitHub repo below.
-- ================================================================

local repo = 'https://raw.githubusercontent.com/yahzuu/Yazu/main/'

local function load(path)
    return loadstring(game:HttpGet(repo .. path))()
end

-- ── 1. UI Library ─────────────────────────────────────────────
local libRepo      = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'
local Library      = loadstring(game:HttpGet(libRepo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(libRepo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(libRepo .. 'addons/SaveManager.lua'))()

-- ── 2. Services & shared state ────────────────────────────────
local Services = load('core/services.lua')
local State    = load('core/state.lua')

-- ── 3. Window ─────────────────────────────────────────────────
local RunService       = Services.RunService
local UserInputService = Services.UserInputService

local Window = Library:CreateWindow({ Title = 'Yazu 0.0126 ', Center = true, AutoShow = true })

UserInputService.MouseIcon = ''
RunService.RenderStepped:Connect(function()
    if UserInputService.MouseIcon ~= '' then UserInputService.MouseIcon = '' end
end)

-- ── 4. Tabs ───────────────────────────────────────────────────
local placeId = game.PlaceId

local Tabs = {
    Aimbot = Window:AddTab('Aimbot'),
    ESP    = Window:AddTab('ESP'),
    Misc   = Window:AddTab('Misc'),
    Dumper = Window:AddTab('Dumper'),
    
}

-- Place-specific tabs added BEFORE UI Settings
if placeId == 185655149 then
    Tabs.BXBRG = Window:AddTab('BXBRG')
end

if placeId == 6137321701 then
    Tabs.blair = Window:AddTab('blair')
end

if placeId == 6348640020 then
    Tabs.blair = Window:AddTab('blair')
end

if placeId == 10266164381 then
    Tabs.bloodlines = Window:AddTab('bloodlines')
end

-- Basketball: matches either the place id or the universe (game) id.
local BASKETBALL_ID = 80681221431821
local isBasketball = placeId == BASKETBALL_ID or game.GameId == BASKETBALL_ID
if isBasketball then
    Tabs.Basketball = Window:AddTab('Basketball')
end
-- UI Settings must always be last
Tabs['UI Settings'] = Window:AddTab('UI Settings')

-- ── 5. Features ───────────────────────────────────────────────
-- Each feature is wrapped in pcall so one failing cannot block the others

local function safeLoad(path)
    local ok, err = pcall(function()
        load(path)(State, Tabs, Services, Library)
    end)
    if not ok then
        warn('[Yazu] Failed to load ' .. path .. ': ' .. tostring(err))
    end
end

safeLoad('features/aimbot.lua')
safeLoad('features/esp.lua')
-- >>> misc toggle capture
local togglesBeforeMisc = {}
for idx in pairs(Toggles) do togglesBeforeMisc[idx] = true end
safeLoad('features/misc.lua')
-- Every toggle misc.lua just created that starts off. Toggles that start on by design
-- (for example DesyncAutoOff, a safety option) are left alone.
local MiscToggleIds = {}
for idx, toggle in pairs(Toggles) do
    if not togglesBeforeMisc[idx] and toggle.Value == false then MiscToggleIds[#MiscToggleIds + 1] = idx end
end
table.sort(MiscToggleIds)
-- <<< misc toggle capture
safeLoad('features/dumper.lua')
safeLoad('features/game_dumper.lua')
safeLoad('features/universal_dumper.lua')

local placeFeatures = {
    [185655149] = 'features/bloxburg.lua',
    [6137321701] = 'features/blair.lua',
    [6348640020] = 'features/blair.lua',
    [10266164381] = 'features/bloodlines.lua',
}

if placeFeatures[placeId] then
    safeLoad(placeFeatures[placeId])
end

if isBasketball then
    safeLoad('features/basketball.lua')
end

-- ── 6. UI Settings tab ────────────────────────────────────────
local UIGrp = Tabs['UI Settings']:AddRightGroupbox('Menu')
UIGrp:AddButton({ Text = 'Unload', Func = function() Library:Unload() end })
UIGrp:AddLabel('Toggle Key'):AddKeyPicker('MenuKeybind', { Default = 'End', NoUI = true, Text = 'Menu Keybind' })
Library.ToggleKeybind = Options.MenuKeybind

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ 'MenuKeybind' })
SaveManager:SetIgnoreIndexes(MiscToggleIds)
ThemeManager:SetFolder('Yazu')
SaveManager:SetFolder('Yazu/configs')
SaveManager:BuildConfigSection(Tabs['UI Settings'])
ThemeManager:ApplyToTab(Tabs['UI Settings'])
-- >>> autoload gate
-- A saved config must never switch a Misc feature on (Fly, Desync, Null Strike, ...).
-- During the autoload, SetValue(true) is ignored for those toggles; saved sliders and
-- dropdowns still load. A short follow-up pass turns off anything that slipped through.
local gatedSetValue = {}
for _, idx in ipairs(MiscToggleIds) do
    local toggle = Toggles[idx]
    if toggle and type(toggle.SetValue) == 'function' then
        local original = toggle.SetValue
        gatedSetValue[idx] = original
        toggle.SetValue = function(self, value)
            if value then return end
            return original(self, value)
        end
    end
end
SaveManager:LoadAutoloadConfig()
for idx, original in pairs(gatedSetValue) do Toggles[idx].SetValue = original end
task.delay(1.5, function()
    for _, idx in ipairs(MiscToggleIds) do
        local toggle = Toggles[idx]
        if toggle and toggle.Value then toggle:SetValue(false) end
    end
end)
-- <<< autoload gate

print("version0.0126")
