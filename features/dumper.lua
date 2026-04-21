-- ================================================================
--  features/dumper.lua
--  Universal Environment Dumper — Yazu / Linoria UI
--  Called by main.lua as: load('features/dumper.lua')(State, Tabs, Services, Library)
-- ================================================================

return function(State, Tabs, Services, Library)

    -- ── Services (via shared Services table, same as every other feature) ──
    local RunService  = Services.RunService
    local Players     = Services.Players
    local HttpService = Services.HttpService
    local LocalPlayer = Services.LocalPlayer

    -- ── Folder setup ────────────────────────────────────────────────────────
    local LOG_ROOT     = 'UniversalDumperLogs'
    local outputFolder = string.format('%s/%d', LOG_ROOT, os.time())
    makefolder(LOG_ROOT)
    makefolder(outputFolder)

    -- ── Helpers ─────────────────────────────────────────────────────────────
    local function safeCall(fn)
        local ok, err = pcall(fn)
        if not ok then Library:Notify('Dump error: ' .. tostring(err)) end
        return ok
    end

    local function safeRead(path)
        local ok, data = pcall(readfile, path)
        return (ok and data) or ''
    end

    local function getInstancePath(inst)
        if not inst or inst == game then return 'game' end
        local parts, obj = {}, inst
        while obj and obj ~= game do
            table.insert(parts, 1, tostring(obj.Name))
            obj = obj.Parent
        end
        local out = 'game:GetService("' .. parts[1] .. '")'
        for i = 2, #parts do
            local seg = parts[i]
            out = out .. (seg:match('[^%w_]') and ('["' .. seg .. '"]') or ('.' .. seg))
        end
        return out
    end

    -- ================================================================
    --  SCRIPT SOURCE DUMP
    -- ================================================================
    local function dumpScriptSources()
        local count  = 0
        local chunks = {
            '-- Script Source Dump',
            '-- Generated : ' .. os.date('%Y-%m-%d %H:%M:%S'),
            '-- Place ID  : ' .. tostring(game.PlaceId),
            '',
        }

        local function sep(label)
            table.insert(chunks, string.rep('=', 60))
            table.insert(chunks, '-- SERVICE: ' .. label)
            table.insert(chunks, string.rep('=', 60))
            table.insert(chunks, '')
        end

        local function process(inst, label)
            if not (inst:IsA('LocalScript') or inst:IsA('ModuleScript') or inst:IsA('Script')) then return end
            count += 1
            table.insert(chunks, string.format('-- [%s] %s  (%s)', label, inst:GetFullName(), inst.ClassName))
            local src
            if inst:IsA('Script') then
                src = '-- ServerScript: not readable from client.'
            else
                local ok, res = pcall(function()
                    if type(decompile) == 'function' then
                        local d = decompile(inst)
                        if type(d) == 'string' and #d > 0 then return d end
                    end
                    local s = inst.Source
                    if type(s) == 'string' and #s > 0 then return s end
                end)
                src = (ok and res) or '-- Decompile failed'
            end
            table.insert(chunks, src)
            table.insert(chunks, string.rep('-', 60))
            table.insert(chunks, '')
            RunService.RenderStepped:Wait()
        end

        local targets = {
            { 'Workspace',         workspace },
            { 'ReplicatedStorage', game:GetService('ReplicatedStorage') },
            { 'ReplicatedFirst',   game:GetService('ReplicatedFirst')   },
            { 'StarterGui',        game:GetService('StarterGui')        },
            { 'StarterPack',       game:GetService('StarterPack')       },
            { 'Players',           Players                              },
        }

        for _, p in ipairs(targets) do
            sep(p[1])
            for _, desc in ipairs(p[2]:GetDescendants()) do process(desc, p[1]) end
        end

        pcall(function()
            for _, pair in ipairs({
                { 'LP/Backpack',  LocalPlayer.Backpack  },
                { 'LP/PlayerGui', LocalPlayer.PlayerGui },
                { 'LP/Character', LocalPlayer.Character },
            }) do
                if pair[2] then
                    sep(pair[1])
                    for _, desc in ipairs(pair[2]:GetDescendants()) do process(desc, pair[1]) end
                end
            end
        end)

        writefile(outputFolder .. '/Script_Source_Dump.lua', table.concat(chunks, '\n'))
        return count
    end

    local function dumpSingleService(svcName)
        local svc
        local ok = pcall(function()
            svc = svcName == 'Workspace' and workspace or game:GetService(svcName)
        end)
        if not ok then Library:Notify('Service not found: ' .. svcName); return 0 end

        local count  = 0
        local chunks = { '-- Dump: ' .. svcName, '-- ' .. os.date('%Y-%m-%d %H:%M:%S'), '' }

        for _, inst in ipairs(svc:GetDescendants()) do
            if inst:IsA('LocalScript') or inst:IsA('ModuleScript') or inst:IsA('Script') then
                count += 1
                local src
                if inst:IsA('Script') then
                    src = '-- ServerScript.'
                else
                    local sok, sres = pcall(function()
                        if type(decompile) == 'function' then
                            local d = decompile(inst)
                            if type(d) == 'string' and #d > 0 then return d end
                        end
                        local s = inst.Source
                        if type(s) == 'string' and #s > 0 then return s end
                    end)
                    src = (sok and sres) or '-- Decompile failed'
                end
                table.insert(chunks, '-- ' .. inst:GetFullName() .. '  (' .. inst.ClassName .. ')')
                table.insert(chunks, src)
                table.insert(chunks, string.rep('-', 60))
                table.insert(chunks, '')
                RunService.RenderStepped:Wait()
            end
        end

        writefile(string.format('%s/Dump_%s.lua', outputFolder, svcName), table.concat(chunks, '\n'))
        return count
    end

    -- ================================================================
    --  OTHER DUMPS
    -- ================================================================
    local function dumpInstanceTree()
        local function crawl(inst, depth)
            local t = { Name = inst.Name, ClassName = inst.ClassName, Children = {} }
            if depth < 8 then
                for _, child in ipairs(inst:GetChildren()) do
                    table.insert(t.Children, crawl(child, depth + 1))
                end
            end
            return t
        end
        writefile(outputFolder .. '/Instance_Tree.json', HttpService:JSONEncode(crawl(game, 0)))
    end

    local function dumpNetworkMetadata()
        local plrs  = Players:GetPlayers()
        local names = {}
        for _, p in ipairs(plrs) do table.insert(names, p.Name) end
        local content = table.concat({
            '=== Network Metadata ===',
            'Time     : ' .. os.date('%Y-%m-%d %H:%M:%S'),
            'Game ID  : ' .. tostring(game.GameId),
            'Place ID : ' .. tostring(game.PlaceId),
            'Job ID   : ' .. tostring(game.JobId),
            'Players  : ' .. #plrs .. ' — [' .. table.concat(names, ', ') .. ']',
            '',
        }, '\n')
        writefile(outputFolder .. '/Network_Metadata.txt', safeRead(outputFolder .. '/Network_Metadata.txt') .. content)
    end

    local function dumpEnvironmentGlobals()
        local lines = { '=== Environment Globals ===', os.date('%Y-%m-%d %H:%M:%S'), '' }
        for k, v in pairs(getgenv()) do
            table.insert(lines, string.format('%-40s = %-20s  [%s]', tostring(k), tostring(v), typeof(v)))
        end
        writefile(outputFolder .. '/Environment_Globals.txt', table.concat(lines, '\n'))
    end

    -- ================================================================
    --  REMOTE SPY
    -- ================================================================
    local spyActive        = false
    local remoteLog        = {}
    local remotesFired     = 0
    local namecallHooked   = false
    local originalNamecall = nil

    local function buildScript(object, method, args)
        local lines = {
            '-- RemoteSpy capture @ ' .. os.date('%H:%M:%S'),
            '-- ' .. object.ClassName .. ' : ' .. getInstancePath(object),
            '',
        }
        for i, v in ipairs(args) do
            local t = typeof(v)
            local s
            if     t == 'Instance' then s = getInstancePath(v)
            elseif t == 'string'   then s = string.format('%q', v)
            elseif t == 'Vector3'  then s = string.format('Vector3.new(%s)', tostring(v))
            elseif t == 'CFrame'   then s = string.format('CFrame.new(%s)', tostring(v))
            elseif t == 'Color3'   then s = string.format('Color3.new(%s)', tostring(v))
            elseif t == 'EnumItem' then s = 'Enum.' .. tostring(v.EnumType) .. '.' .. tostring(v.Name)
            elseif t == 'table'    then s = '{--[[table]]}'
            else                        s = tostring(v)
            end
            table.insert(lines, string.format('local A_%d = %s', i, s))
        end
        local argList = {}
        for i = 1, #args do table.insert(argList, 'A_' .. i) end
        table.insert(lines, 'local Remote = ' .. getInstancePath(object))
        table.insert(lines, 'Remote:' .. method .. '(' .. table.concat(argList, ', ') .. ')')
        return table.concat(lines, '\n')
    end

    local function flushLog()
        if #remoteLog == 0 then return end
        local lines = { '=== Remote Spy Log ===', 'Flushed: ' .. os.date('%Y-%m-%d %H:%M:%S'), 'Total: ' .. remotesFired, string.rep('-', 60), '' }
        for _, e in ipairs(remoteLog) do
            table.insert(lines, e)
            table.insert(lines, string.rep('-', 40))
            table.insert(lines, '')
        end
        writefile(outputFolder .. '/Remote_Log.lua', table.concat(lines, '\n'))
    end

    local function hookNamecall()
        if namecallHooked then return true end
        if not getrawmetatable or not getnamecallmethod then
            Library:Notify('RemoteSpy: executor missing getrawmetatable/getnamecallmethod')
            return false
        end
        local meta = getrawmetatable(game)
        if not meta then Library:Notify('RemoteSpy: no game metatable'); return false end
        if setreadonly then setreadonly(meta, false) elseif make_writeable then make_writeable(meta) end
        originalNamecall = meta.__namecall
        local wrap = type(newcclosure) == 'function' and newcclosure or function(f) return f end
        meta.__namecall = wrap(function(obj, ...)
            local method = getnamecallmethod()
            if spyActive and method and (method == 'FireServer' or method == 'InvokeServer') then
                pcall(function()
                    if obj:IsA('RemoteEvent') or obj:IsA('RemoteFunction') then
                        local args = { ... }
                        remotesFired += 1
                        table.insert(remoteLog, buildScript(obj, method, args))
                        if #remoteLog > 300 then table.remove(remoteLog, 1) end
                        if remotesFired % 25 == 0 then flushLog() end
                        Library:Notify(string.format('[RemoteSpy] #%d %s:%s', remotesFired, obj.Name, method), 3)
                    end
                end)
            end
            return originalNamecall(obj, ...)
        end)
        namecallHooked = true
        return true
    end

    -- ================================================================
    --  UI — mirrors the exact pattern used in esp.lua / misc.lua
    -- ================================================================
    local LeftBox  = Tabs.Dumper:AddLeftGroupbox('Dumper')
    local RightBox = Tabs.Dumper:AddRightGroupbox('Remote Spy')

    -- ── Left: main dumps ────────────────────────────────────────────
    LeftBox:AddButton({ Text = 'Full Dump (All Services)', Func = function()
        safeCall(function()
            local n = dumpScriptSources()
            dumpInstanceTree()
            dumpNetworkMetadata()
            dumpEnvironmentGlobals()
            Library:Notify(string.format('Full dump done — %d scripts saved', n))
        end)
    end })

    LeftBox:AddButton({ Text = 'Dump Script Sources', Func = function()
        local n = 0
        safeCall(function() n = dumpScriptSources() end)
        Library:Notify(string.format('Script dump done — %d scripts', n))
    end })

    LeftBox:AddButton({ Text = 'Dump Instance Tree', Func = function()
        safeCall(dumpInstanceTree)
        Library:Notify('Instance tree saved → Instance_Tree.json')
    end })

    LeftBox:AddButton({ Text = 'Dump Network Metadata', Func = function()
        safeCall(dumpNetworkMetadata)
        Library:Notify('Network metadata saved')
    end })

    LeftBox:AddButton({ Text = 'Dump Env Globals', Func = function()
        safeCall(dumpEnvironmentGlobals)
        Library:Notify('Env globals saved')
    end })

    LeftBox:AddButton({ Text = 'Show Output Path', Func = function()
        Library:Notify(outputFolder)
    end })

    LeftBox:AddLabel('── By Service ──')

    for _, svc in ipairs({ 'Workspace', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterGui', 'StarterPack', 'Players' }) do
        LeftBox:AddButton({ Text = 'Dump: ' .. svc, Func = function()
            local n = 0
            safeCall(function() n = dumpSingleService(svc) end)
            Library:Notify(string.format('%s — %d scripts dumped', svc, n))
        end })
    end

    LeftBox:AddLabel('── LocalPlayer ──')

    for _, pair in ipairs({
        { 'Backpack',  function() return LocalPlayer.Backpack  end },
        { 'PlayerGui', function() return LocalPlayer.PlayerGui end },
        { 'Character', function() return LocalPlayer.Character end },
    }) do
        local name, getter = pair[1], pair[2]
        LeftBox:AddButton({ Text = 'Dump: LP/' .. name, Func = function()
            local n = 0
            local chunks = { '-- LP/' .. name .. ' dump', os.date('%Y-%m-%d %H:%M:%S'), '' }
            safeCall(function()
                local container = getter()
                if not container then Library:Notify(name .. ' not found'); return end
                for _, inst in ipairs(container:GetDescendants()) do
                    if inst:IsA('LocalScript') or inst:IsA('ModuleScript') or inst:IsA('Script') then
                        n += 1
                        local src
                        if inst:IsA('Script') then
                            src = '-- ServerScript'
                        else
                            local ok, res = pcall(function()
                                if type(decompile) == 'function' then
                                    local d = decompile(inst)
                                    if type(d) == 'string' and #d > 0 then return d end
                                end
                                return inst.Source
                            end)
                            src = (ok and res and #res > 0) and res or '-- Decompile failed'
                        end
                        table.insert(chunks, '-- ' .. inst:GetFullName())
                        table.insert(chunks, src)
                        table.insert(chunks, string.rep('-', 60))
                        table.insert(chunks, '')
                        RunService.RenderStepped:Wait()
                    end
                end
                writefile(string.format('%s/Dump_LP_%s.lua', outputFolder, name), table.concat(chunks, '\n'))
            end)
            Library:Notify(string.format('LP/%s — %d scripts dumped', name, n))
        end })
    end

    -- ── Right: Remote Spy ────────────────────────────────────────────
    RightBox:AddLabel('Hooks FireServer / InvokeServer')

    RightBox:AddToggle('DumperRemoteSpy', {
        Text     = 'Enable Remote Spy',
        Default  = false,
        Callback = function(val)
            if val then
                if hookNamecall() then
                    spyActive = true
                    Library:Notify('Remote Spy: ON')
                else
                    Toggles.DumperRemoteSpy:SetValue(false)
                end
            else
                spyActive = false
                flushLog()
                Library:Notify(string.format('Remote Spy: OFF — %d calls logged', remotesFired))
            end
        end,
    })

    RightBox:AddButton({ Text = 'Flush Log Now', Func = function()
        flushLog()
        Library:Notify(string.format('Flushed %d entries', #remoteLog))
    end })

    RightBox:AddButton({ Text = 'Clear Log', Func = function()
        remoteLog    = {}
        remotesFired = 0
        Library:Notify('Remote log cleared')
    end })

    RightBox:AddButton({ Text = 'Show Call Count', Func = function()
        Library:Notify(string.format('Fired: %d  Buffered: %d', remotesFired, #remoteLog))
    end })

end
