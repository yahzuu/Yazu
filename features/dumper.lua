-- features/dumper.lua
-- Universal Environment Dumper v2.0 — Linoria UI Integration
-- Preserves ALL original logic. Wraps into Yazu's module pattern.
-- Usage: load('features/dumper.lua')(State, Tabs, Services, Library)

return function(State, Tabs, Services, Library)

    -- ================================================================
    -- SERVICES
    -- ================================================================
    local runService     = game:GetService("RunService")
    local playersService = game:GetService("Players")
    local httpService    = game:GetService("HttpService")

    -- ================================================================
    -- FOLDER SETUP
    -- ================================================================
    local logFolder    = "UniversalDumperLogs"
    local timestamp    = os.time()
    local outputFolder = string.format("%s/%d", logFolder, timestamp)
    makefolder(logFolder)
    makefolder(outputFolder)

    -- ================================================================
    -- GLOBAL STATE  (mirrors original exactly)
    -- ================================================================
    local hookState = {
        active         = false,   -- toggled via UI (was true in original standalone)
        networkTraffic = {},
        instanceCache  = {},
        classMap       = {},
        hooksInstalled = false,
    }

    -- ================================================================
    -- PERFORMANCE STATE  (mirrors original exactly)
    -- ================================================================
    local performance = {
        lastLogTime  = 0,
        logInterval  = 1/30,
        frameCount   = 0,
        networkStats = {
            remoteCalls   = 0,
            scriptCount   = 0,
            instanceCount = 0,
        }
    }

    -- ================================================================
    -- ERROR HANDLING WRAPPER
    -- ================================================================
    local function safeCall(func, ...)
        local success, result = pcall(func, ...)
        if not success then
            warn("Safe call failed: " .. tostring(result))
            return nil
        end
        return result
    end

    -- ================================================================
    -- SERIALIZATION  (original, untouched)
    -- ================================================================
    local function serializeValue(value, indent)
        indent = indent or ""

        if value == nil then
            return "nil"
        elseif value == true or value == false then
            return tostring(value)
        end

        local valueType = typeof(value)

        if valueType == "string" then
            return string.format("%q", value)
        elseif valueType == "number" then
            return tostring(value)
        elseif valueType == "boolean" then
            return tostring(value)
        elseif valueType == "nil" then
            return "nil"
        end

        if valueType == "table" then
            local result = "{\n"
            for key, val in pairs(value) do
                local formattedKey = type(key) == "string" and key or "[" .. tostring(key) .. "]"
                result = result .. indent .. "  " .. formattedKey .. " = "
                if type(val) == "table" then
                    result = result .. serializeValue(val, indent .. "  ") .. ",\n"
                else
                    result = result .. serializeValue(val) .. ",\n"
                end
            end
            return result .. indent .. "}"
        end

        return tostring(value)
    end

    -- ================================================================
    -- INSTANCE CRAWLING  (original, untouched)
    -- ================================================================
    local function crawlInstance(instance, depth)
        if not instance or instance:IsA("DataModel") then
            return nil
        end

        local class      = instance.ClassName
        local properties = {}

        for _, prop in ipairs(instance:GetPropertyList()) do
            local value = safeCall(function() return instance[prop] end)

            if value ~= nil and not (type(value) == "table" and #value == 0) then
                local defValue = safeCall(function()
                    local propInfo = class:FindFirstChild(prop, true)
                    if propInfo and propInfo:IsA("Property") then
                        return propInfo.DefaultValue
                    end
                    return nil
                end)

                if defValue == nil or value ~= defValue then
                    properties[prop] = value
                end
            end
        end

        local children = {}
        for _, child in ipairs(instance:GetChildren()) do
            local childData = crawlInstance(child, depth + 1)
            if childData then
                table.insert(children, childData)
            end
        end

        return {
            name       = instance.Name,
            className  = class,
            properties = properties,
            children   = children,
            parentPath = (instance.Parent and instance.Parent:GetFullName()) or nil,
        }
    end

    -- ================================================================
    -- REMOTE SPY  (original logic preserved; originalNamecall stored so
    --              the hook can pass through correctly)
    -- ================================================================
    local originalNamecall = nil
    local originalIndex    = nil

    local function setupRemoteSpy()
        if hookState.hooksInstalled then return end

        originalNamecall = hookmetamethod(game, "__namecall", function(instance, ...)
            local method = getnamecallmethod()
            local args   = {...}

            if hookState.active then
                if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
                    local remoteType = instance:IsA("RemoteEvent") and "RemoteEvent" or "RemoteFunction"
                    local ts         = os.time()

                    table.insert(hookState.networkTraffic, {
                        type   = remoteType,
                        name   = instance:GetFullName(),
                        method = method,
                        args   = args,
                        time   = ts,
                    })

                    performance.networkStats.remoteCalls =
                        performance.networkStats.remoteCalls + 1

                    local logEntry = string.format("[%s] %s.%s -> %s",
                        os.date("%H:%M:%S", ts),
                        instance:GetFullName(),
                        method,
                        serializeValue(args)
                    )

                    -- immediate write (matches original behaviour)
                    local existing = ""
                    pcall(function() existing = readfile(outputFolder .. "/Remote_Logs.txt") end)
                    writefile(outputFolder .. "/Remote_Logs.txt", existing .. logEntry .. "\n")
                end
            end

            return originalNamecall(instance, ...)
        end)

        originalIndex = hookmetamethod(game, "__index", function(instance, key)
            if hookState.active then
                if typeof(instance) == "Instance" and instance.Parent ~= nil then
                    local ts = os.time()
                    table.insert(hookState.networkTraffic, {
                        type = "PropertyAccess",
                        name = tostring(instance),
                        key  = key,
                        time = ts,
                    })
                end
            end

            return originalIndex(instance, key)
        end)

        hookState.hooksInstalled = true
    end

    -- ================================================================
    -- SCRIPT SOURCE DUMPING  (original, untouched)
    -- ================================================================
    local function dumpScriptSources()
        local scripts = {}
        for _, script in ipairs(getscripts()) do
            if script:IsA("ModuleScript") or script:IsA("LocalScript") then
                table.insert(scripts, script)
            end
        end

        for i, script in ipairs(scripts) do
            local success = false

            local source, err = safeCall(function()
                return decompile(script)
            end)

            if success and source then
                local existing = ""
                pcall(function()
                    existing = readfile(string.format("%s/Script_Source_Dump.lua", outputFolder))
                end)
                writefile(
                    string.format("%s/Script_Source_Dump.lua", outputFolder),
                    existing .. string.format("-- Script: %s\n%s\n\n", script:GetFullName(), source)
                )
                performance.networkStats.scriptCount =
                    performance.networkStats.scriptCount + 1
            else
                local byteHash = safeCall(function()
                    return string.format("%x", table.sum(script:Clone():GetBytecode()))
                end)

                local existing = ""
                pcall(function()
                    existing = readfile(string.format("%s/Script_Source_Dump.lua", outputFolder))
                end)
                writefile(
                    string.format("%s/Script_Source_Dump.lua", outputFolder),
                    existing .. string.format(
                        "-- Script: %s (Decompile failed)\n-- Bytecode Hash: %s\n\n",
                        script:GetFullName(),
                        byteHash or "unknown"
                    )
                )
            end
        end
    end

    -- ================================================================
    -- INSTANCE TREE DUMP  (original, untouched)
    -- ================================================================
    local function dumpInstanceTree()
        local root         = game
        local instanceData = crawlInstance(root, 0)

        local existing = ""
        pcall(function() existing = readfile(outputFolder .. "/Instance_Tree.json") end)
        writefile(
            outputFolder .. "/Instance_Tree.json",
            existing .. httpService:JSONEncode(instanceData) .. "\n"
        )
    end

    -- ================================================================
    -- ENVIRONMENT GLOBALS DUMP  (original, untouched — getreg/getrenv kept)
    -- ================================================================
    local function dumpEnvironmentGlobals()
        local env  = getgenv()
        local renv = getrenv()
        local reg  = getreg()

        local registryData = {}
        for key, value in pairs(reg) do
            table.insert(registryData, {
                key   = tostring(key),
                type  = typeof(value),
                value = serializeValue(value),
            })
        end

        local globalsList = {}
        for k, v in pairs(env) do
            if k ~= "_G" then
                table.insert(globalsList, {
                    key   = k,
                    type  = typeof(v),
                    value = serializeValue(v),
                })
            end
        end

        local function appendEnv(text)
            local existing = ""
            pcall(function() existing = readfile(outputFolder .. "/Environment_Globals.txt") end)
            writefile(outputFolder .. "/Environment_Globals.txt", existing .. text)
        end

        appendEnv("=== Global Environment Analysis ===\n")
        appendEnv("Registry Contents:\n" .. httpService:JSONEncode(registryData) .. "\n\n")
        appendEnv("Global Variables:\n"  .. httpService:JSONEncode(globalsList)  .. "\n\n")
    end

    -- ================================================================
    -- NETWORK METADATA  (original, untouched)
    -- ================================================================
    local function dumpNetworkMetadata()
        local players = {}
        for _, player in ipairs(playersService:GetPlayers()) do
            table.insert(players, {
                name   = player.Name,
                userId = player.UserId,
                age    = os.time() - (player.AccountAge or 0),
            })
        end

        local function appendMeta(text)
            local existing = ""
            pcall(function() existing = readfile(outputFolder .. "/Network_Metadata.txt") end)
            writefile(outputFolder .. "/Network_Metadata.txt", existing .. text)
        end

        appendMeta("=== Network Metadata ===\n")
        appendMeta("Place Info:\n" .. httpService:JSONEncode({
            placeId   = game.PlaceId,
            jobId     = game.JobId,
            creatorId = game.CreatorId,
            players   = players,
        }) .. "\n")
    end

    -- ================================================================
    -- BATCH LOG FLUSH  (original performLogging logic)
    -- ================================================================
    local function performLogging()
        local currentTime = tick()

        if (currentTime - performance.lastLogTime) < performance.logInterval then
            return false
        end

        if #hookState.networkTraffic > 0 then
            local batch = ""
            for i, logEntry in ipairs(hookState.networkTraffic) do
                if logEntry.type == "RemoteEvent" or logEntry.type == "RemoteFunction" then
                    batch = batch .. string.format("[%s] %s.%s -> %s\n",
                        os.date("%H:%M:%S", logEntry.time),
                        logEntry.name,
                        logEntry.method,
                        serializeValue(logEntry.args)
                    )
                end
            end

            if batch ~= "" then
                local existing = ""
                pcall(function() existing = readfile(outputFolder .. "/Remote_Logs.txt") end)
                writefile(outputFolder .. "/Remote_Logs.txt", existing .. batch)
            end

            hookState.networkTraffic = {}
        end

        performance.lastLogTime = currentTime
        return true
    end

    -- ================================================================
    -- MAIN LOOP  (original mainLoop logic — 10s instance dump, 30s meta dump)
    -- ================================================================
    local function mainLoop()
        if not hookState.active then return end

        performLogging()

        performance.frameCount = performance.frameCount + 1

        -- Every ~10 seconds at 30fps
        if performance.frameCount % 300 == 0 then
            safeCall(dumpInstanceTree)
        end

        -- Every ~30 seconds at 30fps
        if performance.frameCount % 900 == 0 then
            safeCall(function()
                dumpNetworkMetadata()
                dumpEnvironmentGlobals()
            end)
        end
    end

    -- ================================================================
    -- LOOP CONNECTION MANAGEMENT
    -- ================================================================
    local loopConnection = nil

    local function startLoop()
        if loopConnection then return end
        loopConnection = runService.RenderStepped:Connect(mainLoop)
    end

    local function stopLoop()
        if loopConnection then
            loopConnection:Disconnect()
            loopConnection = nil
        end
    end

    -- ================================================================
    -- LINORIA UI
    -- ================================================================
    local tab      = Tabs.Dumper
    local leftBox  = tab:AddLeftGroupbox("Spy Controls")
    local rightBox = tab:AddRightGroupbox("Manual Dumps")
    local statsBox = tab:AddLeftGroupbox("Live Stats")

    -- Master toggle — replaces the auto-start in original initializeDumper()
    leftBox:AddToggle("DumperActive", {
        Text    = "Enable Remote Spy",
        Default = false,
        Tooltip = "Hooks __namecall + __index and logs all Remote traffic",
        Callback = function(val)
            hookState.active = val
            if val then
                setupRemoteSpy()   -- installs hooks once, guards against double-hook
                startLoop()
                Library:Notify("Dumper active → " .. outputFolder)
            else
                stopLoop()
                performLogging()   -- flush remaining traffic on disable
                Library:Notify("Dumper stopped.")
            end
        end,
    })

    leftBox:AddDivider()

    -- Initial full dump button (replicates original initializeDumper() one-shot dumps)
    leftBox:AddButton({
        Text = "Run Initial Full Dump",
        Func = function()
            safeCall(dumpScriptSources)
            safeCall(dumpInstanceTree)
            safeCall(dumpNetworkMetadata)
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Initial full dump complete → " .. outputFolder)
        end,
    })

    leftBox:AddButton({
        Text = "Open Log Folder Path",
        Func = function()
            Library:Notify("Logs saved to: " .. outputFolder)
        end,
    })

    -- Manual one-shot dump buttons (right side)
    rightBox:AddButton({
        Text = "Dump Script Sources",
        Func = function()
            safeCall(dumpScriptSources)
            Library:Notify(string.format("Scripts dumped (%d) → Script_Source_Dump.lua",
                performance.networkStats.scriptCount))
        end,
    })

    rightBox:AddButton({
        Text = "Dump Instance Tree",
        Func = function()
            safeCall(dumpInstanceTree)
            Library:Notify("Instance tree → Instance_Tree.json")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Network Metadata",
        Func = function()
            safeCall(dumpNetworkMetadata)
            Library:Notify("Network metadata → Network_Metadata.txt")
        end,
    })

    rightBox:AddButton({
        Text = "Dump Env Globals",
        Func = function()
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Env globals → Environment_Globals.txt")
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

    rightBox:AddButton({
        Text = "Flush Remote Log Now",
        Func = function()
            performLogging()
            Library:Notify("Remote log flushed → Remote_Logs.txt")
        end,
    })

    -- Live stats label
    local statsLabel   = statsBox:AddLabel("Remote Calls: 0 | Scripts: 0 | Frames: 0")
    local lastStatTick = 0

    runService.RenderStepped:Connect(function()
        if tick() - lastStatTick < 1 then return end
        lastStatTick = tick()
        statsLabel:SetText(string.format(
            "Remote Calls: %d | Scripts: %d\nFrames: %d | Output: .../%d",
            performance.networkStats.remoteCalls,
            performance.networkStats.scriptCount,
            performance.frameCount,
            timestamp
        ))
    end)

    -- ================================================================
    -- CLEANUP  (returned so main.lua can call on Library:Unload())
    -- ================================================================
    return function()
        hookState.active = false
        stopLoop()
    end
end
