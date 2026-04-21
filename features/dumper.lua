-- features/dumper.lua
-- Universal Environment Dumper v3.0 — Linoria UI Integration
-- Integrates: Script Source Dump (decompile), Instance Tree,
--             Network Metadata, Env Globals, Real RemoteSpy (__namecall hook)
-- Usage: load('features/dumper.lua')(State, Tabs, Services, Library)

return function(State, Tabs, Services, Library)

    -- ================================================================
    -- SERVICES
    -- ================================================================
    local runService     = game:GetService("RunService")
    local playersService = game:GetService("Players")
    local httpService    = game:GetService("HttpService")
    local localPlayer    = playersService.LocalPlayer

    -- ================================================================
    -- FOLDER SETUP
    -- Wrapped in pcall so a missing makefolder() does not crash the
    -- entire feature and leave the Dumper tab empty.
    -- ================================================================
    local logFolder    = "UniversalDumperLogs"
    local timestamp    = os.time()
    local outputFolder = string.format("%s/%d", logFolder, timestamp)
    local filesystemOk = false

    local folderOk, folderErr = pcall(function()
        makefolder(logFolder)
        makefolder(outputFolder)
    end)

    if folderOk then
        filesystemOk = true
    else
        warn("[Dumper] Filesystem not available — file output disabled. Error: " .. tostring(folderErr))
    end

    -- ================================================================
    -- UTILITY
    -- ================================================================
    local function safeCall(func)
        local ok, err = pcall(func)
        if not ok then
            Library:Notify("Dump Error: " .. tostring(err))
        end
        return ok
    end

    -- Safely read an existing file (returns "" on failure)
    local function safeRead(path)
        local ok, data = pcall(readfile, path)
        return (ok and data) or ""
    end

    -- Safely write a file — does nothing if filesystem is unavailable
    local function safeWrite(path, content)
        if not filesystemOk then
            Library:Notify("File write skipped — filesystem not supported by this executor")
            return false
        end
        local ok, err = pcall(writefile, path, content)
        if not ok then
            Library:Notify("Write error: " .. tostring(err))
        end
        return ok
    end

    -- ================================================================
    -- REMOTE SPY PATH BUILDER (used by both spy and script dump)
    -- ================================================================
    local function getInstancePath(inst)
        if not inst or inst == game then return "game" end
        local parts = {}
        local obj   = inst
        while obj and obj ~= game do
            table.insert(parts, 1, tostring(obj.Name))
            obj = obj.Parent
        end

        -- Check whether parts[1] is actually a valid service name
        -- before using GetService(), to avoid generating broken paths
        local firstSegment
        local isService = pcall(function() game:GetService(parts[1]) end)
        if isService then
            firstSegment = 'game:GetService("' .. parts[1] .. '")'
        else
            firstSegment = 'game["' .. parts[1] .. '"]'
        end

        local out = firstSegment
        for i = 2, #parts do
            local seg = parts[i]
            if seg:match("[^%w_]") then
                out = out .. '["' .. seg .. '"]'
            else
                out = out .. "." .. seg
            end
        end
        return out
    end

    -- ================================================================
    -- SCRIPT SOURCE DUMP
    -- Covers: Workspace, ReplicatedStorage, ReplicatedFirst,
    --         StarterGui, StarterPack, Players,
    --         LocalPlayer Backpack / PlayerGui / Character
    -- All scripts are written into ONE single .lua file.
    -- Uses decompile() when available, falls back to .Source.
    -- ================================================================
    local function dumpScriptSources()
        local scriptCount = 0
        local chunks = {
            "-- ============================================================",
            "-- Universal Script Source Dump",
            "-- Generated : " .. os.date("%Y-%m-%d %H:%M:%S"),
            "-- Place ID  : " .. tostring(game.PlaceId),
            "-- ============================================================",
            "",
        }

        local function separator(label)
            table.insert(chunks, string.rep("=", 60))
            table.insert(chunks, "-- SERVICE: " .. label)
            table.insert(chunks, string.rep("=", 60))
            table.insert(chunks, "")
        end

        local function processScript(inst, sectionLabel)
            if not (inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script")) then
                return
            end
            scriptCount = scriptCount + 1

            local header = string.format(
                "-- [%s] %s  (%s)",
                sectionLabel, inst:GetFullName(), inst.ClassName
            )

            local src
            if inst:IsA("Script") then
                -- Server scripts cannot be decompiled from the client
                src = "-- ServerScript: source not accessible from client."
            else
                local ok, result = pcall(function()
                    -- Prefer decompile() (executor function)
                    if type(decompile) == "function" then
                        local d = decompile(inst)
                        if type(d) == "string" and #d > 0 then
                            return d
                        end
                    end
                    -- Fall back to .Source property
                    local s = inst.Source
                    if type(s) == "string" and #s > 0 then
                        return s
                    end
                    return nil
                end)
                if ok and result then
                    src = result
                else
                    src = "-- Decompile failed" .. (ok and "" or (": " .. tostring(result)))
                end
            end

            table.insert(chunks, header)
            table.insert(chunks, src)
            table.insert(chunks, "")
            table.insert(chunks, string.rep("-", 60))
            table.insert(chunks, "")

            -- Yield every script to avoid lag spikes
            runService.RenderStepped:Wait()
        end

        -- List of top-level services to crawl
        local serviceTargets = {
            { "Workspace",         workspace },
            { "ReplicatedStorage", game:GetService("ReplicatedStorage") },
            { "ReplicatedFirst",   game:GetService("ReplicatedFirst")   },
            { "StarterGui",        game:GetService("StarterGui")        },
            { "StarterPack",       game:GetService("StarterPack")       },
            { "Players",           playersService                       },
        }

        for _, pair in ipairs(serviceTargets) do
            local label, svc = pair[1], pair[2]
            separator(label)
            for _, desc in ipairs(svc:GetDescendants()) do
                processScript(desc, label)
            end
        end

        -- LocalPlayer-specific containers
        pcall(function()
            local lp = localPlayer
            local lpTargets = {
                { "LocalPlayer/Backpack",  lp.Backpack   },
                { "LocalPlayer/PlayerGui", lp.PlayerGui  },
                { "LocalPlayer/Character", lp.Character  },
            }
            for _, pair in ipairs(lpTargets) do
                if pair[2] then
                    separator(pair[1])
                    for _, desc in ipairs(pair[2]:GetDescendants()) do
                        processScript(desc, pair[1])
                    end
                end
            end
        end)

        safeWrite(
            outputFolder .. "/Script_Source_Dump.lua",
            table.concat(chunks, "\n")
        )
        return scriptCount
    end

    -- Dump scripts from a single named service into its own file
    local function dumpSingleService(svcName)
        local svc
        local ok, err = pcall(function()
            if svcName == "Workspace" then
                svc = workspace
            else
                svc = game:GetService(svcName)
            end
        end)
        if not ok then
            Library:Notify("Service not found: " .. svcName)
            return 0
        end

        local count  = 0
        local chunks = {
            "-- Script Dump: " .. svcName,
            "-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "",
        }

        for _, inst in ipairs(svc:GetDescendants()) do
            if inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script") then
                count = count + 1
                local src

                if inst:IsA("Script") then
                    src = "-- ServerScript: not decompilable."
                else
                    local srcOk, srcResult = pcall(function()
                        if type(decompile) == "function" then
                            local d = decompile(inst)
                            if type(d) == "string" and #d > 0 then return d end
                        end
                        local s = inst.Source
                        if type(s) == "string" and #s > 0 then return s end
                        return nil
                    end)
                    src = (srcOk and srcResult) or "-- Decompile failed"
                end

                table.insert(chunks, "-- " .. inst:GetFullName() .. "  (" .. inst.ClassName .. ")")
                table.insert(chunks, src)
                table.insert(chunks, string.rep("-", 60))
                table.insert(chunks, "")
                runService.RenderStepped:Wait()
            end
        end

        safeWrite(
            string.format("%s/Dump_%s.lua", outputFolder, svcName),
            table.concat(chunks, "\n")
        )
        return count
    end

    -- ================================================================
    -- INSTANCE TREE DUMP
    -- ================================================================
    local function crawlInstance(instance, depth)
        local result = {
            Name      = instance.Name,
            ClassName = instance.ClassName,
            Children  = {},
        }
        if instance:IsA("BasePart") then
            table.insert(result.Children, { Name = "Position", Value = tostring(instance.Position) })
        end
        for _, child in ipairs(instance:GetChildren()) do
            if depth < 8 then -- cap depth to avoid massive files
                table.insert(result.Children, crawlInstance(child, depth + 1))
            end
        end
        return result
    end

    local function dumpInstanceTree()
        local instanceData = crawlInstance(game, 0)
        safeWrite(
            outputFolder .. "/Instance_Tree.json",
            httpService:JSONEncode(instanceData)
        )
    end

    -- ================================================================
    -- NETWORK METADATA DUMP
    -- ================================================================
    local function dumpNetworkMetadata()
        local players = playersService:GetPlayers()
        local playerNames = {}
        for _, p in ipairs(players) do
            table.insert(playerNames, p.Name)
        end

        local content = table.concat({
            "=== Network Metadata ===",
            "Timestamp : " .. os.date("%Y-%m-%d %H:%M:%S"),
            "Game ID   : " .. tostring(game.GameId),
            "Place ID  : " .. tostring(game.PlaceId),
            "Job ID    : " .. tostring(game.JobId),
            "Players   : " .. tostring(#players) .. " — [" .. table.concat(playerNames, ", ") .. "]",
            "",
        }, "\n")

        safeWrite(
            outputFolder .. "/Network_Metadata.txt",
            safeRead(outputFolder .. "/Network_Metadata.txt") .. content
        )
    end

    -- ================================================================
    -- ENVIRONMENT GLOBALS DUMP
    -- Checks for getgenv() support before attempting to call it,
    -- so this button works on all executors without crashing.
    -- ================================================================
    local function dumpEnvironmentGlobals()
        if type(getgenv) ~= "function" then
            Library:Notify("Env dump: getgenv() is not supported by this executor")
            return
        end

        local lines = {
            "=== Environment Globals ===",
            "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "",
        }
        for k, v in pairs(getgenv()) do
            table.insert(lines, string.format("%-40s = %-20s  [%s]", tostring(k), tostring(v), typeof(v)))
        end
        safeWrite(
            outputFolder .. "/Environment_Globals.txt",
            table.concat(lines, "\n")
        )
    end

    -- ================================================================
    -- REMOTE SPY  (real __namecall hook — ported from Remote2Script v2)
    -- Logs every :FireServer() / :InvokeServer() call to file.
    -- ================================================================
    local remoteSpyActive   = false
    local remoteLog         = {}
    local remotesFired      = 0
    local namecallHooked    = false
    local originalNamecall  = nil

    -- Build a call script string from a captured remote call
    local function buildCallScript(object, method, args)
        local lines = {
            "-- Captured by UniversalDumper RemoteSpy",
            "-- Time   : " .. os.date("%H:%M:%S"),
            "-- Remote : " .. tostring(object.ClassName) .. " @ " .. getInstancePath(object),
            "",
        }
        for i, v in ipairs(args) do
            local valStr
            local t = typeof(v)
            if t == "Instance" then
                valStr = getInstancePath(v)
            elseif t == "string" then
                valStr = string.format("%q", v)
            elseif t == "Vector3" then
                valStr = string.format("Vector3.new(%s)", tostring(v))
            elseif t == "CFrame" then
                valStr = string.format("CFrame.new(%s)", tostring(v))
            elseif t == "Color3" then
                valStr = string.format("Color3.new(%s)", tostring(v))
            elseif t == "EnumItem" then
                valStr = "Enum." .. tostring(v.EnumType) .. "." .. tostring(v.Name)
            elseif t == "table" then
                valStr = "{--[[ table ]]}"
            else
                valStr = tostring(v)
            end
            table.insert(lines, string.format("local A_%d = %s", i, valStr))
        end
        local argList = {}
        for i = 1, #args do table.insert(argList, "A_" .. i) end
        table.insert(lines, "local Remote = " .. getInstancePath(object))
        table.insert(lines, "Remote:" .. method .. "(" .. table.concat(argList, ", ") .. ")")
        return table.concat(lines, "\n")
    end

    local function flushRemoteLog()
        if #remoteLog == 0 then return end
        local lines = {
            "=== Remote Spy Log ===",
            "Flushed: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "Total calls: " .. tostring(remotesFired),
            string.rep("-", 60),
            "",
        }
        for _, entry in ipairs(remoteLog) do
            table.insert(lines, entry.script)
            table.insert(lines, string.rep("-", 40))
            table.insert(lines, "")
        end
        safeWrite(outputFolder .. "/Remote_Log.lua", table.concat(lines, "\n"))
    end

    local function hookNamecall()
        if namecallHooked then return true end

        -- Validate executor capabilities
        if not getrawmetatable then
            Library:Notify("RemoteSpy: getrawmetatable() not available in this executor")
            return false
        end
        if not getnamecallmethod then
            Library:Notify("RemoteSpy: getnamecallmethod() not available in this executor")
            return false
        end

        local gameMeta = getrawmetatable(game)
        if not gameMeta then
            Library:Notify("RemoteSpy: could not get game metatable")
            return false
        end

        -- Make metatable writable
        if setreadonly then
            setreadonly(gameMeta, false)
        elseif make_writeable then
            make_writeable(gameMeta)
        end

        originalNamecall = gameMeta.__namecall

        -- Use newcclosure if available for C-closure spoofing, else plain function
        local wrapFn = (type(newcclosure) == "function") and newcclosure or function(f) return f end

        gameMeta.__namecall = wrapFn(function(object, ...)
            local method = getnamecallmethod()

            -- Only intercept remote server calls while spy is active
            if remoteSpyActive and method
               and (method == "FireServer" or method == "InvokeServer"
                    or method == "fireServer" or method == "invokeServer")
            then
                pcall(function()
                    if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") then
                        local args = { ... }
                        -- Roblox appends a trailing nil to varargs; strip it
                        while #args > 0 and args[#args] == nil do
                            args[#args] = nil
                        end

                        remotesFired = remotesFired + 1

                        local entry = {
                            script = buildCallScript(object, method, args),
                        }
                        table.insert(remoteLog, entry)

                        -- Keep log bounded
                        if #remoteLog > 300 then
                            table.remove(remoteLog, 1)
                        end

                        -- Auto-flush every 25 calls
                        if remotesFired % 25 == 0 then
                            flushRemoteLog()
                        end

                        Library:Notify(string.format(
                            "[RemoteSpy] #%d  %s:%s",
                            remotesFired, object.Name, method
                        ), 3)
                    end
                end)
            end

            return originalNamecall(object, ...)
        end)

        namecallHooked = true
        return true
    end

    local function startRemoteSpy()
        if remoteSpyActive then
            Library:Notify("Remote Spy already running")
            return
        end
        if hookNamecall() then
            remoteSpyActive = true
            Library:Notify("Remote Spy: ENABLED")
        end
    end

    local function stopRemoteSpy()
        if not remoteSpyActive then
            Library:Notify("Remote Spy is not running")
            return
        end
        remoteSpyActive = false
        flushRemoteLog()
        Library:Notify(string.format(
            "Remote Spy: DISABLED — %d calls logged → Remote_Log.lua",
            remotesFired
        ))
    end

    local function clearRemoteLog()
        remoteLog    = {}
        remotesFired = 0
        Library:Notify("Remote log cleared")
    end

    -- ================================================================
    -- UI  — LEFT GROUPBOX: Dumper  (one per tab — Linoria requirement)
    -- ================================================================
    local leftBox = Tabs.Dumper:AddLeftGroupbox("Dumper")

    -- ── Main dumps ──────────────────────────────────────────────────
    leftBox:AddButton({
        Text = "Full Dump (All Services)",
        Func = function()
            safeCall(function()
                local count = dumpScriptSources()
                dumpInstanceTree()
                dumpNetworkMetadata()
                dumpEnvironmentGlobals()
                Library:Notify(string.format(
                    "Full dump done — %d scripts → %s", count, outputFolder
                ))
            end)
        end,
    })

    leftBox:AddButton({
        Text = "Dump Script Sources (single file)",
        Func = function()
            local count = 0
            safeCall(function() count = dumpScriptSources() end)
            Library:Notify(string.format("Script dump done — %d scripts", count))
        end,
    })

    leftBox:AddButton({
        Text = "Dump Instance Tree",
        Func = function()
            safeCall(dumpInstanceTree)
            Library:Notify("Instance tree → Instance_Tree.json")
        end,
    })

    leftBox:AddButton({
        Text = "Dump Network Metadata",
        Func = function()
            safeCall(dumpNetworkMetadata)
            Library:Notify("Network metadata saved")
        end,
    })

    leftBox:AddButton({
        Text = "Dump Env Globals",
        Func = function()
            safeCall(dumpEnvironmentGlobals)
            Library:Notify("Env globals saved")
        end,
    })

    leftBox:AddButton({
        Text = "Show Log Folder Path",
        Func = function()
            Library:Notify("Logs: " .. outputFolder)
        end,
    })

    -- ── Per-service script dumps (Dev Decompiler style) ─────────────
    leftBox:AddLabel("Dump by Service:")

    local serviceList = {
        "Workspace",
        "ReplicatedStorage",
        "ReplicatedFirst",
        "StarterGui",
        "StarterPack",
        "Players",
    }

    for _, svcName in ipairs(serviceList) do
        leftBox:AddButton({
            Text = "Dump: " .. svcName,
            Func = function()
                local count = 0
                safeCall(function() count = dumpSingleService(svcName) end)
                Library:Notify(string.format(
                    "Dumped %s — %d scripts → Dump_%s.lua",
                    svcName, count, svcName
                ))
            end,
        })
    end

    -- ── LocalPlayer dumps ────────────────────────────────────────────
    leftBox:AddLabel("LocalPlayer Dumps:")

    local lpTargets = {
        { "Backpack",  function() return localPlayer.Backpack  end },
        { "PlayerGui", function() return localPlayer.PlayerGui end },
        { "Character", function() return localPlayer.Character end },
    }

    for _, pair in ipairs(lpTargets) do
        local label, getContainer = pair[1], pair[2]
        leftBox:AddButton({
            Text = "Dump: LP/" .. label,
            Func = function()
                local count  = 0
                local chunks = {
                    "-- Dump: LocalPlayer/" .. label,
                    "-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
                    "",
                }
                safeCall(function()
                    local container = getContainer()
                    if not container then
                        Library:Notify(label .. " not found")
                        return
                    end
                    for _, inst in ipairs(container:GetDescendants()) do
                        if inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script") then
                            count = count + 1
                            local src
                            if inst:IsA("Script") then
                                src = "-- ServerScript"
                            else
                                local ok, res = pcall(function()
                                    if type(decompile) == "function" then
                                        local d = decompile(inst)
                                        if type(d) == "string" and #d > 0 then return d end
                                    end
                                    return inst.Source
                                end)
                                src = (ok and res and #res > 0) and res or "-- Decompile failed"
                            end
                            table.insert(chunks, "-- " .. inst:GetFullName())
                            table.insert(chunks, src)
                            table.insert(chunks, string.rep("-", 60))
                            table.insert(chunks, "")
                            runService.RenderStepped:Wait()
                        end
                    end
                    safeWrite(
                        string.format("%s/Dump_LP_%s.lua", outputFolder, label),
                        table.concat(chunks, "\n")
                    )
                end)
                Library:Notify(string.format("Dumped LP/%s — %d scripts", label, count))
            end,
        })
    end

    -- ================================================================
    -- UI  — RIGHT GROUPBOX: Remote Spy  (one per tab — Linoria requirement)
    -- ================================================================
    local rightBox = Tabs.Dumper:AddRightGroupbox("Remote Spy")

    rightBox:AddLabel("Hooks FireServer / InvokeServer via __namecall")

    rightBox:AddButton({
        Text = "Enable Remote Spy",
        Func = startRemoteSpy,
    })

    rightBox:AddButton({
        Text = "Disable + Save Log",
        Func = stopRemoteSpy,
    })

    rightBox:AddButton({
        Text = "Flush Log Now",
        Func = function()
            flushRemoteLog()
            Library:Notify(string.format(
                "Flushed %d entries → Remote_Log.lua", #remoteLog
            ))
        end,
    })

    rightBox:AddButton({
        Text = "Clear Remote Log",
        Func = clearRemoteLog,
    })

    rightBox:AddButton({
        Text = "Show Remote Count",
        Func = function()
            Library:Notify(string.format(
                "Remotes fired this session: %d (buffered: %d)",
                remotesFired, #remoteLog
            ))
        end,
    })

    -- ================================================================
    -- PUBLIC API
    -- ================================================================
    return {
        dumpScriptSources      = dumpScriptSources,
        dumpSingleService      = dumpSingleService,
        dumpInstanceTree       = dumpInstanceTree,
        dumpNetworkMetadata    = dumpNetworkMetadata,
        dumpEnvironmentGlobals = dumpEnvironmentGlobals,
        startRemoteSpy         = startRemoteSpy,
        stopRemoteSpy          = stopRemoteSpy,
        flushRemoteLog         = flushRemoteLog,
        clearRemoteLog         = clearRemoteLog,
    }
end
