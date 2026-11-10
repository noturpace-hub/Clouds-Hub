-- Clouds Hub Solova v1.4.0 (v13.1 + Halloween Pumpkin ESP)
-- Requires executor support: getconnections, debug.getupvalues, debug.setupvalue, loadstring/HttpGet.
getgenv().__SOLOVA_AUTOFISH = getgenv().__SOLOVA_AUTOFISH or {}
local S = getgenv().__SOLOVA_AUTOFISH

pcall(function() if S._conn then for _,c in ipairs(S._conn) do pcall(function() c:Disconnect() end) end end end)
pcall(function() if S._thread then task.cancel(S._thread) end end)
pcall(function() if S._ui and S._ui.Destroy then S._ui:Destroy() elseif S._ui and S._ui.Window and S._ui.Window.Destroy then S._ui.Window:Destroy() end end)
pcall(function()
    if S._esp then
        if S._esp.conns then for _,c in ipairs(S._esp.conns) do pcall(function() c:Disconnect() end) end end
        if S._esp.objects then
            for _,o in pairs(S._esp.objects) do
                pcall(function() if o.highlight then o.highlight:Destroy() end end)
                pcall(function() if o.billboard then o.billboard:Destroy() end end)
            end
        end
        if S._esp.folder then pcall(function() S._esp.folder:Destroy() end) end
    end
end)
S._conn = {}
S.running = false
S.mode = S.mode or "V1"
S.castDelay = tonumber(S.castDelay) or 5.0
S.postMinigameDelay = tonumber(S.postMinigameDelay) or 1.8
S.uiToggleKey = S.uiToggleKey or "G"
S._esp = S._esp or { enabled = false }
S._esp.enabled = false
S._esp.objects = {}
S._esp.conns = {}
S._esp.folder = nil

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local lp = Players.LocalPlayer

local IS_MOBILE = (UIS.TouchEnabled and not UIS.KeyboardEnabled)

local function notify(title, msg)
end

local function getRodFunctions()
    local ok, mod = pcall(function()
        local fk = RS:FindFirstChild("FishingKit")
        return fk and fk:FindFirstChild("Modules") and fk.Modules:FindFirstChild("RodFunctions") and require(fk.Modules.RodFunctions)
    end)
    return ok and mod or nil
end

local function getHoldMinigame()
    local pg = lp:FindFirstChild("PlayerGui")
    local ui = pg and pg:FindFirstChild("FishingKitUI")
    return ui and ui:FindFirstChild("HoldMinigame")
end

local function _looksLikeCast(fn)
    local ok2, ups2 = pcall(debug.getupvalues, fn)
    if not ok2 or type(ups2) ~= "table" or #ups2 < 8 then return false end
    local hasRF, hasCF, hasRod = false, false, false
    for _,u in ipairs(ups2) do
        if typeof(u) == "Instance" then
            if u.Name == "RequestFish" then hasRF = true end
            if u.Name == "CatchFish" then hasCF = true end
        elseif type(u) == "table" and rawget(u, "Minigame2") and type(rawget(u, "Minigame2")) == "function" then
            hasRod = true
        end
    end
    return hasRF and hasCF and hasRod
end

local function findCastFunction(force)
    if not force and type(S._castFn) == "function" then return S._castFn end
    local signals = { UIS.InputBegan }
    pcall(function() if UIS.TouchTapInWorld then table.insert(signals, UIS.TouchTapInWorld) end end)
    pcall(function() if UIS.TouchTap then table.insert(signals, UIS.TouchTap) end end)
    local ok, res = pcall(function()
        for _,sig in ipairs(signals) do
            local connsOk, conns = pcall(getconnections, sig)
            if connsOk and type(conns) == "table" then
                for _,c in ipairs(conns) do
                    local fn = c.Function
                    if type(fn) == "function" then
                        local ok1, ups = pcall(debug.getupvalues, fn)
                        if ok1 and type(ups) == "table" then
                            for _,v in ipairs(ups) do
                                if type(v) == "function" and _looksLikeCast(v) then
                                    return v
                                end
                            end
                        end
                        if _looksLikeCast(fn) then return fn end
                    end
                end
            end
        end
        return nil
    end)
    if ok and type(res) == "function" then
        S._castFn = res
        return res
    end
    S._castFn = nil
    return nil
end

local function equipRod()
    local char = lp.Character
    if not char then return false end
    for _,v in ipairs(char:GetChildren()) do
        if v:IsA("Tool") and string.find(v.Name, "Rod") then return true end
    end
    local bp = lp:FindFirstChildOfClass("Backpack")
    local rod = nil
    if bp then
        rod = bp:FindFirstChild("Areon Rod")
        if not rod then
            for _,v in ipairs(bp:GetChildren()) do
                if v:IsA("Tool") and string.find(v.Name, "Rod") then rod = v break end
            end
        end
    end
    if not rod then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:EquipTool(rod) end)
        task.wait(0.3)
        return true
    end
    return false
end

local function isCastStarted()
    local char = lp.Character
    if not char then return false end
    if char:GetAttribute("FishingBusy") or char:GetAttribute("FishingLocked") then return true end
    local hm = getHoldMinigame()
    if hm and hm.Enabled then return true end
    return false
end

local function verifyCast(timeoutSec)
    local step = IS_MOBILE and 0.1 or 0.08
    local t = os.clock() + (timeoutSec or 0.8)
    while os.clock() < t do
        if isCastStarted() then return true end
        task.wait(step)
    end
    return isCastStarted()
end

local function tryFireMobileSignals()
    if type(firesignal) ~= "function" then return false end
    local function fireTouchWorld()
        local ok = false
        pcall(function()
            if UIS.TouchTapInWorld then
                firesignal(UIS.TouchTapInWorld, Vector2.new(400, 300), false)
                ok = true
            end
        end)
        if not ok then
            pcall(function()
                if UIS.TouchTap then
                    firesignal(UIS.TouchTap, { { Position = Vector2.new(400, 300) } }, false)
                    ok = true
                end
            end)
        end
        return ok
    end
    local function fireInputBeganMouse()
        local ok = pcall(function()
            firesignal(UIS.InputBegan, { UserInputType = Enum.UserInputType.MouseButton1, UserInputState = Enum.UserInputState.Begin, Position = Vector3.new(0,0,0), Delta = Vector3.new(0,0,0), KeyCode = Enum.KeyCode.Unknown }, false)
        end)
        if ok then
            task.wait(0.03)
            pcall(function() firesignal(UIS.InputEnded, { UserInputType = Enum.UserInputType.MouseButton1, UserInputState = Enum.UserInputState.End, Position = Vector3.new(0,0,0), Delta = Vector3.new(0,0,0), KeyCode = Enum.KeyCode.Unknown }, false) end)
        end
        return ok
    end
    local function fireFishButton()
        local pg = lp:FindFirstChild("PlayerGui")
        local ui = pg and pg:FindFirstChild("FishingKitUI")
        local mobile = ui and ui:FindFirstChild("Mobile")
        local root = mobile and (mobile:FindFirstChild("FishButton") or mobile)
        if not root then return false end
        local targets = { root }
        for _,d in ipairs(root:GetDescendants()) do table.insert(targets, d) end
        local any = false
        for _,t in ipairs(targets) do
            pcall(function() if t.Activated then firesignal(t.Activated) any = true end end)
            pcall(function() if t.InputBegan then firesignal(t.InputBegan, { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin, Position = Vector3.new(0,0,0), Delta = Vector3.new(0,0,0), KeyCode = Enum.KeyCode.Unknown }, false) any = true end end)
            pcall(function() if t.MouseButton1Down then firesignal(t.MouseButton1Down) any = true end end)
        end
        return any
    end
    local function fireToolActivated()
        local char = lp.Character
        if not char then return false end
        local tool
        for _,v in ipairs(char:GetChildren()) do if v:IsA("Tool") and string.find(v.Name,"Rod") then tool=v break end end
        if not tool then return false end
        local ok = false
        pcall(function() if tool.Activated then firesignal(tool.Activated) ok = true end end)
        return ok
    end
    local did = false
    if fireTouchWorld() then did = true end
    if not isCastStarted() then if fireInputBeganMouse() then did = true end end
    if not isCastStarted() then if fireFishButton() then did = true end end
    if not isCastStarted() then if fireToolActivated() then did = true end end
    if not did then return false end
    return verifyCast(IS_MOBILE and 1.0 or 0.9)
end

local function triggerCast()
    local cast = findCastFunction(false)
    if not cast then cast = findCastFunction(true) end
    if type(cast) == "function" then
        local ok = pcall(cast)
        if ok then
            if verifyCast(IS_MOBILE and 0.8 or 0.7) then return true, "cast-internal" end
        else
            S._castFn = nil
        end
    end
    local okV = pcall(function()
        local cam = workspace.CurrentCamera
        local vs = cam and cam.ViewportSize or Vector2.new(800, 600)
        local x, y = math.floor(vs.X * 0.5), math.floor(vs.Y * 0.5)
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    if okV and verifyCast(IS_MOBILE and 0.8 or 0.7) then return true, "vim-click" end
    if tryFireMobileSignals() then return true, "firesignal" end
    if not IS_MOBILE then
        local okM = pcall(function() mouse1click() end)
        if okM and verifyCast(0.9) then return true, "mouse1click" end
    end
    return false, "Cast tidak terverifikasi/gagal. Pastikan rod equipped & area bisa mancing. (Android: coba V2 manual sekali jika tetap gagal)"
end

local function steerMinigame(rf)
    local hm = getHoldMinigame()
    if not hm or not hm.Enabled then return end
    if not rf or type(rf.Minigame2) ~= "function" then return end
    local frame = hm:FindFirstChild("Frame")
    if not frame then return end
    local playerCtrl = frame:FindFirstChild("PlayerController")
    local fishCtrl = frame:FindFirstChild("FishController")
    if not playerCtrl or not fishCtrl then return end
    local fishX = fishCtrl.Position.X.Scale
    local barX = playerCtrl.Position.X.Scale
    local dir = -1
    if fishX > barX + 0.008 then dir = 1
    elseif fishX < barX - 0.008 then dir = -1
    else dir = (barX < 0.5) and 1 or -1 end
    pcall(function() debug.setupvalue(rf.Minigame2, 10, dir) end)
end

local function isFishingLockedOrBusy()
    local char = lp.Character
    if not char then return true, "nochar" end
    local hm = getHoldMinigame()
    if hm and hm.Enabled then return true, "minigame" end
    if char:GetAttribute("FishingBusy") or char:GetAttribute("FishingLocked") then return true, "busy" end
    return false, "idle"
end

local function applyToggleKey(win, v)
    local keyName = v
    if typeof(v) == "EnumItem" then keyName = v.Name end
    if type(v) ~= "string" then keyName = tostring(v) end
    if not keyName or keyName == "" then keyName = "G" end
    S.uiToggleKey = keyName
    pcall(function() win:SetToggleKey(Enum.KeyCode[keyName]) end)
end

-- ===== Halloween Pumpkin ESP (Labu A-I in Workspace.LabuAktif) =====
local function getEspParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui end
    local cg = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or nil
    if cg then return cg end
    return lp:FindFirstChildOfClass("PlayerGui")
end

local function clearPumpkinESP()
    if S._esp and S._esp.conns then
        for _,c in ipairs(S._esp.conns) do pcall(function() c:Disconnect() end) end
    end
    S._esp.conns = {}
    if S._esp and S._esp.objects then
        for _,o in pairs(S._esp.objects) do
            pcall(function() if o.highlight then o.highlight:Destroy() end end)
            pcall(function() if o.billboard then o.billboard:Destroy() end end)
        end
    end
    S._esp.objects = {}
    if S._esp and S._esp.folder then pcall(function() S._esp.folder:Destroy() end) end
    S._esp.folder = nil
end

local function addPumpkinESP(part)
    if not part or not part.Parent then return end
    if not (part:IsA("BasePart") or part:IsA("MeshPart")) then return end
    local name = part.Name or "Labu"
    if S._esp.objects[part] then return end
    local parentGui = getEspParent()
    if not parentGui then return end
    if not S._esp.folder or not S._esp.folder.Parent then
        local f = Instance.new("Folder")
        f.Name = "CloudsHub_LabuESP"
        pcall(function() f.Parent = parentGui end)
        S._esp.folder = f
    end
    local hl = Instance.new("Highlight")
    hl.Name = "LabuHighlight"
    hl.Adornee = part
    hl.FillColor = Color3.fromRGB(255, 140, 0)
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency = 0.5
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    pcall(function() hl.Parent = S._esp.folder end)

    local bb = Instance.new("BillboardGui")
    bb.Name = "LabuBillboard"
    bb.Adornee = part
    bb.Size = UDim2.new(0, 140, 0, 40)
    bb.StudsOffset = Vector3.new(0, 3.5, 0)
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    pcall(function() bb.Parent = S._esp.folder end)

    local tl = Instance.new("TextLabel")
    tl.Name = "Label"
    tl.BackgroundTransparency = 1
    tl.Size = UDim2.new(1, 0, 1, 0)
    tl.Text = "🎃 " .. name
    tl.TextColor3 = Color3.fromRGB(255, 200, 60)
    tl.TextStrokeTransparency = 0.2
    tl.TextStrokeColor3 = Color3.new(0,0,0)
    tl.TextScaled = true
    tl.Font = Enum.Font.GothamBold
    tl.Parent = bb

    S._esp.objects[part] = { highlight = hl, billboard = bb }
end

local function removePumpkinESP(part)
    local o = S._esp and S._esp.objects and S._esp.objects[part]
    if not o then return end
    pcall(function() if o.highlight then o.highlight:Destroy() end end)
    pcall(function() if o.billboard then o.billboard:Destroy() end end)
    S._esp.objects[part] = nil
end

local function refreshPumpkinESP()
    local folder = workspace:FindFirstChild("LabuAktif")
    if not folder then return end
    for _,ch in ipairs(folder:GetChildren()) do
        if ch:IsA("BasePart") then addPumpkinESP(ch) end
    end
    -- remove ESP for parts no longer in LabuAktif
    for part,_ in pairs(S._esp.objects) do
        if not part or not part.Parent or part.Parent ~= folder then
            removePumpkinESP(part)
        end
    end
end

local function setPumpkinESP(enabled)
    S._esp.enabled = enabled and true or false
    clearPumpkinESP()
    S._esp.enabled = enabled and true or false
    if not S._esp.enabled then return end
    local folder = workspace:FindFirstChild("LabuAktif")
    if folder then
        refreshPumpkinESP()
        local c1 = folder.ChildAdded:Connect(function(ch)
            if not S._esp.enabled then return end
            task.wait(0.05)
            if ch and ch.Parent == folder and ch:IsA("BasePart") then addPumpkinESP(ch) end
        end)
        local c2 = folder.ChildRemoved:Connect(function(ch)
            removePumpkinESP(ch)
        end)
        table.insert(S._esp.conns, c1); table.insert(S._esp.conns, c2)
        table.insert(S._conn, c1); table.insert(S._conn, c2)
    end
    -- also watch for LabuAktif folder appearing later
    local c3 = workspace.ChildAdded:Connect(function(ch)
        if ch.Name == "LabuAktif" and ch:IsA("Folder") and S._esp.enabled then
            task.wait(0.1)
            refreshPumpkinESP()
            local a = ch.ChildAdded:Connect(function(x)
                if not S._esp.enabled then return end
                task.wait(0.05)
                if x and x.Parent == ch and x:IsA("BasePart") then addPumpkinESP(x) end
            end)
            local b = ch.ChildRemoved:Connect(function(x) removePumpkinESP(x) end)
            table.insert(S._esp.conns, a); table.insert(S._esp.conns, b)
            table.insert(S._conn, a); table.insert(S._conn, b)
        end
    end)
    table.insert(S._esp.conns, c3); table.insert(S._conn, c3)
end
-- ===== end Pumpkin ESP =====

local okUI, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not okUI or not WindUI then
    warn("[CloudsHub] Gagal memuat WindUI: " .. tostring(WindUI))
    return
end
S.WindUI = WindUI

local Window = WindUI:CreateWindow({
    Title = "Clouds Hub Solova V1.4.0",
    Icon = "fish",
    Author = "[🎃] Solova Hangout || Private use only!",
    Folder = "SolovaAutoFish",
    Size = UDim2.fromOffset(460, 420),
    MinSize = Vector2.new(320, 320),
    MaxSize = Vector2.new(760, 560),
    Transparent = true,
    Theme = "Dark",
    Resizable = true,
    HideSearchBar = true,
    AutoScale = true,
    OpenButton = {
        Title = "Clouds Hub",
        Icon = "fish",
        CornerRadius = UDim.new(0, 16),
        StrokeThickness = 2,
        Enabled = true,
        Draggable = true,
        OnlyMobile = false,
        Scale = 0.9,
    },
})
S._ui = Window

pcall(function() applyToggleKey(Window, S.uiToggleKey or "G") end)

local TabMemancing = Window:Tab({ Title = "Memancing", Icon = "anchor" })
local TabHalloween = Window:Tab({ Title = "Halloween", Icon = "ghost" })
local TabPengaturan = Window:Tab({ Title = "Pengaturan", Icon = "settings" })

local statusPara
local function setStatus(t) pcall(function() if statusPara then statusPara:SetDesc(t) end end) end

TabMemancing:Dropdown({
    Title = "Pilih Mode",
    Desc = "V1 / V2",
    Values = { "V1 - Auto Cast", "V2 - Manual Cast" },
    Value = (S.mode == "V2") and "V2 - Manual Cast" or "V1 - Auto Cast",
    Callback = function(opt)
        local v = opt
        if type(opt) == "table" then v = opt.Title or opt.Value or opt[1] or tostring(opt) end
        if type(v) ~= "string" then v = tostring(v) end
        if string.find(v, "V2") then S.mode = "V2" else S.mode = "V1" end
        if S.running then setStatus("Mode: " .. S.mode .. " | Berjalan") else setStatus("Mode: " .. S.mode .. " | Mati") end
    end
})

statusPara = TabMemancing:Paragraph({ Title = "Status", Desc = "Mode: " .. tostring(S.mode) .. " | Mati" })

TabMemancing:Toggle({
    Title = "Auto Fishing",
    Desc = "V1: auto cast + auto minigame. V2: hanya auto minigame. Cast diverifikasi (anti loop).",
    Value = false,
    Callback = function(state)
        S.running = state
        if state then
            S._castFn = nil
            S._nextCastAt = os.clock() + 1
            S._sawMinigame = false
            S._wasBusy = false
            setStatus("Mode: " .. S.mode .. " | Berjalan")
            S._thread = task.spawn(function()
                while S.running do
                    local okLoop, errLoop = pcall(function()
                        local rf = getRodFunctions()
                        if not lp.Character then
                            setStatus("Mode: " .. S.mode .. " | Menunggu karakter...")
                            S._nextCastAt = os.clock() + 2
                            S._sawMinigame = false
                            task.wait(1)
                            return
                        end
                        local busy = isFishingLockedOrBusy()
                        local hm = getHoldMinigame()
                        if hm and hm.Enabled then
                            S._sawMinigame = true
                            S._wasBusy = true
                            steerMinigame(rf)
                            setStatus("Mode: " .. S.mode .. " | Minigame: auto-steer")
                            task.wait(0.03)
                            return
                        end
                        if busy then
                            S._wasBusy = true
                            if S._sawMinigame then setStatus("Mode: " .. S.mode .. " | Minigame selesai, menunggu proses...") else setStatus("Mode: " .. S.mode .. " | Sibuk/menunggu...") end
                            task.wait(0.2)
                            return
                        end
                        if S._wasBusy then
                            S._wasBusy = false
                            if S.mode == "V1" then
                                local d
                                if S._sawMinigame then d = tonumber(S.postMinigameDelay) or 1.8 S._sawMinigame = false S._nextCastAt = math.max(S._nextCastAt or 0, os.clock() + d)
                                    setStatus(string.format("Mode: V1 | Selesai minigame, tunggu %.1fs...", math.max(0, S._nextCastAt - os.clock())))
                                else d = tonumber(S.castDelay) or 5.0 S._sawMinigame = false S._nextCastAt = math.max(S._nextCastAt or 0, os.clock() + d)
                                    setStatus(string.format("Mode: V1 | Selesai siklus, tunggu %.1fs...", math.max(0, S._nextCastAt - os.clock())))
                                end
                            else S._sawMinigame = false setStatus("Mode: V2 | Idle (assist minigame aktif)") end
                            task.wait(0.15)
                            return
                        end
                        if S.mode == "V2" then setStatus("Mode: V2 | Idle (assist minigame aktif)") task.wait(0.25) return end
                        if os.clock() < (S._nextCastAt or 0) then setStatus(string.format("Mode: V1 | Tunggu %.1fs...", math.max(0, S._nextCastAt - os.clock()))) task.wait(0.15) return end
                        if not equipRod() then setStatus("Mode: V1 | Rod tidak ditemukan") S._nextCastAt = os.clock() + 2 task.wait(1) return end
                        local okC, how = triggerCast()
                        S._sawMinigame = false
                        if okC then
                            S._wasBusy = true
                            S._nextCastAt = os.clock() + (tonumber(S.castDelay) or 5.0)
                            setStatus(string.format("Mode: V1 | Cast OK (%s)", tostring(how)))
                            task.wait(0.3)
                        else
                            S._wasBusy = false
                            S._nextCastAt = os.clock() + 1.5
                            setStatus("Mode: V1 | " .. tostring(how))
                            task.wait(0.6)
                        end
                    end)
                    if not okLoop then warn("[CloudsHub] loop error", errLoop) task.wait(1) end
                    task.wait(0.05)
                end
                setStatus("Mode: " .. tostring(S.mode) .. " | Mati")
            end)
        else setStatus("Mode: " .. tostring(S.mode) .. " | Mati") end
    end
})

TabMemancing:Button({
    Title = "Auto Equip Rod",
    Desc = "Equip Areon Rod / rod apa pun sekarang",
    Callback = function()
        if equipRod() then setStatus("Rod berhasil di-equip") else setStatus("Rod tidak ditemukan") end
    end
})

TabMemancing:Paragraph({ Title = "Pengaturan Jeda", Desc = "Skala 0.1 detik" })

TabMemancing:Slider({
    Title = "Jeda Setelah Minigame Selesai (detik)",
    Desc = "V1: setelah minigame & idle, tunggu ini sebelum cast lagi.",
    Step = 0.1,
    Value = { Min = 0.5, Max = 10, Default = tonumber(S.postMinigameDelay) or 1.8 },
    Callback = function(v) local n = tonumber(v) if n then S.postMinigameDelay = math.clamp(n, 0.5, 10) end end
})

TabMemancing:Slider({
    Title = "Jeda Antar Cast / Retry (detik)",
    Desc = "V1: jeda umum/retry & fallback safety.",
    Step = 0.1,
    Value = { Min = 2, Max = 15, Default = tonumber(S.castDelay) or 5.0 },
    Callback = function(v) local n = tonumber(v) if n then S.castDelay = math.clamp(n, 2, 15) end end
})

TabHalloween:Paragraph({
    Title = "ESP Labu (Pumpkin)",
    Desc = "Menandai Labu A–I yang sedang aktif/spawn di map (Workspace.LabuAktif). Tanpa teleport/autorun."
})

TabHalloween:Toggle({
    Title = "Pumpkin ESP",
    Desc = "Highlight + label 🎃 untuk semua labu aktif. Update otomatis saat spawn/despawn.",
    Value = false,
    Callback = function(state)
        setPumpkinESP(state)
    end
})

TabPengaturan:Paragraph({ Title = "UI", Desc = "Di HP, gunakan tombol 'Clouds Hub' (draggable) untuk buka/tutup UI. Keybind keyboard berguna di PC." })

TabPengaturan:Keybind({
    Title = "Keybind Tampilkan/Sembunyikan UI",
    Desc = "Buka/tutup window (default: G, PC)",
    Value = S.uiToggleKey or "G",
    Callback = function(v)
        applyToggleKey(Window, v)
    end
})

local hb = RunService.Heartbeat:Connect(function()
    if not S.running then return end
    local now = os.clock()
    if S._lastHbSteer and (now - S._lastHbSteer) < 0.04 then return end
    S._lastHbSteer = now
    local hm = getHoldMinigame()
    if hm and hm.Enabled then steerMinigame(getRodFunctions()) end
end)
table.insert(S._conn, hb)

print("[CloudsHub] loaded v1.4.0 (fishing + Halloween Pumpkin ESP)")
