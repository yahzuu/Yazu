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

local Window = Library:CreateWindow({ Title = 'Yazu', Center = true, AutoShow = true })

UserInputService.MouseIcon = ''
RunService.RenderStepped:Connect(function()
    if UserInputService.MouseIcon ~= '' then UserInputService.MouseIcon = '' end
end)

-- ── 4. Tabs ───────────────────────────────────────────────────
local placeId = game.PlaceId

local Tabs = {
    Aimbot          = Window:AddTab('Aimbot'),
    ESP             = Window:AddTab('ESP'),
    Misc            = Window:AddTab('Misc'),
    ['UI Settings'] = Window:AddTab('UI Settings'),
}

if placeId == 185655149 then
    Tabs.BXBRG = Window:AddTab('BXBRG')
end

-- ── 5. Features ───────────────────────────────────────────────
load('features/aimbot.lua')(State, Tabs, Services, Library)
load('features/esp.lua')(State, Tabs, Services, Library)
load('features/misc.lua')(State, Tabs, Services, Library)

local placeFeatures = {
    [1537690962] = 'features/bloxburg.lua',
}

if placeFeatures[placeId] then
    load(placeFeatures[placeId])(State, Tabs, Services, Library)
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
