-- ================================================================
--  features/dumper.lua
--  Universal Environment Dumper — Linoria UI Integration
--  Features: Script Dump, Instance Tree, Network Meta,
--            Env Globals, Remote Spy (__namecall hook)
-- ================================================================

return function(State, Tabs, Services, Library)

    -- ================================================================
    --  SERVICES
    -- ================================================================
    local RunService     = game:GetService("RunService")
    local PlayersService = game:GetService("Players")
    local HttpService    = game:GetService("HttpService")
    local LocalPlayer    = PlayersService.LocalPlayer

    -- ================================================================
    --  FILESYSTEM SETUP
    --  Wrapped fully in pcall — if the executor does not support
    --  makefolder or writefile the tab still loads and shows buttons.
    -- ================================================================
    local LOG_ROOT     = "YazuDumperLogs"
    local SESSION_DIR  = LOG_ROOT .. "/" .. tostring(os.time())
    local FS_OK        = false

    pcall(function()
        if type(makefolder) ~= "function" then return end
        makefolder(LOG_ROOT)
        makefolder(SESSION_DIR)
        FS_OK = true
    end)

    -- ================================================================
    --  UTILITY HELPERS
    -- ================================================================

    -- Write a file safely; notifies instead of crashing if FS unavailable
    local function writeOut(filename, content)
        if not FS_OK then
            Library:Notify("File output unavailable on this executor")
            return false
        end
        local ok, err = pcall(writefile, SESSION_DIR .. "/" .. filename, content)
        if not ok then
            Library:Notify("Write failed: " .. tostring(err))
        end
        return ok
    end

    -- Read a file safely; returns "" on any failure
    local function readBack(filename)
        if not FS_OK then return "" end
        local ok, data = pcall(readfile, SESSION_DIR .. "/" .. filename)
        return (ok and type(data) == "string") and data or ""
    end

    -- Run a function and show any error as a notification
    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then
            Library:Notify("Error: " .. tostring(err))
        end
        return ok
    end

    -- Build a full instance path string usable as Lua code
    local function instancePath(inst)
        if not inst or inst == game then return "game" end
        local parts = {}
        local cur = inst
        while cur and cur ~= game do
            table.insert(parts, 1, cur.Name)
            cur = cur.Parent
        end
        if #parts == 0 then return "game" end

        -- First segment: try GetService, fall back to index notation
        local root
        local serviceOk = pcall(function() game:GetService(parts[1]) end)
        if serviceOk then
            root = 'game:GetService("' .. parts[1] .. '")'
        else
            root = 'game["' .. parts[1] .. '"]'
        end

        local path = root
        for i = 2, #parts do
            local seg = parts[i]
            -- Use bracket notation for names with non-identifier characters
            if seg:match("[^%w_]") or seg:match("^%d") then
                path = path .. '["' .. seg .. '"]'
            else
                path = path .. "." .. seg
            end
        end
        return path
    end

    -- Try to get source from a script instance
    local function getSource(inst)
        if inst:IsA("Script") then
            return "-- [ServerScript] source not accessible from client"
        end
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
            return result
        end
        return "-- Decompile failed" .. (ok and "" or ": " .. tostring(result))
    end

    -- ================================================================
    --  FEATURE: SCRIPT SOURCE DUMP
    --  Crawls a given set of containers and writes all scripts
    --  into a single .lua file.
    -- ================================================================
    local function dumpScripts(containers, outFilename)
        local count  = 0
        local lines  = {
            "-- ============================================================",
            "-- Yazu Script Source Dump",
            "-- " .. os.date("%Y-%m-%d %H:%M:%S"),
            "-- PlaceId: " .. tostring(game.PlaceId),
            "-- ============================================================",
            "",
        }

        for _, pair in ipairs(containers) do
            local label, container = pair[1], pair[2]
            if container then
                table.insert(lines, string.rep("=", 60))
                table.insert(lines, "-- CONTAINER: " .. label)
                table.insert(lines, string.rep("=", 60))
                table.insert(lines, "")

                local ok, descendants = pcall(function()
                    return container:GetDescendants()
                end)
                if ok then
                    for _, inst in ipairs(descendants) do
                        if inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script") then
                            count = count + 1
                            table.insert(lines, string.format(
                                "-- [%s]  %s  (%s)",
                                label, inst:GetFullName(), inst.ClassName
                            ))
                            table.insert(lines, getSource(inst))
                            table.insert(lines, "")
                            table.insert(lines, string.rep("-", 60))
                            table.insert(lines, "")
                            -- Yield per-script to prevent lag spikes
                            RunService.RenderStepped:Wait()
                        end
                    end
                end
            end
        end

        writeOut(outFilename, table.concat(lines, "\n"))
        return count
    end

    -- Full dump: all common services + LocalPlayer containers
    local function dumpAllScripts()
        local lp = LocalPlayer
        local containers = {
            { "Workspace",         workspace },
            { "ReplicatedStorage", game:GetService("ReplicatedStorage") },
            { "ReplicatedFirst",   game:GetService("ReplicatedFirst")   },
            { "StarterGui",        game:GetService("StarterGui")        },
            { "StarterPack",       game:GetService("StarterPack")       },
            { "Players",           PlayersService                        },
        }
        -- Append LocalPlayer containers safely
        pcall(function()
            if lp.Backpack   then table.insert(containers, { "LP/Backpack",   lp.Backpack   }) end
            if lp.PlayerGui  then table.insert(containers, { "LP/PlayerGui",  lp.PlayerGui  }) end
            if lp.Character  then table.insert(containers, { "LP/Character",  lp.Character  }) end
        end)
        return dumpScripts(containers, "Script_Dump_ALL.lua")
    end

    -- Single-service dump
    local function dumpService(svcName)
        local container
        local ok, err = pcall(function()
            container = (svcName == "Workspace") and workspace or game:GetService(svcName)
        end)
        if not ok or not container then
            Library:Notify("Could not get service: " .. svcName .. " — " .. tostring(err))
            return 0
        end
        return dumpScripts({{ svcName, container }}, "Script_Dump_" .. svcName .. ".lua")
    end

    -- LocalPlayer container dump
    local function dumpLpContainer(label, getter)
        local container
        pcall(function() container = getter() end)
        if not container then
            Library:Notify(label .. " container not found")
            return 0
        end
        return dumpScripts({{ "LP/" .. label, container }}, "Script_Dump_LP_" .. label .. ".lua")
    end

    -- ================================================================
    --  FEATURE: INSTANCE TREE DUMP
    -- ================================================================
    local function crawl(inst, depth)
        local node = {
            Name      = inst.Name,
            ClassName = inst.ClassName,
            Children  = {},
        }
        if inst:IsA("BasePart") then
            table.insert(node.Children, { Name = "Position", Value = tostring(inst.Position) })
        end
        if depth < 8 then
            for _, child in ipairs(inst:GetChildren()) do
                table.insert(node.Children, crawl(child, depth + 1))
            end
        end
        return node
    end

    local function dumpInstanceTree()
        local tree = crawl(game, 0)
        local encoded
        local ok, err = pcall(function()
            encoded = HttpService:JSONEncode(tree)
        end)
        if not ok then
            Library:Notify("JSONEncode failed: " .. tostring(err))
            return
        end
        writeOut("Instance_Tree.json", encoded)
    end

    -- ================================================================
    --  FEATURE: NETWORK METADATA DUMP
    -- ================================================================
    local function dumpNetworkMeta()
        local players     = PlayersService:GetPlayers()
        local names       = {}
        for _, p in ipairs(players) do
            table.insert(names, p.Name)
        end

        local lines = {
            "=== Yazu Network Metadata ===",
            "Timestamp : " .. os.date("%Y-%m-%d %H:%M:%S"),
            "GameId    : " .. tostring(game.GameId),
            "PlaceId   : " .. tostring(game.PlaceId),
            "JobId     : " .. tostring(game.JobId),
            "Players   : " .. tostring(#players) .. "  [" .. table.concat(names, ", ") .. "]",
            "",
        }

        -- Append to existing file so multiple calls accumulate
        local existing = readBack("Network_Meta.txt")
        writeOut("Network_Meta.txt", existing .. table.concat(lines, "\n"))
    end

    -- ================================================================
    --  FEATURE: ENVIRONMENT GLOBALS DUMP
    -- ================================================================
    local function dumpEnvGlobals()
        if type(getgenv) ~= "function" then
            Library:Notify("getgenv() not supported by this executor")
            return
        end

        local lines = {
            "=== Yazu Environment Globals ===",
            "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "",
        }

        local env = getgenv()
        -- Collect and sort keys for a readable output
        local keys = {}
        for k in pairs(env) do
            table.insert(keys, k)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, k in ipairs(keys) do
            local v = env[k]
            table.insert(lines, string.format(
                "%-40s = %-30s  [%s]",
                tostring(k), tostring(v), typeof(v)
            ))
        end

        writeOut("Env_Globals.txt", table.concat(lines, "\n"))
    end

    -- ================================================================
    --  FEATURE: REMOTE SPY  (__namecall hook)
    -- ================================================================
    local spyActive       = false
    local spyLog          = {}
    local spyTotal        = 0
    local hookInstalled   = false
    local originalCall    = nil

    local function buildScript(object, method, args)
        local lines = {
            "-- [RemoteSpy] " .. os.date("%H:%M:%S"),
            "-- " .. object.ClassName .. " @ " .. instancePath(object),
            "",
        }

        for i, v in ipairs(args) do
            local t   = typeof(v)
            local rep

            if t == "Instance" then
                rep = instancePath(v)
            elseif t == "string" then
                rep = string.format("%q", v)
            elseif t == "number" then
                rep = tostring(v)
            elseif t == "boolean" then
                rep = tostring(v)
            elseif t == "Vector3" then
                rep = string.format("Vector3.new(%g, %g, %g)", v.X, v.Y, v.Z)
            elseif t == "CFrame" then
                rep = string.format("CFrame.new(%s)", tostring(v))
            elseif t == "Color3" then
                rep = string.format("Color3.new(%g, %g, %g)", v.R, v.G, v.B)
            elseif t == "EnumItem" then
                rep = "Enum." .. tostring(v.EnumType) .. "." .. v.Name
            elseif t == "table" then
                rep = "{--[[table]]}"
            else
                rep = tostring(v)
            end

            table.insert(lines, string.format("local A%d = %s", i, rep))
        end

        local argNames = {}
        for i = 1, #args do table.insert(argNames, "A" .. i) end

        table.insert(lines, "local Remote = " .. instancePath(object))
        table.insert(lines, "Remote:" .. method .. "(" .. table.concat(argNames, ", ") .. ")")

        return table.concat(lines, "\n")
    end

    local function flushSpy()
        if #spyLog == 0 then return end
        local lines = {
            "-- ==============================================",
            "-- Yazu RemoteSpy Log",
            "-- Flushed: " .. os.date("%Y-%m-%d %H:%M:%S"),
            "-- Total calls this session: " .. tostring(spyTotal),
            "-- ==============================================",
            "",
        }
        for _, entry in ipairs(spyLog) do
            table.insert(lines, entry)
            table.insert(lines, string.rep("-", 40))
            table.insert(lines, "")
        end
        writeOut("Remote_Log.lua", table.concat(lines, "\n"))
    end

    local function installHook()
        if hookInstalled then return true end

        if type(getrawmetatable) ~= "function" then
            Library:Notify("RemoteSpy needs getrawmetatable() — not available")
            return false
        end
        if type(getnamecallmethod) ~= "function" then
            Library:Notify("RemoteSpy needs getnamecallmethod() — not available")
            return false
        end

        local meta = getrawmetatable(game)
        if not meta then
            Library:Notify("RemoteSpy: could not read game metatable")
            return false
        end

        -- Unlock the metatable
        if type(setreadonly) == "function" then
            pcall(setreadonly, meta, false)
        elseif type(make_writeable) == "function" then
            pcall(make_writeable, meta)
        end

        originalCall = rawget(meta, "__namecall")

        local wrap = (type(newcclosure) == "function") and newcclosure or function(f) return f end

        rawset(meta, "__namecall", wrap(function(self, ...)
            local method = getnamecallmethod()

            if spyActive
                and (method == "FireServer"   or method == "InvokeServer"
                  or method == "fireServer"   or method == "invokeServer")
                and (self:IsA("RemoteEvent")  or self:IsA("RemoteFunction"))
            then
                pcall(function()
                    local args = { ... }
                    spyTotal = spyTotal + 1
                    table.insert(spyLog, buildScript(self, method, args))

                    -- Cap buffer to 300 entries
                    if #spyLog > 300 then
                        table.remove(spyLog, 1)
                    end

                    -- Auto-flush every 25 calls
                    if spyTotal % 25 == 0 then
                        flushSpy()
                    end

                    Library:Notify(
                        string.format("[Spy] #%d  %s → %s", spyTotal, self.Name, method),
                        3
                    )
                end)
            end

            return originalCall(self, ...)
        end))

        hookInstalled = true
        return true
    end

    local function startSpy()
        if spyActive then
            Library:Notify("Remote Spy is already running")
            return
        end
        if installHook() then
            spyActive = true
            Library:Notify("Remote Spy: ON")
        end
    end

    local function stopSpy()
        if not spyActive then
            Library:Notify("Remote Spy is not running")
            return
        end
        spyActive = false
        flushSpy()
        Library:Notify(string.format(
            "Remote Spy: OFF — %d calls saved to Remote_Log.lua",
            spyTotal
        ))
    end

    local function clearSpy()
        spyLog   = {}
        spyTotal = 0
        Library:Notify("Remote log cleared")
    end

    -- ================================================================
    --  UI — LEFT SIDE
    -- ================================================================

    -- Groupbox 1: main dump actions
    local DumpGrp = Tabs.Dumper:AddLeftGroupbox("Script Dumper")

    DumpGrp:AddButton({
        Text = "Dump ALL Scripts",
        Func = function()
            guarded(function()
                local n = dumpAllScripts()
                Library:Notify(string.format("Done — %d scripts → Script_Dump_ALL.lua", n))
            end)
        end,
    })

    DumpGrp:AddButton({
        Text = "Dump Instance Tree",
        Func = function()
            guarded(function()
                dumpInstanceTree()
                Library:Notify("Instance tree saved → Instance_Tree.json")
            end)
        end,
    })

    DumpGrp:AddButton({
        Text = "Dump Network Metadata",
        Func = function()
            guarded(function()
                dumpNetworkMeta()
                Library:Notify("Network metadata saved → Network_Meta.txt")
            end)
        end,
    })

    DumpGrp:AddButton({
        Text = "Dump Env Globals",
        Func = function()
            guarded(function()
                dumpEnvGlobals()
                Library:Notify("Globals saved → Env_Globals.txt")
            end)
        end,
    })

    DumpGrp:AddButton({
        Text = "Full Dump (All of the above)",
        Func = function()
            guarded(function()
                local n = dumpAllScripts()
                dumpInstanceTree()
                dumpNetworkMeta()
                dumpEnvGlobals()
                Library:Notify(string.format("Full dump done — %d scripts", n))
            end)
        end,
    })

    DumpGrp:AddButton({
        Text = "Show Output Folder",
        Func = function()
            Library:Notify("Output: " .. SESSION_DIR)
        end,
    })

    -- Groupbox 2: per-service dumps
    local SvcGrp = Tabs.Dumper:AddLeftGroupbox("Dump by Service")

    local SERVICE_LIST = {
        "Workspace",
        "ReplicatedStorage",
        "ReplicatedFirst",
        "StarterGui",
        "StarterPack",
        "Players",
    }

    for _, name in ipairs(SERVICE_LIST) do
        local svcName = name -- capture for closure
        SvcGrp:AddButton({
            Text = svcName,
            Func = function()
                guarded(function()
                    local n = dumpService(svcName)
                    Library:Notify(string.format(
                        "%s — %d scripts dumped", svcName, n
                    ))
                end)
            end,
        })
    end

    -- Groupbox 3: LocalPlayer container dumps
    local LpGrp = Tabs.Dumper:AddLeftGroupbox("LocalPlayer Dumps")

    local LP_CONTAINERS = {
        { "Backpack",  function() return LocalPlayer.Backpack  end },
        { "PlayerGui", function() return LocalPlayer.PlayerGui end },
        { "Character", function() return LocalPlayer.Character end },
    }

    for _, pair in ipairs(LP_CONTAINERS) do
        local label, getter = pair[1], pair[2]
        LpGrp:AddButton({
            Text = "LP / " .. label,
            Func = function()
                guarded(function()
                    local n = dumpLpContainer(label, getter)
                    Library:Notify(string.format(
                        "LP/%s — %d scripts dumped", label, n
                    ))
                end)
            end,
        })
    end

    -- ================================================================
    --  UI — RIGHT SIDE: Remote Spy
    -- ================================================================
    local SpyGrp = Tabs.Dumper:AddRightGroupbox("Remote Spy")

    SpyGrp:AddLabel("Hooks FireServer & InvokeServer")
    SpyGrp:AddLabel("via __namecall metatable hook")

    SpyGrp:AddButton({
        Text = "Enable Remote Spy",
        Func = startSpy,
    })

    SpyGrp:AddButton({
        Text = "Disable + Save Log",
        Func = stopSpy,
    })

    SpyGrp:AddButton({
        Text = "Flush Log Now",
        Func = function()
            guarded(function()
                flushSpy()
                Library:Notify(string.format(
                    "Flushed %d buffered entries → Remote_Log.lua",
                    #spyLog
                ))
            end)
        end,
    })

    SpyGrp:AddButton({
        Text = "Clear Log Buffer",
        Func = clearSpy,
    })

    SpyGrp:AddButton({
        Text = "Show Call Count",
        Func = function()
            Library:Notify(string.format(
                "Total: %d calls  |  Buffered: %d",
                spyTotal, #spyLog
            ))
        end,
    })

    -- ================================================================
    --  PUBLIC API (returned for any other feature that needs it)
    -- ================================================================
    return {
        dumpAllScripts    = dumpAllScripts,
        dumpService       = dumpService,
        dumpInstanceTree  = dumpInstanceTree,
        dumpNetworkMeta   = dumpNetworkMeta,
        dumpEnvGlobals    = dumpEnvGlobals,
        startSpy          = startSpy,
        stopSpy           = stopSpy,
        flushSpy          = flushSpy,
        clearSpy          = clearSpy,
    }
end
