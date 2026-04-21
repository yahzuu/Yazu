-- ================================================================
--  Yazu | main.lua  —  THE ONLY FILE USERS EXECUTE
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

-- [FIX 1] Prevent Dumper crash if Library:Notify is missing
if not Library.Notify then
    Library.Notify = function(self, text, time)
        print("[Yazu Notification]: " .. tostring(text))
        -- Optional: Use startergui if you want a real popup
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "Yazu";
            Text = text;
            Duration = time or 5;
        })
    end
end

-- ── 2. Services & shared state ────────────────────────────────
local Services = load('core/services.lua')
local State    = load('core/state.lua')
local Toggles, Options = getgenv().Toggles, getgenv().Options -- [FIX 2] Ensure visibility

-- ── 3. Window ─────────────────────────────────────────────────
local RunService       = Services.RunService
local UserInputService = Services.UserInputService

local Window = Library:CreateWindow({ Title = 'Yazu 0.011 ', Center = true, AutoShow = true })

-- Mouse icon lock
RunService.RenderStepped:Connect(function()
    if UserInputService.MouseIconEnabled then UserInputService.MouseIconEnabled = false end
end)

-- ── 4. Tabs ───────────────────────────────────────────────────
local placeId = game.PlaceId

local Tabs = {
    Aimbot = Window:AddTab('Aimbot'),
    ESP    = Window:AddTab('ESP'),
    Misc   = Window:AddTab('Misc'),
    Dumper = Window:AddTab('Dumper'),
}

if placeId == 185655149 then
    Tabs.BXBRG = Window:AddTab('BXBRG')
end

Tabs['UI Settings'] = Window:AddTab('UI Settings')

-- ── 5. Features ───────────────────────────────────────────────
-- [FIX 3] Wrap in pcall so one broken feature doesn't stop the whole script
local function safeLoad(path, ...)
    local success, func = pcall(function() return load(path) end)
    if success and type(func) == "function" then
        local ok, err = pcall(function() func(...) end)
        if not ok then warn("Feature Error ["..path.."]: "..tostring(err)) end
    else
        warn("Failed to load feature path: "..path)
    end
end

safeLoad('features/aimbot.lua', State, Tabs, Services, Library)
safeLoad('features/esp.lua', State, Tabs, Services, Library)
safeLoad('features/misc.lua', State, Tabs, Services, Library)
safeLoad('features/dumper.lua', State, Tabs, Services, Library)

if placeId == 185655149 then
    safeLoad('features/bloxburg.lua', State, Tabs, Services, Library)
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

print("Yazu Loaded Successfully")
