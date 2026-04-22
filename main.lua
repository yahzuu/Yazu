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

local Window = Library:CreateWindow({ Title = 'Yazu 0.0111 ', Center = true, AutoShow = true })

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
safeLoad('features/misc.lua')
safeLoad('features/dumper.lua')

local placeFeatures = {
    [185655149] = 'features/bloxburg.lua',
    [6137321701] = 'features/blair.lua',
    [6348640020] = 'features/blair.lua',
}

if placeFeatures[placeId] then
    safeLoad(placeFeatures[placeId])
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
ThemeManager:SetFolder('Yazu')
SaveManager:SetFolder('Yazu/configs')
SaveManager:BuildConfigSection(Tabs['UI Settings'])
ThemeManager:ApplyToTab(Tabs['UI Settings'])
SaveManager:LoadAutoloadConfig()

print("version0.01")
