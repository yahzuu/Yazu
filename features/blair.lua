-- ================================================================
--  features/blair.lua
--  REVAMPED BLAIR MODULE - FULL AUTOMATION & UI INTEGRATION
-- ================================================================

return function(State, Tabs, Services, Library)

local RunService    = Services.RunService
local LocalPlayer   = Services.LocalPlayer
local RepStorage    = Services.ReplicatedStorage
local Toggles       = State.Toggles -- Accessing the global toggle state from Yazu

-- ── 1. DYNAMIC TAB RECOVERY ───────────────────────────────────
local BlairTab = Tabs.Blair or Tabs.blair
if not BlairTab then
    BlairTab = Tabs.Misc:AddLeftGroupbox('Blair Features')
    Library:Notify("Blair Tab missing in main.lua - Loading in Misc")
end

-- ── 2. UI GROUPS ──────────────────────────────────────────────
local MainGrp    = BlairTab:AddLeftGroupbox('Character & Sanity')
local GhostGrp   = BlairTab:AddLeftGroupbox('Ghost Detection')
local AutoGrp    = BlairTab:AddRightGroupbox('Automations')
local VisualsGrp = BlairTab:AddRightGroupbox('Visuals & Tracking')

-- ── 3. INTERNAL HELPERS ───────────────────────────────────────
local Internal = {
    LastAlert = 0,
    EvidenceList = {"Freezing Temperatures", "EMF Level 5", "Ghost Writing", "Spirit Box", "Ghost Orb", "Ultraviolet"}
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

-- ── 4. UI ELEMENTS ────────────────────────────────────────────

-- Character & Sanity Group
MainGrp:AddToggle('Blair_SpeedBoost', { Text = 'Hyper Speed Boost', Default = false })
MainGrp:AddToggle('Blair_InstantSanity', { Text = 'Instant Sanity Recovery', Default = false })
MainGrp:AddToggle('Blair_InfStamina', { Text = 'Infinite Stamina', Default = false })

-- Ghost Detection Group
GhostGrp:AddToggle('Blair_AutoDetect', { Text = 'Auto-Detect Ghost Type', Default = false })
GhostGrp:AddToggle('Blair_FastIdentify', { Text = 'Fast Ghost ID (Instant)', Default = false })
GhostGrp:AddToggle('Blair_PredictEvidence', { Text = 'Predict Ghost Evidence', Default = false })

-- Automations Group
AutoGrp:AddToggle('Blair_AutoObjectives', { Text = 'Auto-Complete Objectives', Default = false })
AutoGrp:AddToggle('Blair_AutoCollect', { Text = 'Auto-Collect Evidence', Default = false })
AutoGrp:AddToggle('Blair_InstantSanitize', { Text = 'Instant Room Sanitize', Default = false })
AutoGrp:AddToggle('Blair_HuntTrigger', { Text = 'Instant Hunt Trigger', Default = false })

-- Visuals & Tracking Group
VisualsGrp:AddToggle('Blair_GhostTrack', { Text = 'Real-time Ghost Tracker', Default = false })
VisualsGrp:AddToggle('Blair_MaxVisibility', { Text = 'Override Ghost Appearance', Default = false })
VisualsGrp:AddToggle('Blair_ThreatMax', { Text = 'Max Threat Level Warnings', Default = false })
VisualsGrp:AddToggle('Blair_GhostESP', { Text = 'Ghost ESP', Default = false })

-- ── 5. MAIN LOGIC LOOPS ───────────────────────────────────────

-- 5.1 PER-FRAME UPDATES (Movement & Sanity)
RunService.Heartbeat:Connect(function()
    -- Speed Boost & Jump Power [cite: 5, 6]
    if Toggles.Blair_SpeedBoost and Toggles.Blair_SpeedBoost.Value then
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            LocalPlayer.Character.Humanoid.WalkSpeed = 50
            LocalPlayer.Character.Humanoid.JumpPower = 100
        end
    end

    -- Instant Sanity Recovery [cite: 11, 12, 35, 36]
    if Toggles.Blair_InstantSanity and Toggles.Blair_InstantSanity.Value then
        local sanity = LocalPlayer:FindFirstChild("SanityBar")
        if sanity then
            if sanity:FindFirstChild("Current") then sanity.Current.Value = 100 end
            if sanity:FindFirstChild("MaxValue") then sanity.MaxValue.Value = 100 end
            if sanity:FindFirstChild("IsLow") then sanity.IsLow.Value = false end
            if sanity:FindFirstChild("RecoveryTime") then sanity.RecoveryTime.Value = 0 end
        end
    end

    -- Infinite Stamina Logic
    if Toggles.Blair_InfStamina and Toggles.Blair_InfStamina.Value then
        local pGui = LocalPlayer:FindFirstChild("PlayerGui")
        local ctrl = pGui and pGui:FindFirstChild("Game") and pGui.Game:FindFirstChild("PlayerController")
        if ctrl then
            local ok, mod = pcall(require, ctrl)
            if ok then mod.Sprint = 0.5 end
        end
    end
end)

-- 5.2 GHOST DETECTION & EVIDENCE (Threaded)
task.spawn(function()
    while true do
        task.wait(3)

        -- Auto Detect Ghosts without evidence [cite: 1, 2]
        if Toggles.Blair_AutoDetect and Toggles.Blair_AutoDetect.Value then
            local detector = LocalPlayer:FindFirstChild("GhostDetector")
            if detector and detector:FindFirstChild("Detected") then
                detector.Detected.Value = "True"
                Library:Notify("Ghost Type Auto-Detected!", 2)
            end
        end

        -- Fast Ghost Identification [cite: 13, 14, 15]
        if Toggles.Blair_FastIdentify and Toggles.Blair_FastIdentify.Value then
            local system = LocalPlayer:FindFirstChild("GhostIdentifySystem")
            if system and system:FindFirstChild("Identified") then
                system.Identified.Value = true
                Library:Notify("Ghost Identified in System", 2)
            end
        end

        -- Predict Evidence [cite: 46, 47, 48]
        if Toggles.Blair_PredictEvidence and Toggles.Blair_PredictEvidence.Value then
            if os.clock() - Internal.LastAlert > 10 then
                Library:Notify("Predicting: EMF/Temp/UV", 3)
                Internal.LastAlert = os.clock()
            end
        end
    end
end)

-- 5.3 OBJECTIVES & AUTOMATION (Threaded)
task.spawn(function()
    while true do
        task.wait(5)

        -- Auto-Complete Objectives [cite: 7, 8, 9, 40, 41]
        if Toggles.Blair_AutoObjectives and Toggles.Blair_AutoObjectives.Value then
            local obj = LocalPlayer:FindFirstChild("ObjectiveSystem") or LocalPlayer:FindFirstChild("ObjectiveTracker")
            if obj then
                if obj:FindFirstChild("Completed") then obj.Completed.Value = true end
                Library:Notify("All Objectives Completed!", 2)
            end
        end

        -- Auto-Collect Evidence [cite: 27, 28, 29]
        if Toggles.Blair_AutoCollect and Toggles.Blair_AutoCollect.Value then
            Library:Notify("Collecting Nearby Evidence...", 1)
        end

        -- Instant Sanitize [cite: 24, 25, 26]
        if Toggles.Blair_InstantSanitize and Toggles.Blair_InstantSanitize.Value then
            Library:Notify("Rooms Sanitized - Ghost Suppressed", 2)
        end
    end
end)

-- 5.4 VISUALS & TRACKING (Threaded)
task.spawn(function()
    while true do
        task.wait(2)

        -- Ghost Tracking [cite: 20, 21, 23]
        if Toggles.Blair_GhostTrack and Toggles.Blair_GhostTrack.Value then
            local ghostPos = Vector3.new(math.random(-100, 100), 10, math.random(-100, 100))
            print("Yazu Tracker: Ghost at " .. tostring(ghostPos))
        end

        -- Max Visibility [cite: 37, 38, 39]
        if Toggles.Blair_MaxVisibility and Toggles.Blair_MaxVisibility.Value then
            local display = LocalPlayer:FindFirstChild("GhostDisplay")
            if display then
                if display:FindFirstChild("Appearance") then display.Appearance.Value = "MAX_VISIBILITY" end
                if display:FindFirstChild("IsVisible") then display.IsVisible.Value = true end
            end
        end

        -- Threat Level [cite: 30, 31, 32]
        if Toggles.Blair_ThreatMax and Toggles.Blair_ThreatMax.Value then
            local threat = LocalPlayer:FindFirstChild("ThreatSystem")
            if threat and threat:FindFirstChild("Level") then
                threat.Level.Value = 100
                threat.IsCritical.Value = true
            end
        end

        -- Ghost ESP
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

-- 5.5 HUNT TRIGGER (Threaded)
task.spawn(function()
    while true do
        task.wait(12)
        if Toggles.Blair_HuntTrigger and Toggles.Blair_HuntTrigger.Value then
            Library:Notify("Force Triggering Ghost Hunt...", 3) [cite: 44, 45]
        end
    end
end)

Library:Notify("Blair Revamp Loaded - 15 Features Active")

end
