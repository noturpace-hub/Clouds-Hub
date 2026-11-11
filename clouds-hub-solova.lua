--[[============================================================================
    Clouds Hub V3.0.0 — [🎃] Solova Hangout (placeId 117700301942271)

    REWRITE PENUH (bukan kelanjutan v1/v2). Metode mancing baru yang
    crash-safe:
      - TANPA debug hook sama sekali (tidak ada getupvalue/setupvalue,
        tidak ada scan getconnections, tidak ada patched function).
      - Cast  : satu klik terkontrol (tombol Mobile game bila tampil,
                else klik layar) via VirtualInputManager + fallback
                mouse1click executor.
      - Steer : minigame "Klik & Tahan" dikendalikan dari sisi INPUT:
                baca posisi ikan vs zona dari GUI HoldMinigame tiap
                Heartbeat (throttled), tahan/lepas (Mouse / Space) sesuai
                posisi ikan. Koneksi Heartbeat tunggal, dibuka-tutup
                bersih, semua pcall.
      - Cross-platform: PC + iOS/Android (VIM atau fallback executor).
    Fitur: Memancing (Full Auto / Assist, auto equip, delay 0.1-step),
    Halloween (Pumpkin ESP LabuAktif + Auto Run ke Labu pathfinding),
    Player (Spectate dropdown/next/prev/stop, follow respawn),
    Pengaturan (Anti-AFK, keybind UI, tombol pill draggable).
============================================================================]]

print("[CloudsHub] memuat V3.0.1 ...")

-- ===== 0. Cleanup instance lama ============================================
local genv = getgenv and getgenv() or _G
if genv.__CLOUDS_HUB_V3 and type(genv.__CLOUDS_HUB_V3.Unload) == "function" then
    pcall(function() genv.__CLOUDS_HUB_V3.Unload() end)
end
pcall(function()
    local cg = (gethui and gethui()) or game:GetService("CoreGui")
    local old = cg:FindFirstChild("CloudsHub_ToggleGui")
    if old then old:Destroy() end
end)
pcall(function()
    local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local old = pg and pg:FindFirstChild("CloudsHub_V3_LabuESP")
    if old then old:Destroy() end
end)

-- ===== 1. Services & state =================================================
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")

local lp = Players.LocalPlayer

local S = {
    version = "3.0.1",
    -- fishing
    running = false,
    mode = "Full",            -- "Full" (auto cast + steer) | "Assist" (steer saja)
    steerEnabled = true,
    steerInput = "Mouse",     -- "Mouse" | "Space"
    autoEquip = true,
    castDelay = 9.0,          -- jeda antar cast / retry (detik)
    postMinigameDelay = 1.8,  -- jeda setelah minigame selesai (detik)
    biteTimeout = 45,         -- maks menunggu gigitan sebelum cast ulang
    -- lain
    antiAfk = false,
    uiToggleKey = "F",
    showPill = true,
    -- internal
    _conn = {},
    _alive = true,
    _wasBusy = false,
    _sawMinigame = false,
    _nextCastAt = 0,
    _lastCastClick = 0,
    _mgStart = nil,
    _steerLast = 0,
    _steerFails = 0,
    _steerWarned = false,
    _biteWaitUntil = 0,
    _castConfirmed = false,
}
local Window = nil -- diisi saat UI jadi; dibaca Unload

local function addConn(c)
    if c then table.insert(S._conn, c) end
    return c
end

local function setStatus(t)
    pcall(function()
        if S._statusPara and S._statusPara.SetDesc then S._statusPara:SetDesc(t) end
    end)
end

-- ===== 2. Deteksi dasar ====================================================
local function getHoldMinigame()
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    local ui = pg and pg:FindFirstChild("FishingKitUI")
    return ui and ui:FindFirstChild("HoldMinigame") or nil
end

local function isTextInputFocused()
    local ok, focused = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and focused ~= nil
end

local function isBusy()
    local ch = lp.Character
    if not ch then return false end
    local a, l
    pcall(function() a = ch:GetAttribute("FishingBusy") end)
    pcall(function() l = ch:GetAttribute("FishingLocked") end)
    return a == true or l == true
end

local function isRod(tool)
    if not tool or not tool:IsA("Tool") then return false end
    local ok, tagged = pcall(function()
        return CollectionService:HasTag(tool, "FishingKitRod")
    end)
    if ok and tagged then return true end
    local n = string.lower(tostring(tool.Name))
    return string.find(n, "rod", 1, true) ~= nil
end

-- ===== 3. Modul input (VIM + fallback) =====================================
local vimOK, vim = pcall(function() return game:GetService("VirtualInputManager") end)
if not vimOK then vim = nil end

local function viewportPoint()
    local cam = workspace.CurrentCamera
    local ok, v = pcall(function() return cam and cam.ViewportSize or Vector2.new(960, 540) end)
    return v.X * 0.5, v.Y * 0.55
end

local function vimSpace(down)
    if not vim then error("no VIM") end
    vim:SendKeyEvent(down, Enum.KeyCode.Space, false, game)
end

local function vimMouse(down, x, y)
    if not vim then error("no VIM") end
    local px, py = x or viewportPoint()
    vim:SendMouseButtonEvent(px, py, 0, down, game, 0)
end

local function executorMouse(down)
    if down then
        if type(mouse1press) == "function" then mouse1press() else error("no mouse fallback") end
    else
        if type(mouse1release) == "function" then mouse1release() else error("no mouse fallback") end
    end
end

-- Tahan/lepas input steer. Satu-satunya gerbang input untuk minigame.
local function inputHold(down)
    local st = S
    local now = os.clock()
    if st._inputHeld == down then return true end
    if st._inputLastChange and (now - st._inputLastChange) < 0.08 then
        return st._inputHeld or false -- anti-spam: minimal 80ms antar transisi
    end
    local ok = false
    if S.steerInput == "Space" then
        ok = pcall(vimSpace, down)
        if not ok then ok = pcall(executorMouse, down) end
    else
        ok = pcall(vimMouse, down)
        if not ok then ok = pcall(executorMouse, down) end
    end
    if ok then
        st._inputHeld = down
        st._inputLastChange = now
    end
    return ok
end

local function inputRelease()
    if S._inputHeld then
        local ok = inputHold(false)
        if not ok then S._inputHeld = false end
    end
end

-- Klik cast: prioritaskan tombol Mobile game bila tampil (posisinya pasti
-- benar), else klik area layar tengah. Selalu tekan-lepas singkat.
local function castClick()
    local now = os.clock()
    if now - (S._lastCastClick or 0) < 2 then return false end
    S._lastCastClick = now
    local ok = pcall(function()
        local targetX, targetY
        local pg = lp:FindFirstChildOfClass("PlayerGui")
        local ui = pg and pg:FindFirstChild("FishingKitUI")
        local mob = ui and ui:FindFirstChild("Mobile")
        local fb = mob and mob:FindFirstChild("FishButton")
        if mob and mob.Visible and fb and fb.Visible then
            local p, sz = fb.AbsolutePosition, fb.AbsoluteSize
            targetX = p.X + sz.X * 0.5
            targetY = p.Y + sz.Y * 0.5
        else
            targetX, targetY = viewportPoint()
        end
        vimMouse(true, targetX, targetY)
        task.wait(0.04)
        vimMouse(false, targetX, targetY)
    end)
    if ok and vim then return true end
    if type(mouse1click) == "function" then
        pcall(mouse1click)
        return true
    end
    return false
end

-- ===== 4. Rod equip ========================================================
local function ensureRodEquipped()
    local ch = lp.Character
    local cur = ch and ch:FindFirstChildOfClass("Tool")
    if isRod(cur) then return true end
    local bp = lp:FindFirstChildOfClass("Backpack")
    if not bp then return false end
    local best
    for _, t in ipairs(bp:GetChildren()) do
        if isRod(t) then
            if string.find(string.lower(tostring(t.Name)), "areon", 1, true) then
                best = t
                break
            end
            best = best or t
        end
    end
    if not best then return false end
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    pcall(function() hum:EquipTool(best) end)
    local deadline = os.clock() + 2
    while os.clock() < deadline do
        local c2 = lp.Character
        local t2 = c2 and c2:FindFirstChildOfClass("Tool")
        if isRod(t2) then return true end
        task.wait(0.15)
    end
    return false
end

-- ===== 5. Auto-steer minigame (Heartbeat tunggal) ==========================
-- Semantik minigame (hasil rekaman live):
--   tahan  -> zona bergerak ke kanan
--   lepas  -> zona auto-drift ke kiri
--   ikan   = FishController (marker), zona = PlayerController (lebar 38% bar)
--   progres mulai 0.40 -> 1.00 = sukses; minigame selesai = Enabled -> false
local function readSteer(hm)
    local bar = hm:FindFirstChild("Frame")
    local zone = bar and bar:FindFirstChild("PlayerController")
    local fish = bar and bar:FindFirstChild("FishController")
    if not (bar and zone and fish) then return nil, "struktur GUI berubah" end
    local bX, bW = bar.AbsolutePosition.X, bar.AbsoluteSize.X
    if not bW or bW <= 0 then return nil, "bar size 0" end
    local zX, zW = zone.AbsolutePosition.X, zone.AbsoluteSize.X
    local fX, fW = fish.AbsolutePosition.X, fish.AbsoluteSize.X
    local zL = (zX - bX) / bW
    local zR = (zX + zW - bX) / bW
    local fN = (fX + fW * 0.5 - bX) / bW
    local center = (zL + zR) * 0.5
    local db = math.max(0.05, (zR - zL) * 0.18) -- deadband ~ histeresis
    if fN > center + db then
        return true  -- ikan di kanan: tahan (zona ke kanan)
    elseif fN < center - db then
        return false -- ikan di kiri: lepas (zona ke kiri)
    end
    return nil -- di dalam deadband: pertahankan kondisi sekarang
end

local steerHB = addConn(RunService.Heartbeat:Connect(function()
    if not S._alive then return end
    local now = os.clock()
    if (now - S._steerLast) < 0.04 then return end
    S._steerLast = now

    local hm = getHoldMinigame()
    local active = hm and hm.Enabled
    if not active then
        inputRelease()
        S._mgStart = nil
        S._steerFails = 0
        S._steerWarned = false
        return
    end

    if isTextInputFocused() then
        inputRelease()
        return
    end

    if not S._mgStart then S._mgStart = now end
    if (now - S._mgStart) > 90 then
        -- failsafe: minigame nyangkut terlalu lama -> lepas, jangan kunci input
        inputRelease()
        return
    end

    if not S.steerEnabled then
        inputRelease()
        return
    end

    local okR, want, err = pcall(function()
        local w, e = readSteer(hm)
        return w, e
    end)
    if not okR then
        S._steerFails = S._steerFails + 1
        if S._steerFails >= 30 and not S._steerWarned then
            S._steerWarned = true
            S.steerEnabled = false
            inputRelease()
            warn("[CloudsHub] auto-steer dimatikan (error GUI berulang)")
        end
        return
    end
    if want == nil then return end -- deadband: pertahankan
    S._steerFails = 0
    inputHold(want)
end))

-- ===== 6. Loop utama mancing (state machine, tanpa hook) ===================
local function fishingStep()
    local ch = lp.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not (ch and hum and ch:FindFirstChild("HumanoidRootPart")) then
        setStatus("Menunggu karakter...")
        return 1
    end

    local hm = getHoldMinigame()
    if hm and hm.Enabled then
        -- steering ditangani Heartbeat; loop cuma menunggu & menampilkan status
        if not S._wasBusy then S._wasBusy = true end
        S._sawMinigame = true
        setStatus(S.steerEnabled and "Minigame: auto-steer aktif" or "Minigame berjalan (steer OFF)")
        return 0.1
    end

    if isTextInputFocused() then
        inputRelease()
        setStatus("Pause (chat/fokus teks)")
        return 0.25
    end

    if isBusy() then
        S._wasBusy = true
        setStatus(S._sawMinigame and "Proses tangkapan..." or "Menunggu ikan menyentuh senar...")
        return 0.2
    end

    if S._wasBusy then
        -- baru saja selesai fase cast/bite/minigame
        S._wasBusy = false
        if S._sawMinigame then
            -- minigame pernah jalan -> siklus benar-benar selesai
            S._castConfirmed = false
            if S.mode == "Full" then
                local d = tonumber(S.postMinigameDelay) or 1.8
                S._sawMinigame = false
                S._nextCastAt = math.max(S._nextCastAt or 0, os.clock() + d)
                setStatus(string.format("Siklus selesai, tunggu %.1fs", math.max(0, S._nextCastAt - os.clock())))
            else
                S._sawMinigame = false
                setStatus("Assist: idle (cast manual)")
            end
            return 0.15
        end
        -- busy hilang TANPA minigame: senar kemungkinan masih keluar
        -- (busy=false saat tunggu bite) -> biarkan fase bite di bawah yang mengatur
    end

    if S.mode ~= "Full" then
        setStatus("Assist: tunggu minigame (cast manual)")
        return 0.3
    end

    -- fase menunggu gigitan: JANGAN cast ulang walau busy=false (anti double-cast)
    if S._castConfirmed then
        if os.clock() < (S._biteWaitUntil or 0) then
            setStatus("Menunggu ikan menyentuh senar...")
            return 0.2
        end
        S._castConfirmed = false
        S._nextCastAt = os.clock() + (tonumber(S.castDelay) or 9.0)
        setStatus("Tidak ada gigitan, cast ulang nanti")
        return 0.3
    end

    local remain = (S._nextCastAt or 0) - os.clock()
    if remain > 0 then
        setStatus(string.format("Tunggu %.1fs", remain))
        return 0.2
    end

    if S.autoEquip and not ensureRodEquipped() then
        setStatus("Rod tidak ditemukan (taruh rod di backpack)")
        S._nextCastAt = os.clock() + 2
        return 1
    end

    setStatus("Cast...")
    if not castClick() then
        S._nextCastAt = os.clock() + 1.5
        return 0.6
    end

    -- verifikasi cast: harus muncul busy/minigame dalam 3s
    local deadline = os.clock() + 3
    while os.clock() < deadline and S.running and S._alive do
        task.wait(0.2)
        local hm2 = getHoldMinigame()
        if (hm2 and hm2.Enabled) or isBusy() then
            S._wasBusy = true
            S._castConfirmed = true
            S._biteWaitUntil = os.clock() + (tonumber(S.biteTimeout) or 45)
            S._nextCastAt = os.clock() + (tonumber(S.castDelay) or 9.0)
            setStatus("Cast OK — menunggu ikan...")
            return 0.2
        end
    end
    S._nextCastAt = os.clock() + (tonumber(S.castDelay) or 9.0)
    setStatus("Cast tidak terkonfirmasi, retry nanti")
    return 0.4
end

task.spawn(function()
    while S._alive do
        local waitT = 0.3
        if S.running then
            local ok, ret = pcall(fishingStep)
            if not ok then
                warn("[CloudsHub] loop error:", ret)
                waitT = 1
            else
                waitT = tonumber(ret) or 0.3
            end
        end
        task.wait(waitT)
    end
end)

-- ===== 7. Anti-AFK =========================================================
local afkConn = nil
local function setAntiAfk(on)
    S.antiAfk = on and true or false
    if afkConn then pcall(function() afkConn:Disconnect() end) afkConn = nil end
    if not on then return end
    afkConn = addConn(lp.Idled:Connect(function()
        if not S.antiAfk then return end
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end))
end

-- ===== 8. Pumpkin ESP (Workspace.LabuAktif) ================================
local esp = { on = false, conns = {}, thread = nil }

local function labuContainer()
    local ws = workspace
    return ws:FindFirstChild("LabuAktif") or ws:WaitForChild("LabuAktif", 5)
end

local function clearEsp(inst)
    if not inst then return end
    pcall(function()
        local h = inst:FindFirstChild("CloudsHub_Highlight"); if h then h:Destroy() end
        local b = inst:FindFirstChild("CloudsHub_Billboard"); if b then b:Destroy() end
    end)
end

local function decorateLabu(part)
    if not part or not part:IsA("BasePart") then return end
    clearEsp(part)
    pcall(function()
        local h = Instance.new("Highlight")
        h.Name = "CloudsHub_Highlight"
        h.FillColor = Color3.fromHex("#38bdf8")
        h.OutlineColor = Color3.fromHex("#f0f9ff")
        h.FillTransparency = 0.6
        h.OutlineTransparency = 0
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Adornee = part
        h.Parent = part

        local bb = Instance.new("BillboardGui")
        bb.Name = "CloudsHub_Billboard"
        bb.Adornee = part
        bb.Size = UDim2.new(0, 150, 0, 34)
        bb.StudsOffset = Vector3.new(0, 3.5, 0)
        bb.AlwaysOnTop = true
        bb.MaxDistance = 600
        bb.Parent = part

        local tl = Instance.new("TextLabel")
        tl.Name = "Label"
        tl.Size = UDim2.new(1, 0, 1, 0)
        tl.BackgroundTransparency = 1
        tl.Font = Enum.Font.GothamBold
        tl.TextSize = 14
        tl.TextColor3 = Color3.fromHex("#f0f9ff")
        tl.TextStrokeTransparency = 0.35
        tl.Text = "🎃 Labu"
        tl.Parent = bb
    end)
end

local function espUpdateLabels()
    local ch = lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local c = labuContainer()
    if not (c and hrp) then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            local bb = p:FindFirstChild("CloudsHub_Billboard")
            local tl = bb and bb:FindFirstChild("Label")
            if tl then
                local d = (p.Position - hrp.Position).Magnitude
                tl.Text = string.format("🎃 Labu (%.0fm)", d)
            end
        end
    end
end

local function setPumpkinESP(on)
    esp.on = on and true or false
    for _, c in ipairs(esp.conns) do pcall(function() c:Disconnect() end) end
    esp.conns = {}
    if esp.thread then
        esp._stop = true
        esp.thread = nil
    end
    local c = labuContainer()
    if not c then
        warn("[CloudsHub] Workspace.LabuAktif tidak ditemukan")
        return
    end
    if not on then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then clearEsp(p) end
        end
        return
    end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and string.find(p.Name, "Labu", 1, true) then
            decorateLabu(p)
        end
    end
    table.insert(esp.conns, addConn(c.ChildAdded:Connect(function(ch2)
        task.wait(0.2)
        if esp.on and ch2:IsA("BasePart") then decorateLabu(ch2) end
    end)))
    table.insert(esp.conns, addConn(c.ChildRemoved:Connect(function(ch2)
        clearEsp(ch2)
    end)))
    task.spawn(function()
        while esp.on and S._alive do
            pcall(espUpdateLabels)
            task.wait(0.5)
        end
    end)
end

-- ===== 9. Auto Run ke Labu (pathfinding + anti-stuck) ======================
local autoRun = { on = false, thread = nil, walkSpeed = nil }

local function nearestLabu()
    local c = workspace:FindFirstChild("LabuAktif")
    if not c then return nil end
    local ch = lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local best, bestD
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and string.find(p.Name, "Labu", 1, true) then
            local d = (p.Position - hrp.Position).Magnitude
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    return best, bestD
end

local function moveToHuman(hum, pos, timeout)
    local done = false
    local conn = hum.MoveToFinished:Connect(function() done = true end)
    hum:MoveTo(pos)
    local t0 = os.clock()
    while not done and (os.clock() - t0) < (timeout or 2.5) do
        task.wait(0.05)
        if not autoRun.on then break end
    end
    pcall(function() conn:Disconnect() end)
    return done
end

local function autoRunLoop()
    while autoRun.on and S._alive do
        local ch = lp.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if not (hum and hrp) then task.wait(1) continue end
        local target = nearestLabu()
        if not target then
            task.wait(5)
            continue
        end
        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = false,
            WaypointSpacing = 4,
        })
        local okPath, errPath = pcall(function()
            path:ComputeAsync(target.Position + Vector3.new(0, 3, 0))
        end)
        if not okPath or path.Status ~= Enum.PathStatus.Success then
            -- fallback: lari langsung
            if not moveToHuman(hum, target.Position + Vector3.new(0, 3, 0), 4) then task.wait(1) end
            continue
        end
        local wps = path:GetWaypoints()
        for i, wp in ipairs(wps) do
            if not autoRun.on or not S._alive then break end
            if wp.Action == Enum.PathWaypointAction.Jump then
                pcall(function() hum.Jump = true end)
            end
            local ok = moveToHuman(hum, wp.Position, 2.5)
            if not ok then
                pcall(function() hum.Jump = true end)
                if not moveToHuman(hum, wp.Position, 2) then break end -- repath
            end
        end
        if autoRun.on then task.wait(1.5) end -- jeda di labu sebelum cari lagi
    end
end

local function startAutoRun()
    if autoRun.on then return end
    autoRun.on = true
    local ch = lp.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            autoRun.walkSpeed = hum.WalkSpeed
            hum.WalkSpeed = 22 -- best-effort
        end)
    end
    autoRun.thread = task.spawn(autoRunLoop)
end

local function stopAutoRun()
    autoRun.on = false
    local ch = lp.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if hum then
        pcall(function()
            if autoRun.walkSpeed then hum.WalkSpeed = autoRun.walkSpeed end
        end)
    end
    if hrp then pcall(function() hum:MoveTo(hrp.Position) end) end
end

-- ===== 10. Spectate ========================================================
local spectate = { target = nil, index = 0 }

local function othersList()
    local t = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then table.insert(t, p) end
    end
    return t
end

local function bindCameraTo(player)
    local ch = player and player.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local cam = workspace.CurrentCamera
    if cam and hum then
        pcall(function() cam.CameraSubject = hum end)
        return true
    end
    return false
end

local function setSpectate(player)
    if spectate.charConn then
        pcall(function() spectate.charConn:Disconnect() end)
        spectate.charConn = nil
    end
    spectate.target = player
    if not player then
        bindCameraTo(lp)
        spectate.index = 0
        return true
    end
    if not bindCameraTo(player) then
        task.spawn(function()
            local ok, conn = pcall(function()
                return player.CharacterAdded:Wait()
            end)
            if ok and spectate.target == player then
                task.wait(0.5)
                pcall(function() bindCameraTo(player) end)
            end
        end)
    end
    spectate.charConn = addConn(player.CharacterAdded:Connect(function()
        if spectate.target ~= player then return end
        task.wait(0.5)
        pcall(function() bindCameraTo(player) end)
    end))
    return true
end

local function spectateStep(dir)
    local list = othersList()
    if #list == 0 then return nil end
    spectate.index = ((spectate.index + dir - 1) % #list) + 1
    local p = list[spectate.index]
    setSpectate(p)
    return p
end

table.insert(S._conn, Players.PlayerRemoving:Connect(function(p)
    if spectate.target == p then
        setSpectate(nil)
        pcall(function()
            if S._specStatus then S._specStatus:SetDesc("Target: - (player keluar)") end
        end)
    end
end))

-- ===== 11. UI (WindUI, tema biru langit) ===================================
local WindUIOK, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
end)
if not WindUIOK or type(WindUI) ~= "table" then
    warn("[CloudsHub] Gagal memuat WindUI:", tostring(WindUI))
    S._alive = false
    return
end

pcall(function()
    WindUI:AddTheme({
        Name = "CloudsSky",
        Accent = Color3.fromHex("#38bdf8"),
        Dialog = Color3.fromHex("#bae6fd"),
        Outline = Color3.fromHex("#7dd3fc"),
        Text = Color3.fromHex("#f0f9ff"),
        Placeholder = Color3.fromHex("#7ba7cc"),
        Background = Color3.fromHex("#0b1526"),
        Button = Color3.fromHex("#0ea5e9"),
        Icon = Color3.fromHex("#bae6fd"),
    })
    WindUI:SetTheme("CloudsSky")
    WindUI.TransparencyValue = 0.06
end)

Window = WindUI:CreateWindow({
    Title = "Clouds Hub V3.0.1",
    SubTitle = "Solova Hangout",
    Icon = "cloud",
    Author = "Clouds Hub",
    Folder = "CloudsHubV3",
    Size = UDim2.fromOffset(440, 390),
    Transparent = true,
    Theme = "CloudsSky",
    SideBarWidth = 170,
    HasOutline = true,
    Resizable = true,
    HideSearchBar = true,
    AutoScale = true,
    User = { Enabled = true, Anonymous = false, Callback = function() end },
    OpenButton = { Enabled = false },
})

local function applyToggleKey(win, v)
    local keyName = v
    if typeof(v) == "EnumItem" then keyName = v.Name end
    if type(v) ~= "string" then keyName = tostring(v) end
    if not keyName or keyName == "" then keyName = "F" end
    S.uiToggleKey = keyName
    pcall(function() win:SetToggleKey(Enum.KeyCode[keyName]) end)
end
pcall(function() applyToggleKey(Window, S.uiToggleKey) end)

local TabMemancing  = Window:Tab({ Title = "Memancing",  Icon = "anchor" })
local TabHalloween  = Window:Tab({ Title = "Halloween",  Icon = "ghost" })
local TabPlayer     = Window:Tab({ Title = "Player",     Icon = "users" })
local TabPengaturan = Window:Tab({ Title = "Pengaturan", Icon = "settings" })

S._statusPara = TabMemancing:Paragraph({
    Title = "Status",
    Desc = "Mode: Full | Mati",
})

TabMemancing:Dropdown({
    Title = "Mode Auto Fishing",
    Desc = "Full = cast + steer otomatis",
    Values = { "Full Auto", "Assist (Cast Manual)" },
    Value = "Full Auto",
    Callback = function(opt)
        local v = opt
        if type(opt) == "table" then v = opt.Title or opt.Value or opt[1] or tostring(opt) end
        v = tostring(v)
        S.mode = (string.find(v, "Assist") and "Assist") or "Full"
        setStatus("Mode: " .. S.mode .. " | " .. (S.running and "Berjalan" or "Mati"))
    end,
})

TabMemancing:Toggle({
    Title = "Auto Fishing",
    Desc = "Nyalakan siklus otomatis (cast → minigame → cooldown).",
    Value = false,
    Callback = function(state)
        S.running = state
        if state then
            S._wasBusy = false
            S._sawMinigame = false
            S._castConfirmed = false
            S._biteWaitUntil = 0
            S._nextCastAt = os.clock() + 1
            setStatus("Mode: " .. S.mode .. " | Berjalan")
            print("[CloudsHub] auto-fishing ON mode=" .. S.mode)
        else
            inputRelease()
            setStatus("Mode: " .. S.mode .. " | Mati")
            print("[CloudsHub] auto-fishing OFF")
        end
    end,
})

TabMemancing:Toggle({
    Title = "Auto Steer Minigame",
    Desc = "Tahan/lepas otomatis saat minigame (input-only, tanpa hook).",
    Value = S.steerEnabled,
    Callback = function(state)
        S.steerEnabled = state
        if not state then inputRelease() end
        print("[CloudsHub] steer " .. (state and "enabled" or "disabled"))
    end,
})

TabMemancing:Dropdown({
    Title = "Input Steer",
    Desc = "Mouse = klik-tahan; Space = tombol spasi",
    Values = { "Mouse", "Space" },
    Value = S.steerInput,
    Callback = function(opt)
        local v = opt
        if type(opt) == "table" then v = opt.Title or opt.Value or opt[1] or tostring(opt) end
        v = tostring(v)
        if string.find(v, "Space", 1, true) then S.steerInput = "Space" else S.steerInput = "Mouse" end
        inputRelease() -- ganti input saat sedang menahan = lepas dulu
    end,
})

TabMemancing:Toggle({
    Title = "Auto Equip Rod",
    Desc = "Equip rod otomatis sebelum cast (Areon Rod diprioritaskan).",
    Value = true,
    Callback = function(state) S.autoEquip = state end,
})

TabMemancing:Button({
    Title = "Auto Equip Rod Sekarang",
    Desc = "Equip rod langsung",
    Callback = function()
        local ok = ensureRodEquipped()
        setStatus(ok and "Rod ter-equip" or "Rod tidak ditemukan")
    end,
})

TabMemancing:Slider({
    Title = "Jeda Setelah Minigame (detik)",
    Desc = "Tunggu sebelum cast lagi setelah minigame selesai.",
    Step = 0.1,
    Value = { Min = 0.5, Max = 10, Default = tonumber(S.postMinigameDelay) },
    Callback = function(v)
        local n = tonumber(v)
        if n then S.postMinigameDelay = math.clamp(n, 0.5, 10) end
    end,
})

TabMemancing:Slider({
    Title = "Jeda Antar Cast / Retry (detik)",
    Desc = "Jeda umum antar siklus & retry cast gagal.",
    Step = 0.1,
    Value = { Min = 2, Max = 15, Default = tonumber(S.castDelay) },
    Callback = function(v)
        local n = tonumber(v)
        if n then S.castDelay = math.clamp(n, 2, 15) end
    end,
})

TabMemancing:Slider({
    Title = "Bite Timeout (detik)",
    Desc = "Maksimal menunggu gigitan sebelum cast ulang (anti double-cast).",
    Step = 1,
    Value = { Min = 10, Max = 120, Default = tonumber(S.biteTimeout) },
    Callback = function(v)
        local n = tonumber(v)
        if n then S.biteTimeout = math.clamp(n, 10, 120) end
    end,
})

-- Halloween ------------------------------------------------------------------
TabHalloween:Paragraph({
    Title = "Event Labu",
    Desc = "ESP labu aktif & lari otomatis ke labu terdekat (tanpa teleport).",
})

TabHalloween:Toggle({
    Title = "Pumpkin ESP",
    Desc = "Highlight + label jarak untuk semua labu aktif.",
    Value = false,
    Callback = function(state) setPumpkinESP(state) end,
})

TabHalloween:Toggle({
    Title = "Auto Run ke Labu",
    Desc = "Pathfinding ke labu terdekat, anti-stuck + auto-jump.",
    Value = false,
    Callback = function(state)
        if state then startAutoRun() else stopAutoRun() end
    end,
})

-- Player ---------------------------------------------------------------------
S._specStatus = TabPlayer:Paragraph({ Title = "Spectate", Desc = "Target: -" })

local specPlayers = {}
for _, p in ipairs(othersList()) do table.insert(specPlayers, p.Name) end
if #specPlayers == 0 then specPlayers = { "-" } end

local ddSpectate = TabPlayer:Dropdown({
    Title = "Select Player",
    Desc = "Pilih pemain untuk di-spectate",
    Values = specPlayers,
    Value = specPlayers[1],
    Callback = function(opt)
        local name = opt
        if type(opt) == "table" then name = opt.Title or opt.Value or opt[1] end
        name = tostring(name)
        if name == "-" then return end
        local target = Players:FindFirstChild(name)
        if target and target ~= lp then
            setSpectate(target)
            pcall(function()
                S._specStatus:SetDesc("Target: " .. (target.DisplayName or target.Name) .. " (@" .. target.Name .. ")")
            end)
        end
    end,
})

TabPlayer:Button({
    Title = "Refresh Daftar Player",
    Desc = "Muat ulang daftar pemain di dropdown",
    Callback = function()
        local names = {}
        for _, p in ipairs(othersList()) do table.insert(names, p.Name) end
        if #names == 0 then names = { "-" } end
        local ok = pcall(function() ddSpectate:Refresh(names) end)
        if not ok then pcall(function() ddSpectate:Set(names) end) end
        pcall(function() S._specStatus:SetDesc("Daftar diperbarui (" .. #names .. ")") end)
    end,
})

TabPlayer:Button({
    Title = "Spectate / Stop",
    Desc = "Spectate target terpilih, klik lagi untuk kembali",
    Callback = function()
        if spectate.target then
            setSpectate(nil)
            pcall(function() S._specStatus:SetDesc("Target: -") end)
        else
            local sel = nil
            pcall(function()
                local v = ddSpectate:Get()
                if type(v) == "table" then v = v.Value or v[1] end
                if v and v ~= "-" then sel = Players:FindFirstChild(tostring(v)) end
            end)
            if not sel then
                local names = othersList()
                sel = names[1]
            end
            if sel then
                setSpectate(sel)
                pcall(function()
                    S._specStatus:SetDesc("Target: " .. (sel.DisplayName or sel.Name) .. " (@" .. sel.Name .. ")")
                end)
            end
        end
    end,
})

TabPlayer:Button({
    Title = "Next Player",
    Desc = "Spectate pemain berikutnya",
    Callback = function()
        local p = spectateStep(1)
        pcall(function()
            S._specStatus:SetDesc(p and ("Target: " .. (p.DisplayName or p.Name)) or "Tidak ada player lain")
        end)
    end,
})

TabPlayer:Button({
    Title = "Previous Player",
    Desc = "Spectate pemain sebelumnya",
    Callback = function()
        local p = spectateStep(-1)
        pcall(function()
            S._specStatus:SetDesc(p and ("Target: " .. (p.DisplayName or p.Name)) or "Tidak ada player lain")
        end)
    end,
})

TabPlayer:Button({
    Title = "Stop Spectate",
    Desc = "Kembali ke kamera sendiri",
    Callback = function()
        setSpectate(nil)
        pcall(function() S._specStatus:SetDesc("Target: -") end)
    end,
})

-- Pengaturan -----------------------------------------------------------------
TabPengaturan:Paragraph({
    Title = "UI",
    Desc = "Keybind F (PC) atau tombol pill '☁ Clouds Hub' (draggable, semua platform).",
})

TabPengaturan:Toggle({
    Title = "Anti-AFK",
    Desc = "Mencegah kick idle saat AFK mancing.",
    Value = false,
    Callback = function(state) setAntiAfk(state) end,
})

TabPengaturan:Keybind({
    Title = "Keybind Buka/Tutup UI",
    Desc = "Default: F (PC)",
    Value = S.uiToggleKey,
    Callback = function(v) applyToggleKey(Window, v) end,
})

TabPengaturan:Toggle({
    Title = "Tampilkan Tombol Clouds",
    Desc = "Tombol pill '☁ Clouds Hub' di sisi layar.",
    Value = S.showPill,
    Callback = function(state)
        S.showPill = state
        pcall(function()
            local cg = (gethui and gethui()) or game:GetService("CoreGui")
            local gui = cg:FindFirstChild("CloudsHub_ToggleGui")
            if gui then gui.Enabled = state end
        end)
    end,
})

TabPengaturan:Button({
    Title = "Unload Clouds Hub",
    Desc = "Matikan semua fitur & hapus UI",
    Callback = function()
        pcall(function() S.Unload() end)
    end,
})

-- ===== 12. Pill toggle (draggable) =========================================
pcall(function()
    local host = (gethui and gethui()) or game:GetService("CoreGui")
    local gui = Instance.new("ScreenGui")
    gui.Name = "CloudsHub_ToggleGui"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Enabled = S.showPill
    gui.Parent = host

    local btn = Instance.new("TextButton")
    btn.Name = "ToggleCloudsHub"
    btn.Size = UDim2.fromOffset(118, 36)
    btn.Position = UDim2.new(0, 14, 0.5, -18)
    btn.BackgroundColor3 = Color3.fromHex("#38bdf8")
    btn.BackgroundTransparency = 0.08
    btn.Text = "☁ Clouds Hub"
    btn.TextColor3 = Color3.fromHex("#f0f9ff")
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.AutoButtonColor = true
    btn.Active = true
    btn.Draggable = true
    btn.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = btn

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.2
    stroke.Color = Color3.fromHex("#bae6fd")
    stroke.Transparency = 0.25
    stroke.Parent = btn

    btn.MouseButton1Click:Connect(function()
        pcall(function()
            if Window and Window.Toggle then Window:Toggle() end
        end)
    end)
end)

-- ===== 13. Unload ==========================================================
S.Unload = function()
    S._alive = false
    S.running = false
    pcall(function() inputRelease() end)
    setAntiAfk(false)
    setPumpkinESP(false)
    stopAutoRun()
    setSpectate(nil)
    for _, c in ipairs(S._conn) do
        pcall(function() c:Disconnect() end)
    end
    S._conn = {}
    if afkConn then pcall(function() afkConn:Disconnect() end) afkConn = nil end
    pcall(function()
        if Window then
            if Window.Destroy then Window:Destroy() end
        end
    end)
    pcall(function()
        local host = (gethui and gethui()) or game:GetService("CoreGui")
        local gui = host:FindFirstChild("CloudsHub_ToggleGui")
        if gui then gui:Destroy() end
    end)
    genv.__CLOUDS_HUB_V3 = nil
    print("[CloudsHub] V3 unloaded")
end
genv.__CLOUDS_HUB_V3 = S

-- Default Anti-AFK ON (untuk AFK mancing)
setAntiAfk(true)

print("[CloudsHub] loaded V3.0.1 — input-only auto fishing (tanpa debug hook), UI biru langit")
