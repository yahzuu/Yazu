-- features/dumper.lua
-- Universal Environment Dumper v3.1 — Linoria UI Integration
-- Compatible with: linoria/lib (Library.lua)
--
-- USAGE (in your main loader script):
--   local Library = loadstring(readfile("Library.lua"))()
--   local Window  = Library:CreateWindow({ Title = "My Script", AutoShow = true })
--   local Tabs    = { Dumper = Window:AddTab("Dumper") }
--   loadstring(readfile("dumper.lua"))(Tabs, Library)
--
-- Arguments:
--   Tabs    — table with a .Dumper key pointing to a Linoria Tab object
--   Library — the Linoria Library instance

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
    -- ================================================================
    local logFolder    = "UniversalDumperLogs"
    local timestamp    = os.time()
    local outputFolder = string.format("%s/%d", logFolder, timestamp)
    makefolder(logFolder)
    makefolder(outputFolder)

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

    local function safeRead(path)
        local ok, data = pcall(readfile, path)
        return (ok and data) or ""
    end

    -- ================================================================
    -- REMOTE SPY PATH BUILDER
    -- ================================================================
    local function getInstancePath(inst)
        if not inst or inst == game then return "game" end
        local parts = {}
        local obj   = inst
        while obj and obj ~= game do
            table.insert(parts, 1, tostring(obj.Name))
            obj = obj.Parent
        end
        local out = 'game:GetService("' .. parts[1] .. '")'
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
            scriptCount += 1

            local header = string.format(
                "-- [%s] %s  (%s)",
                sectionLabel, inst:GetFullName(), inst.ClassName
            )

            local src
            if inst:IsA("Script") then
                src = "-- ServerScript: source not accessible from client."
            else
                local ok, result = pcall(function()
                    if type(decompile) == "function" then
                        local d = decompile(inst)
                        if type(d) == "string" and #d > 0 then return d end
                    end
                    local s = inst.Source
                    if type(s) == "string" and #s > 0 then return s end
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

            runService.RenderStepped:Wait()
        end

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

        writefile(
            outputFolder .. "/Script_Source_Dump.lua",
            table.concat(chunks, "\n")
        )
        return scriptCount
    end

    local function dumpSingleService(svcName)
        local svc
        local ok, err = pcall(function()
            svc = svcName == "Workspace" and workspace or game:GetService(svcName)
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
                count += 1
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

        writefile(
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
        if depth < 8 then
            for _, child in ipairs(instance:GetChildren()) do
                table.insert(result.Children, crawlInstance(child, depth + 1))
            end
        end
        return result
    end

    local function dumpInstanceTree()
        local instanceData = crawlInstance(game, 0)
        writefile(
            outputFolder .. "/Instance_Tree.json",
            httpService:JSONEncode(instanceData)
        )
    end

    -- ================================================================
    -- NETWORK METADATA DUMP
    -- ================================================================
    local function dumpNetworkMetadata()
        local players     = playersService:GetPlayers()
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

        writefile(
            outputFolder .. "/Network_Metadata.txt",
            safeRead(outputFolder .. "/Network_Metadata.txt") .. content
        )
    end

    -- ================================================================
    -- ENVIRONMENT GLOBALS DUMP
    -- ================================================================
    local function dumpEnvironmentGlobals()
        local lines = {
            "=== Environment Globals ===",
            "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "",
        }
        for k, v in pairs(getgenv()) do
            table.insert(lines, string.format("%-40s = %-20s  [%s]", tostring(k), tostring(v), typeof(v)))
        end
        writefile(
            outputFolder .. "/Environment_Globals.txt",
            table.concat(lines, "\n")
        )
    end

    -- ================================================================
    -- REMOTE SPY  (__namecall hook)
    -- ================================================================
    local remoteSpyActive  = false
    local remoteLog        = {}
    local remotesFired     = 0
    local namecallHooked   = false
    local originalNamecall = nil

    local function buildCallScript(object, method, args)
        local lines = {
            "-- Captured by UniversalDumper RemoteSpy",
            "-- Time   : " .. os.date("%H:%M:%S"),
            "-- Remote : " .. tostring(object.ClassName) .. " @ " .. getInstancePath(object),
            "",
        }
        for i, v in ipairs(args) do
            local t      = typeof(v)
            local valStr
            if     t == "Instance" then valStr = getInstancePath(v)
            elseif t == "string"   then valStr = string.format("%q", v)
            elseif t == "Vector3"  then valStr = string.format("Vector3.new(%s)", tostring(v))
            elseif t == "CFrame"   then valStr = string.format("CFrame.new(%s)", tostring(v))
            elseif t == "Color3"   then valStr = string.format("Color3.new(%s)", tostring(v))
            elseif t == "EnumItem" then valStr = "Enum." .. tostring(v.EnumType) .. "." .. tostring(v.Name)
            elseif t == "table"    then valStr = "{--[[ table ]]}"
            else                        valStr = tostring(v)
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
        writefile(outputFolder .. "/Remote_Log.lua", table.concat(lines, "\n"))
    end

    local function hookNamecall()
        if namecallHooked then return true end

        if not getrawmetatable then
            Library:Notify("RemoteSpy: getrawmetatable() unavailable")
            return false
        end
        if not getnamecallmethod then
            Library:Notify("RemoteSpy: getnamecallmethod() unavailable")
            return false
        end

        local gameMeta = getrawmetatable(game)
        if not gameMeta then
            Library:Notify("RemoteSpy: could not get game metatable")
            return false
        end

        if setreadonly then
            setreadonly(gameMeta, false)
        elseif make_writeable then
            make_writeable(gameMeta)
        end

        originalNamecall = gameMeta.__namecall

        local wrapFn = (type(newcclosure) == "function") and newcclosure or function(f) return f end

        gameMeta.__namecall = wrapFn(function(object, ...)
            local method = getnamecallmethod()

            if remoteSpyActive and method
               and (method == "FireServer" or method == "InvokeServer"
                    or method == "fireServer" or method == "invokeServer")
            then
                pcall(function()
                    if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") then
                        local args = { ... }
                        while #args > 0 and args[#args] == nil do
                            args[#args] = nil
                        end

                        remotesFired += 1

                        table.insert(remoteLog, { script = buildCallScript(object, method, args) })

                        if #remoteLog > 300 then
                            table.remove(remoteLog, 1)
                        end

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
            "Remote Spy: DISABLED — %d calls logged",
            remotesFired
        ))
    end

    local function clearRemoteLog()
        remoteLog    = {}
        remotesFired = 0
        Library:Notify("Remote log cleared")
    end

    -- ================================================================
    -- UI — LEFT GROUPBOX: Dumper
    -- All Linoria API calls verified against Library.lua:
    --   :AddLeftGroupbox(name)  → Groupbox
    --   :AddButton({ Text, Func, Tooltip? })
    --   :AddLabel(text)
    -- ================================================================
    local leftBox = Tabs.Dumper:AddLeftGroupbox("Dumper")

    -- Main dump actions
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
        Text    = "Dump Script Sources (all in one file)",
        Func    = function()
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

    -- Per-service dumps
    leftBox:AddLabel("── Dump by Service ──")

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
                    "Dumped %s — %d scripts", svcName, count
                ))
            end,
        })
    end

    -- LocalPlayer dumps
    leftBox:AddLabel("── LocalPlayer ──")

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
                            count += 1
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
                    writefile(
                        string.format("%s/Dump_LP_%s.lua", outputFolder, label),
                        table.concat(chunks, "\n")
                    )
                end)
                Library:Notify(string.format("Dumped LP/%s — %d scripts", label, count))
            end,
        })
    end

    -- ================================================================
    -- UI — RIGHT GROUPBOX: Remote Spy
    -- ================================================================
    local rightBox = Tabs.Dumper:AddRightGroupbox("Remote Spy")

    rightBox:AddLabel("Hooks FireServer / InvokeServer")
    rightBox:AddLabel("via __namecall intercept")

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
                "Remotes fired: %d (buffered: %d)",
                remotesFired, #remoteLog
            ))
        end,
    })

    -- ================================================================
    -- PUBLIC API (optional — lets caller access internals)
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
