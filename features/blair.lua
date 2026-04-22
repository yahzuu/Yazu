-- ================================================================
--  features/blair.lua
--  FULLY LOADED BLAIR MODULE FOR YAZU
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService    = Services.RunService
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage

-- ── 1. DYNAMIC TAB RECOVERY ───────────────────────────────────
-- Since your main.lua skips the Blair tab check, this adds it manually
local BlairTab = Tabs.Blair or Tabs.blair
if not BlairTab then
    BlairTab = Tabs.Misc:AddLeftGroupbox('Blair Features')
    Library:Notify("Blair Tab missing in main.lua - Loading in Misc")
end

-- ── 2. UI GROUPS ──────────────────────────────────────────────
local MainGrp  = BlairTab:AddLeftGroupbox('Character')
local VisGrp   = BlairTab:AddLeftGroupbox('Visuals')
local GhostGrp = BlairTab:AddRightGroupbox('Ghost & Evidence')
local MiscGrp  = BlairTab:AddRightGroupbox('Miscellaneous')

-- ── 3. INTERNAL CACHE & HELPERS ───────────────────────────────
local Internal = {
    CrosshairLines = {},
    LastAlert      = 0,
    OriginalSanity = nil
}

local function GetMod(name)
    local s = RepStorage:FindFirstChild("SharedData")
    local m = s and s:FindFirstChild(name)
    if m then
        local ok, res = pcall(require, m)
        return ok and res or nil
    end
    return nil
end

-- ── 4. UI ELEMENTS (EVERY FEATURE) ────────────────────────────
MainGrp:AddToggle('Blair_InfStamina',   { Text = 'Infinite Stamina', Default = false })
MainGrp:AddToggle('Blair_SanityFreeze', { Text = 'Sanity Freeze (100%)', Default = false })

VisGrp:AddToggle('Blair_FullBright',    { Text = 'Full Bright', Default = false })
VisGrp:AddToggle('Blair_NoFlashDrain',  { Text = 'No Flashlight Drain', Default = false })
VisGrp:AddToggle('Blair_Crosshair',     { Text = 'Crosshair Overlay', Default = false })

GhostGrp:AddToggle('Blair_AutoLog',     { Text = 'Auto Evidence Logger', Default = false })
GhostGrp:AddToggle('Blair_WritingInd',  { Text = 'Evidence Indicator', Default = false })
GhostGrp:AddToggle('Blair_GhostESP',    { Text = 'Ghost ESP', Default = false })

MiscGrp:AddToggle('Blair_FastInteract', { Text = 'Fast Interaction', Default = false })
MiscGrp:AddToggle('Blair_RadioSpam',    { Text = 'Radio Spammer', Default = false })

-- ── 5. MAIN LOGIC ─────────────────────────────────────────────

-- Crosshair Setup
Internal.CrosshairLines[1] = Drawing.new("Line")
Internal.CrosshairLines[2] = Drawing.new("Line")

RunService.Heartbeat:Connect(function()
    -- [1] Infinite Stamina
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        local ctrl = pGui and pGui:FindFirstChild("Game") and pGui.Game:FindFirstChild("PlayerController")
        if ctrl then
            local ok, mod = pcall(require, ctrl)
            if ok then mod.Sprint = 0.5 end
        end
    end

    -- [2] Sanity Freeze
    if Toggles.Blair_SanityFreeze and Toggles.Blair_SanityFreeze.Value then
        local mod = GetMod("SanityMonitor")
        if mod and mod.setSanity then
            pcall(function() mod.setSanity(100) end)
        end
    end

    -- [3] Auto Evidence Logger
    if Toggles.Blair_AutoLog and Toggles.Blair_AutoLog.Value then
        local emf = GetMod("EMFLocalCore")
        local thermo = GetMod("ThermometerLocalCore")
        if (emf and emf.EvidenceFound) or (thermo and thermo.TemperatureDrop) then
            if os.clock() - Internal.LastAlert > 5 then
                Library:Notify("[EVIDENCE] Detected EMF/Temp Drop!", 3)
                Internal.LastAlert = os.clock()
            end
        end
    end

    -- [4] Fast Interaction
    if Toggles.Blair_FastInteract and Toggles.Blair_FastInteract.Value then
        for _, p in next, workspace:GetDescendants() do
            if p:IsA("ProximityPrompt") then p.HoldDuration = 0 end
        end
    end

    -- [5] Crosshair Overlay
    local cross = Toggles.Blair_Crosshair and Toggles.Blair_Crosshair.Value
    local l1, l2 = Internal.CrosshairLines[1], Internal.CrosshairLines[2]
    l1.Visible = cross; l2.Visible = cross
    if cross then
        local center = workspace.CurrentCamera.ViewportSize / 2
        l1.Color = Color3.new(1,0,0); l1.Thickness = 2
        l1.From = center - Vector2.new(10,0); l1.To = center + Vector2.new(10,0)
        l2.Color = Color3.new(1,0,0); l2.Thickness = 2
        l2.From = center - Vector2.new(0,10); l2.To = center + Vector2.new(0,10)
    end

    -- [6] No Flashlight Drain
    if Toggles.Blair_NoFlashDrain and Toggles.Blair_NoFlashDrain.Value then
        local mod = GetMod("Flashlight")
        if mod then mod.Intensity = 1 end
    end

    -- [9] Full Bright
    if Toggles.Blair_FullBright and Toggles.Blair_FullBright.Value then
        local mod = GetMod("LightPartRemote")
        if mod then mod.OverrideAmbient = true end
    end

    -- [10] Evidence Indicator
    if Toggles.Blair_WritingInd and Toggles.Blair_WritingInd.Value then
        local mod = GetMod("GhostWritingBook")
        if mod and mod.EvidenceFound and os.clock() - Internal.LastAlert > 5 then
            Library:Notify("[EVIDENCE] Ghost Writing Detected!", 3)
            Internal.LastAlert = os.clock()
        end
    end
end)

-- [7] Radio Spammer (Threaded)
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_RadioSpam and Toggles.Blair_RadioSpam.Value then
            local mod = GetMod("RadioRemote")
            if mod and mod.SendSignal then pcall(function() mod.SendSignal("Yazu Spam") end) end
        end
    end
end)

-- [8] Ghost ESP (Threaded)
task.spawn(function()
    while true do
        task.wait(1)
        if Toggles.Blair_GhostESP and Toggles.Blair_GhostESP.Value then
            for _, v in next, workspace:GetChildren() do
                if v:IsA("Model") and (v.Name:find("Ghost") or v:FindFirstChild("GhostData")) then
                    if not v:FindFirstChild("YazuESP") then
                        local h = Instance.new("Highlight", v)
                        h.Name = "YazuESP"
                        h.FillColor = Color3.new(1,0,0)
                    end
                end
            end
        else
            for _, v in next, workspace:GetChildren() do
                if v:FindFirstChild("YazuESP") then v.YazuESP:Destroy() end
            end
        end
    end
end)

Library:Notify("Blair Fully Loaded - All 11 Features Active")

end
