-- ================================================================
--  features/dumper.lua
--  Script Dump | Instance Tree | Network Meta | Env Globals | Remote Spy
-- ================================================================

return function(State, Tabs, Services, Library)

print("[Dumper] Loading...")

-- ================================================================
--  SERVICES  (all sourced from game directly, not the Services table,
--  so dumper has no dependency on Services being set up correctly)
-- ================================================================
local RS      = game:GetService("RunService")
local Players = game:GetService("Players")
local HTTP    = game:GetService("HttpService")
local LP      = Players.LocalPlayer

-- ================================================================
--  FILESYSTEM
--  Folder is created lazily on first use, NOT at load time.
--  This is the root cause of the original crash — makefolder was
--  called at load time without pcall, killing the whole feature.
-- ================================================================
local ROOT_FOLDER = "YazuDumper"
local SESSION_ID  = tostring(os.time())
local SESSION_DIR = ROOT_FOLDER .. "/" .. SESSION_ID
local FS_READY    = false

local function ensureFS()
    if FS_READY then return true end
    if type(makefolder) ~= "function" then return false end
    local ok = pcall(function()
        makefolder(ROOT_FOLDER)
        makefolder(SESSION_DIR)
    end)
    if ok then
        FS_READY = true
        print("[Dumper] Filesystem ready: " .. SESSION_DIR)
    else
        print("[Dumper] makefolder failed")
    end
    return FS_READY
end

local function writeFile(name, content)
    if not ensureFS() then
        Library:Notify("Filesystem not supported on this executor")
        return false
    end
    local ok, err = pcall(writefile, SESSION_DIR .. "/" .. name, content)
    if not ok then
        Library:Notify("Write failed: " .. tostring(err))
        print("[Dumper] Write error: " .. tostring(err))
    end
    return ok
end

local function readFile(name)
    if not FS_READY then return "" end
    local ok, data = pcall(readfile, SESSION_DIR .. "/" .. name)
    return (ok and type(data) == "string") and data or ""
end

-- ================================================================
--  UTILITY
-- ================================================================
local function run(fn)
    local ok, err = pcall(fn)
    if not ok then
        Library:Notify("Error: " .. tostring(err))
        print("[Dumper] Error: " .. tostring(err))
    end
end

local function buildPath(inst)
    if not inst or inst == game then return "game" end
    local parts = {}
    local cur = inst
    while cur and cur ~= game do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    if #parts == 0 then return "game" end
    local isService = false
    pcall(function() game:GetService(parts[1]); isService = true end)
    local path = isService
        and ('game:GetService("' .. parts[1] .. '")')
        or  ('game["'            .. parts[1] .. '"]')
    for i = 2, #parts do
        local s = parts[i]
        if s:match("[^%w_]") or s:match("^%d") then
            path = path .. '["' .. s .. '"]'
        else
            path = path .. "." .. s
        end
    end
    return path
end

local function getSource(inst)
    if inst:IsA("Script") then
        return "-- [ServerScript] not readable from client"
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
    if ok and result then return result end
    return "-- decompile failed" .. (ok and "" or ": " .. tostring(result))
end

-- ================================================================
--  SCRIPT DUMP CORE
-- ================================================================
local function dumpContainers(containers, outFile)
    local count = 0
    local lines = {
        "-- Yazu Script Dump",
        "-- " .. os.date("%Y-%m-%d %H:%M:%S"),
        "-- PlaceId: " .. tostring(game.PlaceId),
        "",
    }

    for i = 1, #containers do
        local label     = containers[i][1]
        local container = containers[i][2]
        if container then
            table.insert(lines, string.rep("=", 60))
            table.insert(lines, "-- " .. label)
            table.insert(lines, string.rep("=", 60))
            table.insert(lines, "")
            local ok, desc = pcall(function() return container:GetDescendants() end)
            if ok then
                for _, inst in ipairs(desc) do
                    if inst:IsA("LocalScript") or inst:IsA("ModuleScript") or inst:IsA("Script") then
                        count = count + 1
                        table.insert(lines, "-- " .. inst:GetFullName() .. " (" .. inst.ClassName .. ")")
                        table.insert(lines, getSource(inst))
                        table.insert(lines, string.rep("-", 60))
                        table.insert(lines, "")
                        RS.RenderStepped:Wait()
                    end
                end
            end
        end
    end

    writeFile(outFile, table.concat(lines, "\n"))
    return count
end

local function dumpAll()
    local lp = LP
    local containers = {
        { "Workspace",         workspace },
        { "ReplicatedStorage", game:GetService("ReplicatedStorage") },
        { "ReplicatedFirst",   game:GetService("ReplicatedFirst")   },
        { "StarterGui",        game:GetService("StarterGui")        },
        { "StarterPack",       game:GetService("StarterPack")       },
        { "Players",           Players                              },
    }
    pcall(function()
        if lp.Backpack   then table.insert(containers, { "LP/Backpack",   lp.Backpack   }) end
        if lp.PlayerGui  then table.insert(containers, { "LP/PlayerGui",  lp.PlayerGui  }) end
        if lp.Character  then table.insert(containers, { "LP/Character",  lp.Character  }) end
    end)
    return dumpContainers(containers, "ALL_Scripts.lua")
end

local function dumpService(svcName)
    local svc
    local ok, err = pcall(function()
        svc = (svcName == "Workspace") and workspace or game:GetService(svcName)
    end)
    if not ok or not svc then
        Library:Notify("Service error: " .. tostring(err))
        return 0
    end
    return dumpContainers({{ svcName, svc }}, svcName .. ".lua")
end

local function dumpLP(label, getter)
    local c
    pcall(function() c = getter() end)
    if not c then Library:Notify(label .. " not found"); return 0 end
    return dumpContainers({{ "LP/" .. label, c }}, "LP_" .. label .. ".lua")
end

-- ================================================================
--  INSTANCE TREE
-- ================================================================
local function crawl(inst, depth)
    local node = { Name = inst.Name, ClassName = inst.ClassName, Children = {} }
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

local function dumpTree()
    local ok, encoded = pcall(function()
        return HTTP:JSONEncode(crawl(game, 0))
    end)
    if not ok then Library:Notify("JSON encode failed"); return end
    writeFile("Instance_Tree.json", encoded)
end

-- ================================================================
--  NETWORK METADATA
-- ================================================================
local function dumpNetwork()
    local plrs = Players:GetPlayers()
    local names = {}
    for _, p in ipairs(plrs) do table.insert(names, p.Name) end
    local content = table.concat({
        "-- Yazu Network Metadata",
        "-- " .. os.date("%Y-%m-%d %H:%M:%S"),
        "GameId:   " .. tostring(game.GameId),
        "PlaceId:  " .. tostring(game.PlaceId),
        "JobId:    " .. tostring(game.JobId),
        "Players:  " .. #plrs .. "  [" .. table.concat(names, ", ") .. "]",
        "",
    }, "\n")
    writeFile("Network_Meta.txt", readFile("Network_Meta.txt") .. content)
end

-- ================================================================
--  ENV GLOBALS
-- ================================================================
local function dumpGlobals()
    if type(getgenv) ~= "function" then
        Library:Notify("getgenv() not available on this executor")
        return
    end
    local lines = {
        "-- Yazu Env Globals",
        "-- " .. os.date("%Y-%m-%d %H:%M:%S"),
        "",
    }
    local env = getgenv()
    local keys = {}
    for k in pairs(env) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = env[k]
        table.insert(lines, string.format("%-40s = %-30s [%s]", tostring(k), tostring(v), type(v)))
    end
    writeFile("Env_Globals.txt", table.concat(lines, "\n"))
end

-- ================================================================
--  REMOTE SPY
-- ================================================================
local spyOn      = false
local spyLog     = {}
local spyCount   = 0
local spyHooked  = false
local spyOldCall = nil

local function buildCallScript(obj, method, args)
    local lines = {
        "-- [RemoteSpy] " .. os.date("%H:%M:%S"),
        "-- " .. obj.ClassName .. " @ " .. buildPath(obj),
        "",
    }
    for i, v in ipairs(args) do
        local t = type(v)
        local rep
        if t == "userdata" then
            local ok, tn = pcall(function() return typeof(v) end)
            local typeName = ok and tn or "userdata"
            if typeName == "Instance"  then rep = buildPath(v)
            elseif typeName == "Vector3"  then rep = "Vector3.new(" .. tostring(v.X) .. "," .. tostring(v.Y) .. "," .. tostring(v.Z) .. ")"
            elseif typeName == "CFrame"   then rep = "CFrame.new(" .. tostring(v) .. ")"
            elseif typeName == "Color3"   then rep = "Color3.new(" .. tostring(v.R) .. "," .. tostring(v.G) .. "," .. tostring(v.B) .. ")"
            elseif typeName == "EnumItem" then rep = "Enum." .. tostring(v.EnumType) .. "." .. tostring(v.Name)
            else                               rep = tostring(v)
            end
        elseif t == "string"  then rep = string.format("%q", v)
        elseif t == "table"   then rep = "{--[[table]]}"
        else                       rep = tostring(v)
        end
        table.insert(lines, "local A" .. i .. " = " .. rep)
    end
    local argList = {}
    for i = 1, #args do table.insert(argList, "A" .. i) end
    table.insert(lines, "local Remote = " .. buildPath(obj))
    table.insert(lines, "Remote:" .. method .. "(" .. table.concat(argList, ", ") .. ")")
    return table.concat(lines, "\n")
end

local function flushSpy()
    if #spyLog == 0 then return end
    local lines = {
        "-- Yazu Remote Spy Log",
        "-- Flushed: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "-- Total calls: " .. tostring(spyCount),
        string.rep("-", 60),
        "",
    }
    for _, entry in ipairs(spyLog) do
        table.insert(lines, entry)
        table.insert(lines, string.rep("-", 40))
        table.insert(lines, "")
    end
    writeFile("Remote_Log.lua", table.concat(lines, "\n"))
end

local function hookSpy()
    if spyHooked then return true end
    if type(getrawmetatable)   ~= "function" then Library:Notify("RemoteSpy: no getrawmetatable"); return false end
    if type(getnamecallmethod) ~= "function" then Library:Notify("RemoteSpy: no getnamecallmethod"); return false end
    local meta = getrawmetatable(game)
    if not meta then Library:Notify("RemoteSpy: metatable nil"); return false end
    if type(setreadonly)  == "function" then pcall(setreadonly,  meta, false) end
    if type(make_writeable) == "function" then pcall(make_writeable, meta)    end
    spyOldCall = rawget(meta, "__namecall")
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    rawset(meta, "__namecall", wrap(function(self, ...)
        local method = getnamecallmethod()
        if spyOn and method then
            local m = method:lower()
            if (m == "fireserver" or m == "invokeserver") then
                pcall(function()
                    if self:IsA("RemoteEvent") or self:IsA("RemoteFunction") then
                        local args = {...}
                        spyCount = spyCount + 1
                        table.insert(spyLog, buildCallScript(self, method, args))
                        if #spyLog > 300 then table.remove(spyLog, 1) end
                        if spyCount % 25 == 0 then flushSpy() end
                        Library:Notify("[Spy] #" .. spyCount .. "  " .. self.Name .. ":" .. method, 3)
                    end
                end)
            end
        end
        return spyOldCall(self, ...)
    end))
    spyHooked = true
    return true
end

local function startSpy()
    if spyOn then Library:Notify("Spy already running"); return end
    if hookSpy() then spyOn = true; Library:Notify("Remote Spy: ON") end
end

local function stopSpy()
    if not spyOn then Library:Notify("Spy not running"); return end
    spyOn = false
    flushSpy()
    Library:Notify("Remote Spy: OFF — " .. spyCount .. " calls saved")
end

-- ================================================================
--  UI  —  left side
-- ================================================================
local GrpDump = Tabs.Dumper:AddLeftGroupbox("Script Dumper")

GrpDump:AddButton({ Text = 'Dump ALL Scripts', Func = function()
    run(function()
        local n = dumpAll()
        Library:Notify("Done — " .. n .. " scripts saved")
    end)
end })

GrpDump:AddButton({ Text = 'Dump Instance Tree', Func = function()
    run(function()
        dumpTree()
        Library:Notify("Instance_Tree.json saved")
    end)
end })

GrpDump:AddButton({ Text = 'Dump Network Metadata', Func = function()
    run(function()
        dumpNetwork()
        Library:Notify("Network_Meta.txt saved")
    end)
end })

GrpDump:AddButton({ Text = 'Dump Env Globals', Func = function()
    run(function()
        dumpGlobals()
        Library:Notify("Env_Globals.txt saved")
    end)
end })

GrpDump:AddButton({ Text = 'Full Dump (All Above)', Func = function()
    run(function()
        local n = dumpAll()
        dumpTree()
        dumpNetwork()
        dumpGlobals()
        Library:Notify("Full dump done — " .. n .. " scripts")
    end)
end })

GrpDump:AddButton({ Text = 'Show Output Path', Func = function()
    Library:Notify(SESSION_DIR)
end })

-- Per-service
local GrpSvc = Tabs.Dumper:AddLeftGroupbox("Dump by Service")

local SERVICES = { "Workspace", "ReplicatedStorage", "ReplicatedFirst", "StarterGui", "StarterPack", "Players" }
for i = 1, #SERVICES do
    local svc = SERVICES[i]
    GrpSvc:AddButton({ Text = svc, Func = function()
        run(function()
            local n = dumpService(svc)
            Library:Notify(svc .. " — " .. n .. " scripts saved")
        end)
    end })
end

-- LocalPlayer
local GrpLP = Tabs.Dumper:AddLeftGroupbox("LocalPlayer Dumps")

local LP_TARGETS = {
    { "Backpack",  function() return LP.Backpack  end },
    { "PlayerGui", function() return LP.PlayerGui end },
    { "Character", function() return LP.Character end },
}
for i = 1, #LP_TARGETS do
    local label  = LP_TARGETS[i][1]
    local getter = LP_TARGETS[i][2]
    GrpLP:AddButton({ Text = "LP / " .. label, Func = function()
        run(function()
            local n = dumpLP(label, getter)
            Library:Notify("LP/" .. label .. " — " .. n .. " scripts saved")
        end)
    end })
end

-- ================================================================
--  UI  —  right side: Remote Spy
-- ================================================================
local GrpSpy = Tabs.Dumper:AddRightGroupbox("Remote Spy")

GrpSpy:AddLabel("Hooks FireServer / InvokeServer")
GrpSpy:AddLabel("via __namecall metatable hook")

GrpSpy:AddButton({ Text = 'Enable Spy',     Func = startSpy })
GrpSpy:AddButton({ Text = 'Disable + Save', Func = stopSpy })

GrpSpy:AddButton({ Text = 'Flush Log Now', Func = function()
    run(function()
        flushSpy()
        Library:Notify("Flushed " .. #spyLog .. " entries")
    end)
end })

GrpSpy:AddButton({ Text = 'Clear Log', Func = function()
    spyLog   = {}
    spyCount = 0
    Library:Notify("Log cleared")
end })

GrpSpy:AddButton({ Text = 'Show Count', Func = function()
    Library:Notify("Total: " .. spyCount .. "  Buffered: " .. #spyLog)
end })

print("[Dumper] Loaded OK")

end -- return function
