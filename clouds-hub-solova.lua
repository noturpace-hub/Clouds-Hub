-- Clouds Hub Solova v2.3.4 (AFK terpadu: auto-equip+cast+steer, cast input stabil tanpa loop)
-- Prioritas: Auto Cast + Auto Steer berjalan bersama untuk AFK. Mekanik berdasarkan FishingKit game (controller/RodFunctions, minigame input arah).

getgenv().__CLOUDS_HUB = getgenv().__CLOUDS_HUB or {}
local S = getgenv().__CLOUDS_HUB

-- ===== cleanup =====
pcall(function() if S._conns then for _, c in ipairs(S._conns) do pcall(function() c:Disconnect() end) end end end)
pcall(function() if S._autorunThread then task.cancel(S._autorunThread) end end)
pcall(function() if S._ui and S._ui.Destroy then S._ui:Destroy() end end)
pcall(function() local cg = game:GetService("CoreGui"); local old = cg:FindFirstChild("CloudsHub_ToggleGui"); if old then old:Destroy() end end)
pcall(function()
    if S._esp then
        if S._esp.conns then for _, c in ipairs(S._esp.conns) do pcall(function() c:Disconnect() end) end end
        if S._esp.objects then for _, o in pairs(S._esp.objects) do pcall(function() if o.hl then o.hl:Destroy() end end); pcall(function() if o.bb then o.bb:Destroy() end end) end end
        if S._esp.folder then pcall(function() S._esp.folder:Destroy() end) end
        if S._esp.gui then pcall(function() S._esp.gui:Destroy() end) end
    end
end)
pcall(function() if S._spectate and S._spectate.conns then for _, c in ipairs(S._spectate.conns) do pcall(function() c:Disconnect() end) end end end)
pcall(function() if S._antiAfkConn then S._antiAfkConn:Disconnect() end end)
pcall(function() if S._autoRun then S._autoRun.enabled = false end end)
pcall(function() if S._steerInputRelease then S._steerInputRelease() end end)

-- ===== services =====
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")

local lp = Players.LocalPlayer

-- ===== state =====
S._conns = S._conns or {}
-- running = Auto Fish AFK (cast + steer terpadu)
S.running = S.running == true
S.assistSteerOnly = S.assistSteerOnly == true -- manual cast, auto steer tetap jalan saat minigame
S.autoEquip = (S.autoEquip ~= false)
S.postDelay = math.clamp(tonumber(S.postDelay) or 2.0, 0.5, 10.0)
S.retryDelay = math.clamp(tonumber(S.retryDelay) or 8.0, 2.0, 15.0)
S.uiToggleKey = S.uiToggleKey or "F"
S.autoSteer = (S.autoSteer ~= false)

S._fish = S._fish or {}
local F = S._fish
F.phase = F.phase or "idle"
F.nextAt = F.nextAt or 0
F.lastCastAt = F.lastCastAt or 0
F.pendingCastAt = F.pendingCastAt or 0
F.lastCastMethod = "-"
F.sawMinigame = false
F.busySeen = false
F.steerActive = false
F.steerHolding = false
F.lastSteerChange = 0

S._esp = S._esp or { enabled = false, objects = {}, conns = {}, folder = nil, gui = nil }
S._autoRun = S._autoRun or { enabled = false }
S._spectate = S._spectate or { index = 0, target = nil, conns = {} }
S._antiAfk = S._antiAfk or { enabled = false }

local function now()
    return os.clock()
end

local function safeDisconnect(x)
    if not x then return end
    pcall(function()
        if x.Disconnect then
            x:Disconnect()
        end
    end)
end

local function getChar()
    return lp.Character
end

local function getHum()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end

local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end

local function getPlayerGui()
    return lp:FindFirstChild("PlayerGui")
end

local function isTextFocused()
    local ok, r = pcall(function()
        return UIS:GetFocusedTextBox() ~= nil
    end)
    return ok and r or false
end

local function diag(msg)
    pcall(function()
        print("[CloudsHub][diag] " .. tostring(msg))
    end)
end

-- ===== minigame helpers =====
local function getFishingKitUI() local pg=getPlayerGui(); return pg and pg:FindFirstChild("FishingKitUI") or nil end

local function getHoldMinigame()
    local ui = getFishingKitUI()
    if not ui then return nil end
    local hm = ui:FindFirstChild("HoldMinigame")
    if hm then return hm end
    for _, c in ipairs(ui:GetChildren()) do
        local n = string.lower(c.Name)
        if string.find(n, "hold") or string.find(n, "minigame") then return c end
    end
    return nil
end

local function findControllerByRole(root, role)
    if not root then return nil end
    local wantFish = (role == "fish")
    local best = nil
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiObject") then
            local ln = string.lower(d.Name)
            local isFish = string.find(ln, "fish") ~= nil
            local isPlayer = (string.find(ln, "player") ~= nil) or (string.find(ln, "bar") ~= nil) or (string.find(ln, "catch") ~= nil) or (string.find(ln, "pointer") ~= nil) or (string.find(ln, "handle") ~= nil)
            local isCtrl = string.find(ln, "controller") ~= nil
            if wantFish then
                if isFish and (isCtrl or d.Name == "FishController" or d.Name == "Fish") then return d end
                if not best and isFish then best = d end
            else
                if (isPlayer and isCtrl) or d.Name == "PlayerController" then return d end
                if not best and isPlayer and not isFish then best = d end
            end
        end
    end
    return best
end

local function getMinigameControllers(hm)
    hm = hm or getHoldMinigame()
    if not hm then return nil, nil, nil end
    local frame = hm:FindFirstChild("Frame") or hm:FindFirstChildWhichIsA("Frame") or hm
    local pc = frame:FindFirstChild("PlayerController")
    local fc = frame:FindFirstChild("FishController")
    if not pc then pc = findControllerByRole(frame, "player") end
    if not fc then fc = findControllerByRole(frame, "fish") end
    if (not pc or not fc) and frame ~= hm then
        if not pc then pc = findControllerByRole(hm, "player") end
        if not fc then fc = findControllerByRole(hm, "fish") end
    end
    return frame, pc, fc
end

local function isMinigameActive(hm)
    hm = hm or getHoldMinigame()
    if not hm then return false end
    local ok, en = pcall(function() return hm.Enabled end)
    if ok then
        return en == true
    end
    -- fallback hanya jika Enabled tidak bisa dibaca
    local _, pc, fc = getMinigameControllers(hm)
    if pc and fc then
        local frame = hm:FindFirstChild("Frame") or hm:FindFirstChildWhichIsA("Frame") or hm
        local okV, vis = pcall(function() return frame.Visible end)
        if okV and vis == true then return true end
    end
    return false
end

-- ===== rod & state =====
local function getEquippedFishingRod()
    local char = getChar(); if not char then return nil end
    local ok, tagged = pcall(function() return CollectionService:GetTagged("FishingKitRod") end)
    if ok and type(tagged) == "table" then
        for _, t in ipairs(tagged) do if t and t:IsA("Tool") and t.Parent == char then return t end end
    end
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") then local n = string.lower(t.Name); if string.find(n, "rod") or string.find(n, "pancing") then return t end end
    end
    return nil
end

local function equipFishingRod()
    local char = getChar(); local hum = getHum(); local bp = lp:FindFirstChild("Backpack")
    if not char or not hum or not bp then return false end
    if getEquippedFishingRod() then return true end
    local ok, tagged = pcall(function() return CollectionService:GetTagged("FishingKitRod") end)
    if ok and type(tagged) == "table" then
        for _, t in ipairs(tagged) do
            if t and t:IsA("Tool") and t.Parent == bp then
                local e = pcall(function() hum:EquipTool(t) end); if e then task.wait(0.05); return true end
            end
        end
    end
    for _, t in ipairs(bp:GetChildren()) do
        if t:IsA("Tool") then
            local n = string.lower(t.Name)
            if string.find(n, "rod") or string.find(n, "pancing") then
                local e = pcall(function() hum:EquipTool(t) end); if e then task.wait(0.05); return true end
            end
        end
    end
    return false
end

local function isFishingBusy()
    local char = getChar(); if not char then return false end
    local ok, v = pcall(function() return char:GetAttribute("FishingBusy") end)
    return ok and v == true
end
local function isFishingLocked()
    local char = getChar(); if not char then return false end
    local ok, v = pcall(function() return char:GetAttribute("FishingLocked") end)
    return ok and v == true
end

-- ===== Auto Steer (input hold/release sesuai RodFunctions) =====
local function setSteerHold(shouldHold)
    shouldHold = shouldHold and true or false
    if F.steerHolding == shouldHold then return end
    local t = now()
    if (t - (F.lastSteerChange or 0)) < 0.03 then return end
    F.lastSteerChange = t
    F.steerHolding = shouldHold
    pcall(function() VIM:SendMouseButtonEvent(0, 0, 0, shouldHold, game, 0) end)
    pcall(function() VIM:SendKeyEvent(shouldHold, Enum.KeyCode.Space, false, game) end)
end

local function releaseSteerInput()
    if F.steerHolding then
        F.steerHolding = false
        F.lastSteerChange = now()
    end
    pcall(function() VIM:SendMouseButtonEvent(0, 0, 0, false, game, 0) end)
    pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
end
S._steerInputRelease = releaseSteerInput

local function steerTick()
    F.steerActive = false
    if not S.autoSteer or isTextFocused() then
        releaseSteerInput(); return
    end

    local hm = getHoldMinigame()
    local _, pc, fc = getMinigameControllers(hm)
    local active = isMinigameActive(hm)
    if not active and pc and fc then
        local okV1, v1 = pcall(function() return pc.Visible end)
        local okV2, v2 = pcall(function() return fc.Visible end)
        if (okV1 and v1) and (okV2 and v2) then active = true end
    end
    if not active or not (pc and fc and pc:IsA("GuiObject") and fc:IsA("GuiObject")) then
        releaseSteerInput(); return
    end

    F.steerActive = true
    local ok = pcall(function()
        local fishX = fc.Position.X.Scale
        local barX = pc.Position.X.Scale
        local diff = fishX - barX
        local dead = 0.012
        if diff > dead then
            setSteerHold(true)
        elseif diff < -dead then
            setSteerHold(false)
        else
            if diff >= 0 then setSteerHold(true) else setSteerHold(false) end
        end
    end)
    if not ok then releaseSteerInput() end
end

-- ===== Auto Cast (cross-platform, sesuai alur controller/game) =====
local function clickGuiButton(btn)
    if not (btn and btn:IsA("GuiButton")) then return false end
    local did = false
    if type(firesignal) == "function" then
        did = pcall(function() if btn.Activated then firesignal(btn.Activated) end end) or did
        if not did then did = pcall(function() if btn.MouseButton1Click then firesignal(btn.MouseButton1Click) end end) or did end
        if not did then did = pcall(function() if btn.MouseButton1Down then firesignal(btn.MouseButton1Down) end end) or did end
        if not did then did = pcall(function() if btn.MouseButton1Up then firesignal(btn.MouseButton1Up) end end) or did end
    end
    if not did then
        local okP, absPos, absSize = pcall(function() return btn.AbsolutePosition, btn.AbsoluteSize end)
        if okP and absPos and absSize then
            local insetY = 36
            pcall(function() insetY = GuiService:GetGuiInset().Y end)
            local x = absPos.X + absSize.X * 0.5
            local y = absPos.Y + absSize.Y * 0.5 + insetY
            did = pcall(function()
                VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
                task.wait(0.03)
                VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end) or did
        end
    end
    return did
end

local function tryCast()
    if isTextFocused() then return false, "focused" end
    local hum = getHum()
    if not hum or hum.Health <= 0 then return false, "nochar" end
    if isMinigameActive() or isFishingBusy() or isFishingLocked() then return false, "busy" end

    if S.autoEquip then
        if not getEquippedFishingRod() then
            pcall(equipFishingRod)
            task.wait(0.2)
        end
    end
    local rod = getEquippedFishingRod()
    if not rod then
        F.lastCastMethod = "no-rod"
        return false, "no-rod"
    end

    local okAny = false
    local method = "fail"

    local methods = {}

    -- Pastikan tool aktif/konteks siap (tanpa memanggil RodFunctions.Cast secara langsung agar tidak konflik)
    pcall(function() if rod.Activate then rod:Activate() end end)
    task.wait(0.05)

    local ui = getFishingKitUI()
    local mobileBtn = ui and ui:FindFirstChild("Mobile")

    -- 1) Klik tombol Mobile (ImageButton) - terbukti memicu alur cast saat cycle berjalan
    if mobileBtn and mobileBtn:IsA("GuiButton") then
        if clickGuiButton(mobileBtn) then table.insert(methods, "mobile-btn") end
    end

    -- 2) Input klik/tap area world (PC/iOS/Android) - satu usaha per siklus, hindari spam
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or Vector2.new(1000, 700)
    local x, y = vp.X * 0.5, vp.Y * 0.45
    if UIS.TouchEnabled then
        if type(VIM.SendTouchEvent) == "function" then
            local okTap = pcall(function()
                VIM:SendTouchEvent(0, 1, 0, x, y)
                task.wait(0.03)
                VIM:SendTouchEvent(0, 2, 0, x, y)
            end)
            if okTap then table.insert(methods, "touch") end
        end
    else
        local okClick = pcall(function()
            VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.04)
            VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if okClick then table.insert(methods, "vim-click") end
    end

    -- 3) Fallback mouse1click bila diperlukan
    if #methods == 0 and type(mouse1click) == "function" then
        local okM = pcall(function() mouse1click() end)
        if okM then table.insert(methods, "mouse1click") end
    end

    if #methods > 0 then
        local method = table.concat(methods, "+")
        F.lastCastMethod = method
        return true, method
    end

    F.lastCastMethod = "fail"
    return false, "fail"
end

-- ===== Fishing tick (AFK: cast + steer terpadu) =====
local function fishingTick()
    local t = now()
    local inMinigame = isMinigameActive()
    local busy = isFishingBusy() or isFishingLocked()

    if inMinigame then
        F.phase = "minigame"; F.sawMinigame = true; F.busySeen = true; F.pendingCastAt = 0
        return
    end
    if F.sawMinigame or F.busySeen then
        if not inMinigame and not busy then
            F.sawMinigame = false; F.busySeen = false
            F.phase = "cooldown"
            F.nextAt = math.max(F.nextAt, t + S.postDelay)
            F.pendingCastAt = 0
            diag("cycle complete, cooldown " .. tostring(S.postDelay) .. "s")
            return
        end
    end
    if busy then
        F.phase = "waiting"; F.busySeen = true; F.pendingCastAt = 0
        return
    end

    -- Auto-cast hanya jika mode AFK penuh aktif
    if not S.running then
        F.phase = "idle"; F.pendingCastAt = 0; return
    end
    if isTextFocused() then return end
    local hum = getHum()
    if not hum or hum.Health <= 0 then return end

    if F.pendingCastAt > 0 then
        if (t - F.pendingCastAt) < S.retryDelay then
            F.phase = "waiting"; return
        else
            diag("cast timeout, retry"); F.pendingCastAt = 0
        end
    end
    if t < F.nextAt then F.phase = "cooldown"; return end
    if (t - F.lastCastAt) < 1.2 then return end

    F.phase = "casting"
    local ok, method = tryCast()
    F.lastCastAt = t
    if ok then
        diag("cast ok: " .. tostring(method))
        F.pendingCastAt = t
        F.phase = "waiting"
    else
        diag("cast fail: " .. tostring(method))
        F.pendingCastAt = 0
        F.phase = "idle"
        F.nextAt = t + 2.0
    end
end

-- ===== ESP, AutoRun, Spectate, Anti-AFK =====
local function getLabuFolder() return workspace:FindFirstChild("LabuAktif") end
local function ensureEspGui()
    local pg = getPlayerGui(); if not pg then return nil end
    local gui = pg:FindFirstChild("CloudsHub_LabuESP")
    if not gui then
        gui = Instance.new("ScreenGui"); gui.Name = "CloudsHub_LabuESP"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 5; gui.Parent = pg
    end
    return gui
end
local function clearEspObjects()
    if not S._esp or not S._esp.objects then return end
    for k, o in pairs(S._esp.objects) do
        pcall(function() if o.hl then o.hl:Destroy() end end)
        pcall(function() if o.bb then o.bb:Destroy() end end)
        S._esp.objects[k] = nil
    end
end
local function addEspFor(part)
    if not (part and part:IsA("BasePart") and part.Parent) then return end
    if S._esp.objects[part] then return end
    local hl = Instance.new("Highlight")
    hl.Name = "CH_LabuHL"; hl.Adornee = part; hl.FillTransparency = 0.6; hl.OutlineTransparency = 0; hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = S._esp.folder or workspace
    local bb = Instance.new("BillboardGui")
    bb.Name = "CH_LabuBB"; bb.Adornee = part; bb.Size = UDim2.new(0, 120, 0, 36); bb.StudsOffset = Vector3.new(0, 3, 0); bb.AlwaysOnTop = true
    bb.Parent = ensureEspGui()
    local tl = Instance.new("TextLabel")
    tl.BackgroundTransparency = 1; tl.Size = UDim2.new(1, 0, 1, 0); tl.TextScaled = true; tl.Font = Enum.Font.GothamBold; tl.TextStrokeTransparency = 0.2
    tl.Text = "🎃 " .. tostring(part.Name); tl.TextColor3 = Color3.fromRGB(255, 170, 60); tl.Parent = bb
    S._esp.objects[part] = { hl = hl, bb = bb }
end
local function refreshEsp()
    if not S._esp.enabled then return end
    local folder = getLabuFolder()
    for part, obj in pairs(S._esp.objects) do
        if not (part and part.Parent and folder and part:IsDescendantOf(folder) and string.find(part.Name, "Labu_")) then
            pcall(function() if obj.hl then obj.hl:Destroy() end end)
            pcall(function() if obj.bb then obj.bb:Destroy() end end)
            S._esp.objects[part] = nil
        end
    end
    if not folder then return end
    for _, ch in ipairs(folder:GetChildren()) do if ch:IsA("BasePart") and string.find(ch.Name, "Labu_") then addEspFor(ch) end end
end
local function setPumpkinEsp(on)
    S._esp.enabled = on and true or false
    if S._esp.conns then for _, c in ipairs(S._esp.conns) do safeDisconnect(c) end; S._esp.conns = {} end
    if not on then clearEspObjects(); return end
    if not S._esp.folder or not S._esp.folder.Parent then local f = Instance.new("Folder"); f.Name = "CloudsHub_LabuESP_HL"; f.Parent = workspace; S._esp.folder = f end
    ensureEspGui(); refreshEsp()
    local folder = getLabuFolder()
    if folder then
        table.insert(S._esp.conns, folder.ChildAdded:Connect(function(ch) task.wait(0.05); if S._esp.enabled and ch:IsA("BasePart") and string.find(ch.Name, "Labu_") then addEspFor(ch) end end))
        table.insert(S._esp.conns, folder.ChildRemoved:Connect(function() task.defer(refreshEsp) end))
    end
    task.spawn(function() while S._esp.enabled do pcall(refreshEsp); task.wait(2.0) end end)
end

-- AutoRun
local function releaseRunKeys() if UIS.KeyboardEnabled and not UIS.TouchEnabled then pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end) end end
local function ensureRun(hum)
    if not hum then return end
    pcall(function() if hum.WalkSpeed < 20 then hum.WalkSpeed = 20 end end)
    if UIS.KeyboardEnabled and not UIS.TouchEnabled then pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game) end) end
end
local function getActivePumpkins()
    local folder = getLabuFolder(); local out = {}
    if not folder then return out end
    for _, ch in ipairs(folder:GetChildren()) do if ch:IsA("BasePart") and string.find(ch.Name, "Labu_") then table.insert(out, ch) end end
    return out
end
local function getNearestPumpkin()
    local hrp = getHRP(); if not hrp then return nil, math.huge end
    local best, bestD = nil, math.huge
    for _, p in ipairs(getActivePumpkins()) do if p and p.Parent then local d = (p.Position - hrp.Position).Magnitude; if d < bestD then best, bestD = p, d end end end
    return best, bestD
end
local function moveToWithTimeout(hum, pos, timeoutSec)
    local done, reached = false, false; timeoutSec = timeoutSec or 2.5
    local conn = hum.MoveToFinished:Connect(function(r) reached = r; done = true end)
    hum:MoveTo(pos); local t0 = now()
    while not done and (now() - t0) < timeoutSec do if not S._autoRun.enabled then break end; task.wait(0.1) end
    if conn then pcall(function() conn:Disconnect() end) end
    return reached, done
end
local function computeWaypoints(fromPos, toPos)
    local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 5 })
    local ok = pcall(function() path:ComputeAsync(fromPos, toPos) end)
    if ok and path.Status == Enum.PathStatus.Success then local wps = path:GetWaypoints(); if #wps > 0 then return wps end end
    return { { Position = toPos, Action = Enum.PathWaypointAction.Walk } }
end
local function runToTarget(targetPart)
    local hum = getHum(); local hrp = getHRP()
    if not hum or not hrp or not targetPart or not targetPart.Parent then return false end
    ensureRun(hum)
    local wps = computeWaypoints(hrp.Position, targetPart.Position)
    local startIdx = (#wps > 1) and 2 or 1
    for i = startIdx, #wps do
        if not S._autoRun.enabled or not targetPart.Parent then return false end
        hum = getHum(); hrp = getHRP(); if not hum or not hrp then return false end
        ensureRun(hum)
        local wp = wps[i]
        if wp.Action == Enum.PathWaypointAction.Jump then pcall(function() hum.Jump = true end); task.wait(0.05) end
        local before = hrp.Position
        moveToWithTimeout(hum, wp.Position, 3.0); task.wait(0.05)
        hrp = getHRP(); if not hrp then return false end
        if (hrp.Position - targetPart.Position).Magnitude <= 4.5 then return true end
        if (hrp.Position - before).Magnitude < 0.8 then
            pcall(function() hum.Jump = true end); task.wait(0.15)
            local hrp2 = getHRP()
            if hrp2 and (hrp2.Position - before).Magnitude < 0.8 then
                pcall(function() hum:MoveTo(wp.Position + Vector3.new(math.random(-2,2)*0.2, 0, math.random(-2,2)*0.2)) end); task.wait(0.2)
            end
            return false
        end
    end
    return false
end
local function stopAutoRun()
    S._autoRun.enabled = false; releaseRunKeys()
    local hum = getHum(); local hrp = getHRP()
    if hum and hrp then pcall(function() hum:MoveTo(hrp.Position) end) end
end
local function startAutoRun()
    stopAutoRun(); S._autoRun.enabled = true
    S._autorunThread = task.spawn(function()
        while S._autoRun.enabled do
            local okLoop = pcall(function()
                local hum = getHum(); local hrp = getHRP()
                if not hum or not hrp then task.wait(0.4); return end
                ensureRun(hum)
                local target, dist = getNearestPumpkin()
                if not target then task.wait(0.6); return end
                if dist <= 4.5 then task.wait(0.25); return end
                runToTarget(target); task.wait(0.12)
            end)
            if not okLoop then task.wait(0.4) end
            task.wait(0.08)
        end
        releaseRunKeys()
    end)
end

-- Spectate
local function getPlayerList()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do if p ~= lp then table.insert(list, p) end end
    table.sort(list, function(a,b) return a.Name:lower() < b.Name:lower() end)
    return list
end
local function applySpectateCamera(target)
    local cam = workspace.CurrentCamera; if not cam then return end
    if target then local hum = target.Character and target.Character:FindFirstChildOfClass("Humanoid"); if hum then cam.CameraSubject = hum end
    else local myHum = getHum(); if myHum then cam.CameraSubject = myHum end end
end
local function setSpectateTarget(p)
    S._spectate.target = p; S._spectate.index = 0
    if p then local list = getPlayerList(); for i,v in ipairs(list) do if v == p then S._spectate.index = i break end end end
    applySpectateCamera(p)
end
local function spectateStep(delta)
    local list = getPlayerList(); if #list == 0 then setSpectateTarget(nil); return nil end
    local idx = (S._spectate.index or 0) + delta
    if idx < 1 then idx = #list elseif idx > #list then idx = 1 end
    S._spectate.index = idx; local target = list[idx]; S._spectate.target = target; applySpectateCamera(target); return target
end
table.insert(S._spectate.conns, Players.PlayerRemoving:Connect(function(p) if S._spectate.target == p then setSpectateTarget(nil) end end))
table.insert(S._spectate.conns, RunService.RenderStepped:Connect(function() if S._spectate.target then pcall(applySpectateCamera, S._spectate.target) end end))
for _, c in ipairs(S._spectate.conns) do table.insert(S._conns, c) end

-- Anti-AFK
local function setAntiAfk(on)
    S._antiAfk.enabled = on and true or false
    if S._antiAfkConn then safeDisconnect(S._antiAfkConn); S._antiAfkConn = nil end
    if not on then return end
    local vu = game:GetService("VirtualUser")
    S._antiAfkConn = lp.Idled:Connect(function()
        pcall(function()
            vu:Button2Down(Vector2.new(0,0), workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new())
            task.wait(0.05)
            vu:Button2Up(Vector2.new(0,0), workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new())
        end)
    end)
    table.insert(S._conns, S._antiAfkConn)
end

-- ===== UI =====
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
pcall(function() WindUI:AddTheme({ Name = "Clouds", Accent = Color3.fromHex("#6aa9ff"), Dialog = Color3.fromHex("#dbeafe"), Outline = Color3.fromHex("#93c5fd"), Text = Color3.fromHex("#eaf4ff"), Placeholder = Color3.fromHex("#9cc7ff"), Background = Color3.fromHex("#0f233d"), Button = Color3.fromHex("#3b82f6"), Icon = Color3.fromHex("#bfdbfe") }) end)
pcall(function() WindUI:SetTheme("Clouds") end)
pcall(function() WindUI.TransparencyValue = 0.08 end)

local Window = WindUI:CreateWindow({
    Title = "Clouds Hub V2.3.4",
    Icon = "cloud",
    Author = "Clouds Hub",
    Folder = "CloudsHub",
    Size = UDim2.fromOffset(430, 380),
    Transparent = true,
    Theme = "Clouds",
    SideBarWidth = 170,
    HasOutline = true,
    User = { Enabled = true, Anonymous = false, Callback = function() end },
})
S._ui = Window

local function applyToggleKey(win, keyStr)
    local name = tostring(keyStr or "F"):upper(); S.uiToggleKey = name
    local keyCode = Enum.KeyCode[name] or Enum.KeyCode.F
    pcall(function() if win and win.SetToggleKey then win:SetToggleKey(keyCode) end end)
    return keyCode
end
pcall(function() Window:Tag({ Title = "v2.3.4 AFK", Icon = "cloud" }) end)
pcall(function()
    local cg = game:GetService("CoreGui")
    local gui = Instance.new("ScreenGui"); gui.Name = "CloudsHub_ToggleGui"; gui.ResetOnSpawn = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.Parent = cg
    local btn = Instance.new("TextButton"); btn.Name = "ToggleCloudsHub"; btn.Size = UDim2.fromOffset(118, 36); btn.Position = UDim2.new(0, 14, 0.5, -18)
    btn.BackgroundColor3 = Color3.fromRGB(59, 130, 246); btn.BackgroundTransparency = 0.12; btn.Text = "☁ Clouds Hub"; btn.TextColor3 = Color3.fromRGB(255,255,255)
    btn.Font = Enum.Font.GothamBold; btn.TextSize = 13; btn.Active = true; btn.Draggable = true; btn.Parent = gui
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    local st = Instance.new("UIStroke", btn); st.Thickness = 1.2; st.Color = Color3.fromRGB(191,219,254); st.Transparency = 0.25
    btn.MouseButton1Click:Connect(function() pcall(function() if Window and Window.Toggle then Window:Toggle() end end) end)
end)

local TabMemancing = Window:Tab({ Title = "Memancing", Icon = "fish" })
local TabHalloween = Window:Tab({ Title = "Halloween", Icon = "ghost" })
local TabPlayer = Window:Tab({ Title = "Player", Icon = "users" })
local TabPengaturan = Window:Tab({ Title = "Pengaturan", Icon = "settings" })

local statusPara = TabMemancing:Paragraph({ Title = "Status", Desc = "Siap" })
local castPara = TabMemancing:Paragraph({ Title = "Metode Cast Terakhir", Desc = "-" })

local function updateStatusUI()
    local modeText = S.running and "AFK (Auto Cast + Auto Steer)" or (S.assistSteerOnly and "Assist (Manual Cast + Auto Steer)" or "Idle")
    local s = "Mode: " .. modeText .. " | Fase: " .. tostring(F.phase or "-")
    if isTextFocused() then s = s .. " | Pause (chat/fokus)" end
    if F.steerActive then s = s .. " | Steering" end
    pcall(function() statusPara:SetDesc(s) end)
    pcall(function() castPara:SetDesc(tostring(F.lastCastMethod or "-")) end)
end

TabMemancing:Paragraph({ Title = "Prioritas Utama", Desc = "Auto Cast + Auto Steer terpadu untuk AFK (PC/iOS/Android). Auto steer memakai input arah minigame sesuai mekanik game." })

TabMemancing:Toggle({
    Title = "Auto Fish AFK (Cast + Steer)",
    Desc = "Utama: otomatis cast (lempar) dan otomatis kendalikan minigame saat aktif. Bisa ditinggal AFK.",
    Value = S.running,
    Callback = function(state)
        S.running = state and true or false
        if S.running then
            S.assistSteerOnly = false
            F.nextAt = now() + 0.4
            F.sawMinigame = false; F.busySeen = false; F.pendingCastAt = 0
        else
            F.pendingCastAt = 0
            releaseSteerInput()
        end
        updateStatusUI()
    end
})

TabMemancing:Toggle({
    Title = "Assist Steer (Manual Cast)",
    Desc = "Opsional: jika AFK dimatikan, auto steer tetap membantu saat minigame tampil (kamu cast manual).",
    Value = S.assistSteerOnly,
    Callback = function(state)
        S.assistSteerOnly = state and true or false
        if S.assistSteerOnly then S.running = false end
        updateStatusUI()
    end
})

TabMemancing:Toggle({
    Title = "Auto Steer Minigame",
    Desc = "Mengendalikan arah bar mengikuti ikan via input hold/lepas (kompatibel dengan minigame game).",
    Value = S.autoSteer,
    Callback = function(state)
        S.autoSteer = state and true or false
        if not S.autoSteer then releaseSteerInput() end
        updateStatusUI()
    end
})

TabMemancing:Toggle({ Title = "Auto Equip Rod", Desc = "Otomatis equip rod FishingKit jika belum terpegang.", Value = S.autoEquip, Callback = function(state) S.autoEquip = state and true or false end })

TabMemancing:Slider({ Title = "Delay Setelah Ikan Dapat (Post-Minigame)", Desc = "Jeda sebelum cast berikutnya setelah siklus selesai (0.1s).", Step = 0.1, Value = { Min = 0.5, Max = 10.0, Default = S.postDelay }, Callback = function(v)
    local n = tonumber(type(v) == "table" and (v.Current or v.Value or v.Default) or v)
    if n then S.postDelay = math.clamp(n, 0.5, 10.0) end
end })

TabMemancing:Slider({ Title = "Timeout Retry Cast", Desc = "Jika setelah cast tidak masuk busy/minigame, tunggu lalu retry (0.1s). Default 8.0 detik.", Step = 0.1, Value = { Min = 2.0, Max = 15.0, Default = S.retryDelay }, Callback = function(v)
    local n = tonumber(type(v) == "table" and (v.Current or v.Value or v.Default) or v)
    if n then S.retryDelay = math.clamp(n, 2.0, 15.0) end
end })

TabMemancing:Paragraph({ Title = "Catatan", Desc = "Cast: input klik/tap/tool + tombol Mobile (cross-platform). Steer: input arah minigame. Aksi dipause saat chat/fokus teks." })

-- Halloween
TabHalloween:Paragraph({ Title = "ESP Labu (Pumpkin)", Desc = "Highlight + label labu aktif di Workspace.LabuAktif." })
TabHalloween:Toggle({ Title = "Pumpkin ESP", Desc = "Tandai semua labu aktif. Update otomatis.", Value = S._esp.enabled == true, Callback = function(state) setPumpkinEsp(state) end })
TabHalloween:Toggle({ Title = "Auto Run ke Labu", Desc = "Jalan otomatis ke labu terdekat (pathfinding, anti-stuck, auto-jump).", Value = S._autoRun.enabled == true, Callback = function(state) if state then startAutoRun() else stopAutoRun() end end })

-- Player
S._spectateStatus = TabPlayer:Paragraph({ Title = "Spectate", Desc = "Target: -" })
TabPlayer:Button({ Title = "Next Player", Desc = "Spectate pemain berikutnya", Callback = function()
    local p = spectateStep(1); pcall(function() S._spectateStatus:SetDesc(p and ("Target: " .. (p.DisplayName or p.Name) .. " (@" .. p.Name .. ")") or "Target: -") end)
end })
TabPlayer:Button({ Title = "Previous Player", Desc = "Spectate pemain sebelumnya", Callback = function()
    local p = spectateStep(-1); pcall(function() S._spectateStatus:SetDesc(p and ("Target: " .. (p.DisplayName or p.Name) .. " (@" .. p.Name .. ")") or "Target: -") end)
end })
TabPlayer:Button({ Title = "Stop Spectate", Desc = "Kembali ke kamera sendiri", Callback = function()
    setSpectateTarget(nil); pcall(function() S._spectateStatus:SetDesc("Target: -") end)
end })

-- Pengaturan
TabPengaturan:Toggle({ Title = "Anti-AFK", Desc = "Mencegah idle/kick otomatis saat AFK.", Value = S._antiAfk.enabled == true, Callback = function(state) setAntiAfk(state) end })
TabPengaturan:Keybind({ Title = "Keybind Tampilkan/Sembunyikan UI", Desc = "Buka/tutup window (default: F, PC). Di mobile gunakan tombol Clouds Hub.", Value = S.uiToggleKey or "F", Callback = function(v) applyToggleKey(Window, v) end })
applyToggleKey(Window, S.uiToggleKey)

-- ===== loops =====
local lastFish, lastUI = 0, 0
table.insert(S._conns, RunService.RenderStepped:Connect(function()
    pcall(steerTick)
end))
table.insert(S._conns, RunService.Heartbeat:Connect(function()
    local t = now()
    if (t - lastFish) >= 0.1 then lastFish = t; pcall(fishingTick) end
    if (t - lastUI) >= 0.5 then lastUI = t; pcall(updateStatusUI) end
end))

-- pastikan input steer dilepas saat reload kondisi aman
releaseSteerInput()
updateStatusUI()
print("[CloudsHub] loaded v2.3.4 (AFK terpadu: auto-equip+cast+steer, cast stabil cross-platform)")
diag("loaded v2.3.4 running=" .. tostring(S.running) .. " assist=" .. tostring(S.assistSteerOnly) .. " steer=" .. tostring(S.autoSteer) .. " retry=" .. tostring(S.retryDelay))
