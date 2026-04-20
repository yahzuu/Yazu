-- features/dumper.lua
-- Universal Environment Dumper — Linoria UI integration
-- Usage: load('features/dumper.lua')(State, Tabs, Services, Library)

return function(State, Tabs, Services, Library)

    -- ── Dumper core state ────────────────────────────────────────
    local httpService   = game:GetService("HttpService")
    local playersService = game:GetService("Players")
    local runService    = Services.RunService

    local logFolder    = "YazuDumperLogs"
    local timestamp    = os.time()
    local outputFolder = string.format("%s/%d", logFolder, timestamp)
    makefolder(logFolder)
    makefolder(outputFolder)

    local hookState = {
        active         = false,   -- OFF by default; toggle turns it on
        networkTraffic = {},
    }

    local perfStats = {
        lastLogTime  = 0,
        logInterval  = 1/30,
        frameCount   = 0,
        hooksInstalled = false,
        remoteCalls  = 0,
        scriptCount  = 0,
    }

    -- ── Helpers ──────────────────────────────────────────────────
    local function safeCall(fn, ...)
        local ok, result = pcall(fn, ...)
        if not ok then warn("[Dumper] " .. tostring(result)) end
        return ok and result or nil
    end

    local function serializeValue(value, indent)
        indent = indent or ""
        if value == nil then return "nil" end
        local t = typeof(value)
        if t == "string"  then return string.format("%q", value) end
        if t == "number" or t == "boolean" then return tostring(value) end
        if t == "table" then
            local out = "{\n"
            for k, v in pairs(value) do
                local fk = type(k) == "string" and k or "[" .. tostring(k) .. "]"
                out = out .. indent .. "  " .. fk .. " = " .. serializeValue(v, indent .. "  ") .. ",\n"
            end
            return out .. indent .. "}"
        end
        return tostring(value)
    end

    local function appendFile(path, text)
        -- writefile with append flag (exploit fs API)
        local existing = ""
        pcall(function() existing = readfile(path) end)
        writefile(path, existing .. text)
    end

    -- ── Remote spy ───────────────────────────────────────────────
    local function setupRemoteSpy()
        if perfStats.hooksInstalled then return end

        hookmetamethod(game, "__namecall", function(instance, ...)
            if not hookState.active then
                return (hookmetamethod(game, "__namecall")) -- passthrough trick won't work; just call original
            end
            local method = getnamecallmethod()
            if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
                local entry = {
                    type   = instance.ClassName,
                    name   = instance:GetFullName(),
                    method = method,
                    args   = {...},
                    time   = os.time(),
                }
                table.insert(hookState.networkTraffic, entry)
                perfStats.remoteCalls = perfStats.remoteCalls + 1
            end
        end)

        perfStats.hooksInstalled = true
    end

    -- ── Dump functions ───────────────────────────────────────────
    local function dumpScriptSources()
        local scripts = getscripts and getscripts() or {}
        local count = 0
        for _, s in ipairs(scripts) do
            if s:IsA("ModuleScript") or s:IsA("LocalScript") then
                local src = safeCall(decompile, s) or "-- Decompile failed"
                appendFile(outputFolder .. "/Script_Source_Dump.lua",
                    string.format("-- %s\n%s\n\n", s:GetFullName(), src))
                count = count + 1
            end
        end
        perfStats.scriptCount = count
        return count
    end

    local function crawlInstance(inst, depth)
        if not inst or inst:IsA("DataModel") then return nil end
        local children = {}
        for _, child in ipairs(inst:GetChildren()) do
            local d = crawlInstance(child, depth + 1)
            if d then table.insert(children, d) end
        end
        return { name = inst.Name, className = inst.ClassName, children = children }
    end

    local function dumpInstanceTree()
        local data = crawlInstance(game, 0)
        appendFile(outputFolder .. "/Instance_Tree.json",
            httpService:JSONEncode(data) .. "\n")
    end

    local function dumpNetworkMetadata()
        local players = {}
        for _, p in ipairs(playersService:GetPlayers()) do
            table.insert(players, { name = p.Name, userId = p.UserId })
        end
        appendFile(outputFolder .. "/Network_Metadata.json",
            httpService:JSONEncode({
                placeId  = game.PlaceId,
                jobId    = game.JobId,
                players  = players,
            }) .. "\n")
    end

    local function dumpEnvironmentGlobals()
        local env = getgenv and getgenv() or {}
        local list = {}
        for k, v in pairs(env) do
            if k ~= "_G" then
                table.insert(list, { key = k, type = typeof(v), value = serializeValue(v) })
            end
        end
        appendFile(outputFolder .. "/Environment_Globals.json",
            httpService:JSONEncode(list) .. "\n")
    end

    -- ── Batch log flush ──────────────────────────────────────────
    local function flushNetworkLogs()
        if #hookState.networkTraffic == 0 then return end
        local batch = hookState.networkTraffic
        hookState.networkTraffic = {}
        local lines = ""
        for _, entry in ipairs(batch) do
            lines = lines .. string.format("[%s] %s.%s -> %s\n",
                os.date("%H:%M:%S", entry.time),
                entry.name, entry.method,
                serializeValue(entry.args))
        end
        appendFile(outputFolder .. "/Remote_Logs.txt", lines)
    end

    -- ── Frame loop ───────────────────────────────────────────────
    local loopConnection = nil

    local function startLoop()
        if loopConnection then return end
        loopConnection = runService.RenderStepped:Connect(function()
            if not hookState.active then return end
            local now = tick()
            if (now - perfStats.lastLogTime) >= perfStats.logInterval then
                flushNetworkLogs()
                perfStats.lastLogTime = now
            end
            perfStats.frameCount = perfStats.frameCount + 1
            if perfStats.frameCount % 300 == 0 then
                safeCall(dumpInstanceTree)
            end
        end)
    end

    local function stopLoop()
        if loopConnection then
            loopConnection:Disconnect()
            loopConnection = nil
        end
    end

    -- ── Linoria UI ───────────────────────────────────────────────
    local tab     = Tabs.Dumper  -- added in main.lua
    local leftBox = tab:AddLeftGroupbox("Spy Controls")
    local rightBox = tab:AddRightGroupbox("Manual Dumps")
    local statsBox = tab:AddLeftGroupbox("Live Stats")

    -- Master toggle
    leftBox:AddToggle("DumperActive", {
        Text    = "Enable Remote Spy",
        Default = false,
        Tooltip = "Hooks __namecall and logs all RemoteEvent/RemoteFunction calls",
        Callback = function(val)
            hookState.active = val
            if val then
                setupRemoteSpy()
                startLoop()
                Library:Notify("Dumper started — saving to: " .. outputFolder)
            else
                stopLoop()
                flushNetworkLogs()  -- flush leftovers on disable
                Library:Notify("Dumper stopped.")
            end
        end,
    })

    leftBox:AddToggle("AutoInstanceDump", {
        Text    = "Auto Instance Tree (10s)",
        Default = false,
        Tooltip = "Periodically re-dumps the full instance tree while spy is active",
    })

    leftBox:AddDivider()

    leftBox:AddButton({
        Text = "Open Log Folder",
        Func = function()
            -- Some exploits support this; gracefully fails if not
            safeCall(function() syn and syn.open_file and syn.open_file(outputFolder) end)
            Library:Notify("Logs at: " .. outputFolder)
        end,
    })

    -- Manual one-shot dump buttons
    rightBox:AddButton({
        Text = "Dump Script Sources",
        Func = function()
            local n = safeCall(dumpScriptSources) or 0
            Library:Notify(string.format("Dumped %d scripts → Script_Source_Dump.lua", n))
        end,
    })

    rightBox:AddButton({
        Text = "Dump Instance Tree",
        Func = function()
            safeCall(dumpInstanceTree)
            Library:Notify("Instance tree saved → Instance_Tree.json")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Network Metadata",
        Func = function()
            safeCall(dumpNetworkMetadata)
            Library:Notify("Network metadata saved → Network_Metadata.json")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Env Globals",
        Func = function()
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Environment globals saved → Environment_Globals.json")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Everything",
        Func = function()
            safeCall(dumpScriptSources)
            safeCall(dumpInstanceTree)
            safeCall(dumpNetworkMetadata)
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Full dump complete → " .. outputFolder)
        end,
    })

    -- Live stats label (updates every second via a separate RenderStepped)
    local statsLabel = statsBox:AddLabel("Remote Calls: 0 | Scripts: 0")
    local lastStatUpdate = 0
    runService.RenderStepped:Connect(function()
        if tick() - lastStatUpdate < 1 then return end
        lastStatUpdate = tick()
        statsLabel:SetText(string.format(
            "Remote Calls: %d | Scripts Dumped: %d\nOutput: .../%d",
            perfStats.remoteCalls,
            perfStats.scriptCount,
            timestamp
        ))
    end)

    -- Return cleanup so main.lua can call it on unload if needed
    return function()
        hookState.active = false
        stopLoop()
    end
end
