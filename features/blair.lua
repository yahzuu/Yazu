-- ================================================================
--  features/blair.lua
--  Complete & Robust Blair Integration for Yazu
--  Target Place ID: 5370213192
-- ================================================================

return function(State, Tabs, Services, Library)

-- ── 1. DEPENDENCIES ───────────────────────────────────────────
local RunService    = Services.RunService
local Players       = Services.Players
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage
local UserInput     = Services.UserInputService

-- ── 2. UI SETUP (LinoriaLib) ──────────────────────────────────
local BlairTab = Tabs.Blair
local MainGrp  = BlairTab:AddLeftGroupbox('Player Hacks')
local VisGrp   = BlairTab:AddLeftGroupbox('Visuals')
local EvidGrp  = BlairTab:AddRightGroupbox('Ghost & Evidence')
local MiscGrp  = BlairTab:AddRightGroupbox('Miscellaneous')

-- ── 3. INTERNAL CACHE & HELPERS ───────────────────────────────
local Internal = {
    OriginalSanitySet = nil,
    CrosshairLines    = {},
    CachedGhost       = nil,
    LastNotification  = 0
}

-- Safe module fetcher to prevent script crashes
local function GetBlairModule(name)
    local shared = RepStorage:FindFirstChild("SharedData")
    if not shared then return nil end
    
    local module = shared:FindFirstChild(name)
    if module and module:IsA("ModuleScript") then
        local success, result = pcall(require, module)
        return success and result or nil
    end
    return nil
end

-- Notification helper to avoid spam
local function Notify(msg)
    if os.clock() - Internal.LastNotification > 3 then
        Library:Notify("[BLAIR] " .. msg, 3)
        Internal.LastNotification = os.clock()
    end
end

-- ── 4. CROSSHAIR SYSTEM ───────────────────────────────────────
local function SetupCrosshair()
    local hLine = Drawing.new("Line")
    local vLine = Drawing.new("Line")
    
    hLine.Thickness = 2
    hLine.Color = Color3.fromRGB(255, 0, 0)
    vLine.Thickness = 2
    vLine.Color = Color3.fromRGB(255, 0, 0)
    
    Internal.CrosshairLines = {hLine, vLine}
end
SetupCrosshair()

local function UpdateCrosshair()
    local enabled = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value
    local h, v = Internal.CrosshairLines[1], Internal.CrosshairLines[2]
    
    h.Visible = enabled
    v.Visible = enabled
    
    if enabled then
        local vpSize = workspace.CurrentCamera.ViewportSize
        local center = Vector2.new(vpSize.X / 2, vpSize.Y / 2)
        
        h.From = center - Vector2.new(12, 0)
        h.To   = center + Vector2.new(12, 0)
        
        v.From = center - Vector2.new(0, 12)
        v.To   = center + Vector2.new(0, 12)
    end
end

-- ── 5. TOGGLE CALLBACKS ───────────────────────────────────────

local function ToggleSanity(val)
    local mod = GetBlairModule("SanityMonitor")
    if not mod then return end
    
    if val then
        Internal.OriginalSanitySet = mod.setSanity
        mod.setSanity = function(val)
            -- Force sanity to stay at 100 regardless of what the game wants
            return Internal.OriginalSanitySet(100)
        end
        Notify("Sanity Frozen at 100%")
    else
        if Internal.OriginalSanitySet then
            mod.setSanity = Internal.OriginalSanitySet
        end
    end
end

-- ── 6. UI ELEMENTS ────────────────────────────────────────────

MainGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })
MainGrp:AddToggle('Blair_SanityFreeze', { Text = 'Sanity Freeze', Default = false, Callback = ToggleSanity })

VisGrp:AddToggle('Blair_FullBright', { Text = 'Full Bright', Default = false })
VisGrp:AddToggle('Blair_Crosshair', { Text = 'Crosshair Overlay', Default = false })
VisGrp:AddToggle('Blair_NoFlashDrain', { Text = 'No Flashlight Drain', Default = false })

EvidGrp:AddToggle('Blair_AutoLog', { Text = 'Auto Evidence Logger', Default = false })
EvidGrp:AddToggle('Blair_WritingInd', { Text = 'Ghost Writing Indicator', Default = false })
EvidGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })

MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam', { Text = 'Radio Spammer', Default = false })

-- ── 7. MAIN FEATURE LOOPS ─────────────────────────────────────

RunService.Heartbeat:Connect(function()
    -- 1. Infinite Stamina (Injects into PlayerController)
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        local gameDir = pGui and pGui:FindFirstChild("Game")
        if gameDir and gameDir:FindFirstChild("PlayerController") then
            local controller = require(gameDir.PlayerController)
            if controller then controller.Sprint = 0.5 end
        end
    end

    -- 2. Fast Interaction (Instant Proximity Prompts)
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, v in next, workspace:GetDescendants() do
            if v:IsA("ProximityPrompt") then
                v.HoldDuration = 0
            end
        end
    end

    -- 3. Full Bright (Ambient Override)
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        local light = GetBlairModule("LightPartRemote")
        if light then light.OverrideAmbient = true end
    end

    -- 4. No Flashlight Drain
    if Toggles.Blair_NoFlashDrain and Toggles.Blair_NoFlashDrain.Value then
        local fl = GetBlairModule("Flashlight")
        if fl then fl.Intensity = 1 end
    end

    -- 5. Crosshair Refresh
    UpdateCrosshair()

    -- 6. Evidence Logic
    if Toggles.Blair_AutoLog and Toggles.Blair_AutoLog.Value then
        local emf = GetBlairModule("EMFLocalCore")
        local thermo = GetBlairModule("ThermometerLocalCore")
        if emf and emf.EvidenceFound then Notify("EMF Level 5 Found!") end
        if thermo and thermo.TemperatureDrop then Notify("Freezing Temperatures!") end
    end

    if Toggles.Blair_WritingInd and Toggles.Blair_WritingInd.Value then
        local book = GetBlairModule("GhostWritingBook")
        if book and book.EvidenceFound then Notify("Ghost Writing Evidence Found!") end
    end
end)

-- 8. GHOST ESP LOOP (High Performance)
task.spawn(function()
    while true do
        task.wait(0.5) -- Lower frequency to save FPS
        if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
            for _, obj in next, workspace:GetChildren() do
                -- Blair ghosts are usually named "Ghost" or "The [Name]"
                if obj:IsA("Model") and (obj.Name:find("Ghost") or obj:FindFirstChild("GhostData")) then
                    if not obj:FindFirstChild("YazuHighlight") then
                        local h = Instance.new("Highlight")
                        h.Name = "YazuHighlight"
                        h.FillColor = Color3.fromRGB(255, 0, 0)
                        h.OutlineColor = Color3.fromRGB(255, 255, 255)
                        h.Adornee = obj
                        h.Parent = obj
                    end
                end
            end
        else
            -- Cleanup
            for _, obj in next, workspace:GetChildren() do
                local h = obj:FindFirstChild("YazuHighlight")
                if h then h:Destroy() end
            end
        end
    end
end)

-- 9. RADIO SPAMMER
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            local radio = GetBlairModule("RadioRemote")
            if radio and radio.SendSignal then
                pcall(function() radio.SendSignal("Yazu Framework Protocol Active") end)
            end
        end
    end
end)

end
