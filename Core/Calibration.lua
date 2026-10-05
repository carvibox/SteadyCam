---------------------------------------------------------------------------------------
--  Core/Calibration.lua — guided calibration (state machine)
---------------------------------------------------------------------------------------
--  For one mount: three camera distances (near / mid / far, set automatically), and at
--  each one `repeats` × (MOUNT, DISMOUNT). The player presses one secure button per step
--  (UI/Wizard.lua): /say (the measured chat bubble) + /cast <mount> or /dismount.
--  The shoulder offset is held constant (PC.SetCalibrationHold) so X = -G·hold:
--    mount step    → on-foot gain (during the cast) and mounted gain (after it)
--    dismount step → normalized curve g(t) (Analysis.NormalizeDismount)
--  Every step is quality-checked (bubble seen, no movement, zoom unchanged, right mount)
--  and repeated on failure. Results go to models[race-sex].mounts[mountID]; the zoom,
--  chat bubbles and framing are restored at the end (KNOWLEDGE.md §7).
--  States: idle → zooming → ready → recording → (settling) → … → done | paused (combat).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local C_MountJournal = _G.C_MountJournal
local C_Spell = _G.C_Spell
local CameraZoomIn = _G.CameraZoomIn
local CameraZoomOut = _G.CameraZoomOut
local CreateFrame = _G.CreateFrame
local GetCameraZoom = _G.GetCameraZoom
local GetFramerate = _G.GetFramerate
local GetTime = _G.GetTime
local InCombatLockdown = _G.InCombatLockdown
local IsIndoors = _G.IsIndoors
local IsInInstance = _G.IsInInstance
local IsResting = _G.IsResting
local UIParent = _G.UIParent

local abs, max, min, floor = math.abs, math.max, math.min, math.floor

local C = {}
PC.Calibration = C

local NEAR_ZOOM, FAR_ZOOM = 12, 22 -- two distances (results don't depend on zoom)
local MAX_ZOOM_CAP = 39
local REPEATS_FULL, REPEATS_QUICK = 3, 1
local MOUNT_AFTER = 1.6 -- seconds recorded after mounting (steady mounted gain at the end)
local DISMOUNT_AFTER = 1.0
local MOUNT_TIMEOUT = 5 -- 1.5 s cast + latency + margin
local DISMOUNT_TIMEOUT = 8 -- long enough to dismount yourself if the button didn't
local SETTLE = 0.8 -- seconds before the next mount is offered
local MAX_MOVE = 1.5 -- yards (some big mounts nudge you when summoned)
local MAX_SPEED = 0.1 -- yards/s: any real movement after the click fails the step
local MAX_ZOOM_DRIFT = 0.3
local MIN_COVERAGE = 0.8 -- share of frames with the bubble seen after the swap
-- On-foot / mounted gain ratio bounds. Small races on big mounts measure well above 12
-- (gnome on a Golden Gryphon), so only absurd values are rejected; the real guard is
-- MIN_MOUNTED_PX: the mounted bubble must move a measurable amount.
local MIN_RATIO, MAX_RATIO = 1.05, 40
local MIN_MOUNTED_PX = 3
local MAX_STEP_FAILURES = 4 -- the same step failing this often: the mount can't be measured
-- Big mounts can push your chat bubble out of view (or measure as "too close"): the first
-- time a step fails that way, both vertical framings drop to this for the rest of the
-- calibration, and the player's own values come back at the end (Restore).
local LOW_PAD = 0.05

local run -- nil when idle
local driver

C.state = "idle"

local function Fire()
  PC.Fire("CALIBRATION_STATE", C.state)
end

local function Median(list)
  if #list == 0 then
    return nil
  end
  local copy = {}
  for i = 1, #list do
    copy[i] = list[i]
  end
  table.sort(copy)
  local mid = floor(#copy / 2) + 1
  if #copy % 2 == 0 then
    return (copy[mid - 1] + copy[mid]) / 2
  end
  return copy[mid]
end

---------------------------------------------------------------------------------------
-- Plan
---------------------------------------------------------------------------------------
--- Near / mid / far camera distances for this client (max = 15 × max zoom factor).
--- Two distances. The size factor and dip gain are the same at every zoom (measured
--- 6–39), so two are enough to cross-check; 12 is far enough for big mounts to fit on
--- screen (6 often failed with "too close") and 22 stays clear of most walls behind you.
function C.ZoomLevels()
  local factor = tonumber(C_CVar.GetCVar("cameraDistanceMaxZoomFactor")) or 1.9
  local far = min(FAR_ZOOM, 15 * factor, MAX_ZOOM_CAP)
  local near = min(NEAR_ZOOM, max(3, far - 6))
  return { near, far }
end

--- Shoulder held during a level: big enough to measure while mounted, small enough that
--- the on-foot bubble stays on screen (~35 % of the half-width). On-foot px per unit at
--- zoom z ≈ 0.78 × UI height / z (KNOWLEDGE.md §4).
function C.HoldFor(zoom)
  local footGain = 0.78 * UIParent:GetHeight() / max(zoom, 1)
  return PC.Clamp(0.35 * (UIParent:GetWidth() / 2) / footGain, 0.5, 5)
end

--- Quick (1 run per distance) when there is something to check the run against: your own
--- calibrated mounts, or SteadyCam's shipped measurements for your race (every race but
--- the unmeasured ones). Full (3 runs) otherwise, so a bad sample can be spotted.
function C.Repeats()
  for _, m in pairs(PC.GetModelStore().mounts) do
    if m.captures and #m.captures > 0 then
      return REPEATS_QUICK
    end
  end
  local key = PC.GetModelKey()
  if PC.KnownCalibrations[key] or PC.KnownCalibrations[PC.RaceAliases[key] or ""] then
    return REPEATS_QUICK
  end
  return REPEATS_FULL
end

function C.StepCount(repeats)
  return #C.ZoomLevels() * (repeats or C.Repeats()) * 2
end

function C.CastName(mountID)
  local name, spellID = C_MountJournal.GetMountInfoByID(mountID)
  if spellID and C_Spell and C_Spell.GetSpellName then
    name = C_Spell.GetSpellName(spellID) or name
  end
  return name
end

--- Mounts offered by the wizard: the one you ride (if any) first, then favorites.
local mountCache = {} -- [filter] = { at, list }

--- Mounts for the picker. filter: "favorites" | "usable" (usable here) | "all"
--- (collected). The mount you ride is always listed. Sorted: that one, then usable before
--- not usable here, then the ones you ride most, then by name.
--- Each: { id, name, icon, usable, favorite, riding, uses }.
function C.CandidateMounts(filter)
  filter = filter or "favorites"
  local now = GetTime()
  local cached = mountCache[filter]
  if cached and now - cached.at < 2 then
    return cached.list
  end
  local list = {}
  local current = PC.GetCurrentMountID()
  if C_MountJournal and C_MountJournal.GetMountIDs then
    for _, id in ipairs(C_MountJournal.GetMountIDs()) do
      local name, _, icon, _, isUsable, _, isFavorite, _, _, hideOnChar, isCollected =
        C_MountJournal.GetMountInfoByID(id)
      local riding = id == current
      local wanted = filter == "all"
        or (filter == "favorites" and isFavorite)
        or (filter == "usable" and isUsable)
      if isCollected and not hideOnChar and (wanted or riding) then
        list[#list + 1] = {
          id = id,
          name = name,
          icon = icon,
          usable = isUsable and true or false,
          favorite = isFavorite and true or false,
          riding = riding,
          uses = PC.db.mountUse[id] or 0,
        }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.riding ~= b.riding then
      return a.riding
    end
    if a.usable ~= b.usable then
      return a.usable
    end
    if a.uses ~= b.uses then
      return a.uses > b.uses
    end
    return (a.name or "") < (b.name or "")
  end)
  mountCache[filter] = { at = now, list = list }
  return list
end

--- Forget the cached mount lists (window opened, filter changed, journal changed).
function C.RefreshMountList()
  mountCache = {}
end

-- What you ride is listed first: mounting or dismounting changes the order.
PC.On("MOUNT_SWAP", C.RefreshMountList)
PC.On("MOUNT_IDENTIFIED", C.RefreshMountList)

--- Pre-flight checks: { {key, ok, required, args...}, ... }.
function C.Checks(mountID)
  local s = PC.db.settings
  local usable = false
  if mountID then
    local _, _, _, _, isUsable = C_MountJournal.GetMountInfoByID(mountID)
    usable = isUsable and true or false
  end
  local inInstance = IsInInstance and IsInInstance()
  local checks = {
    { key = "race", ok = true, required = true },
    { key = "combat", ok = not InCombatLockdown(), required = true },
    { key = "instance", ok = not inInstance, required = true },
    -- Cities and inns (rest areas) are crowded: a dozen /say lines there read as spam.
    { key = "resting", ok = not (IsResting and IsResting()), required = true },
    { key = "outdoors", ok = not (IsIndoors and IsIndoors()), required = true },
    {
      key = "active",
      ok = PC.IsActive() and not s.respectMotionSickness,
      required = true,
    },
    { key = "mount", ok = mountID ~= nil and usable, required = true },
    { key = "fps", ok = (GetFramerate and GetFramerate() or 60) >= 55, required = false },
  }
  -- DynamicCam moves the same CVars: measurements would be garbage. Only listed when loaded.
  if PC.dynamicCamLoaded then
    table.insert(checks, 6, { key = "dynamiccam", ok = false, required = true })
  end
  return checks
end

function C.CanStart(mountID)
  for _, check in ipairs(C.Checks(mountID)) do
    if check.required and not check.ok then
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------------------
-- Zoom
---------------------------------------------------------------------------------------
local function ZoomCommand(target)
  local d = target - GetCameraZoom()
  if d > 0.05 then
    CameraZoomOut(d)
  elseif d < -0.05 then
    CameraZoomIn(-d)
  end
end

---------------------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------------------
local EnterReady

local function SetMessage(key, kind, detail)
  run.message, run.messageKind, run.detail = key, kind, detail
end

--- The journal's own answer: is the selected mount the one being ridden?
local function RidingSelectedMount()
  local _, _, _, isActive = C_MountJournal.GetMountInfoByID(run.mountID)
  return isActive and true or false
end

local function EnterZooming(level)
  run.level = level
  run.zoomTarget = run.levels[level]
  run.zoomStarted = GetTime()
  run.zoomIssued = nil
  run.zoomStable = nil
  C.state = "zooming"
  driver:Show()
  Fire()
end

--- What the button does now, fixing up state the player changed by hand.
local function ResolveAction()
  local step = run.steps[run.index]
  local mounted = PC.IsMountedOrInVehicle()
  if step.kind == "mount" then
    return mounted and "prep" or "mount"
  end
  if not mounted then
    run.index = run.index - 1 -- redo this pair's mount
    return "mount"
  end
  if not RidingSelectedMount() then
    run.index = run.index - 1
    return "prep"
  end
  return "dismount"
end

EnterReady = function()
  run.action = ResolveAction()
  C.state = "ready"
  driver:Hide()
  Fire()
end

local function Settle(seconds)
  run.settleUntil = GetTime() + seconds
  C.state = "settling"
  driver:Show()
  Fire()
end

--- Movement after the click: real speed, or a large position change (summons can nudge
--- you a little without you moving).
local function Moved(samples, fromT)
  local x0, y0
  for _, s in ipairs(samples) do
    if s.t >= fromT then
      if s.speed and s.speed > MAX_SPEED then
        return true, string.format("speed %.2f", s.speed)
      end
      if s.wx and s.wy then
        if not x0 then
          x0, y0 = s.wx, s.wy
        else
          local d = ((s.wx - x0) ^ 2 + (s.wy - y0) ^ 2) ^ 0.5
          if d > MAX_MOVE then
            return true, string.format("moved %.1f yd", d)
          end
        end
      end
    end
  end
  return false
end

--- Zoom changes after the click, judged on foot only (mounted zoom is the game's).
local function ZoomDrifted(samples, fromT)
  for _, s in ipairs(samples) do
    if s.t >= fromT and not s.mounted and s.zoom then
      local d = abs(s.zoom - run.levelZoom)
      if d > MAX_ZOOM_DRIFT then
        return true, string.format("zoom %.1f vs %.1f", s.zoom, run.levelZoom)
      end
    end
  end
  return false
end

--- Mount step: on-foot gain during the cast, mounted gain at the end.
local function EvaluateMount(r)
  local hold = run.hold
  local pre, post = {}, {}
  for _, s in ipairs(r.samples) do
    if s.x and s.sh and abs(s.sh) > 0.2 then
      local g = -s.x / s.sh
      if s.t <= -0.05 and s.t >= -1.6 and not s.mounted then
        pre[#pre + 1] = g
      elseif s.t >= MOUNT_AFTER - 0.6 and s.mounted then
        post[#post + 1] = g
      end
    end
  end
  if #pre < 6 or #post < 6 then
    return false, "nobubble", string.format("bubble frames: %d on foot, %d mounted", #pre, #post)
  end
  local gf, gm = Median(pre), Median(post)
  if gf and gm and gf > 0.1 and (gm <= 0 or gm >= gf) then
    -- Mounted bubble on the wrong side, or farther out than on foot: the camera sits too
    -- close to frame this (big) mount, so the projection is meaningless.
    return false, "close", string.format("mounted %+.0f px vs on foot %+.0f px", -gm * hold, -gf * hold)
  end
  if not gm or not gf or gf <= 0.1 or gm * abs(hold) < MIN_MOUNTED_PX then
    return false, "small", string.format("mounted move %.1f px (hold %.2f)", (gm or 0) * abs(hold), hold)
  end
  local ratio = gf / gm
  if ratio < MIN_RATIO or ratio > MAX_RATIO then
    return false, "data", string.format("size factor %.2f out of range", ratio)
  end
  run.gm[run.level] = gm
  run.ratios[#run.ratios + 1] = ratio
  PC.Debug(string.format("mount ok: hold %.2f gf %.1f gm %.1f ratio %.2f", hold, gf, gm, ratio))
  return true
end

--- Dismount step: normalized gain curve.
local function EvaluateDismount(r)
  local gmPre = {}
  local after, seen = 0, 0
  local simple = {}
  for _, s in ipairs(r.samples) do
    if s.x and s.sh and abs(s.sh) > 0.2 and s.mounted and s.t >= -0.6 and s.t <= -0.03 then
      gmPre[#gmPre + 1] = -s.x / s.sh
    end
    if s.t >= 0.15 and s.t <= 0.8 then
      after = after + 1
      if s.x then
        seen = seen + 1
      end
    end
    simple[#simple + 1] = { t = s.t, x = s.x, sh = s.sh }
  end
  if after == 0 or seen / after < MIN_COVERAGE then
    return false, "nobubble", string.format("bubble seen in %d of %d frames", seen, after)
  end
  local gm = (#gmPre >= 4) and Median(gmPre) or run.gm[run.level]
  if not gm then
    return false, "nobubble", "no mounted measurement before the dismount"
  end
  local capture, err = PC.Analysis.NormalizeDismount(simple, run.levelZoom, gm)
  if not capture then
    return false, "data", tostring(err)
  end
  if capture.ratio < MIN_RATIO or capture.ratio > MAX_RATIO then
    return false, "data", string.format("size factor %.2f out of range", capture.ratio)
  end
  if capture.ramp < 0.03 or capture.ramp > 0.6 then
    return false, "data", string.format("camera switch at %.2fs", capture.ramp)
  end
  for i = 1, math.min(#capture.g, 41) do
    if capture.g[i] < 0.1 then
      -- The bubble swung to the other side: the camera is too close for this mount.
      return false, "close", string.format("dismount curve %.2f at %.2fs", capture.g[i], (i - 1) * capture.dt)
    end
  end
  capture.clickToSwap = r.clickToSwap -- click → IsMounted() flip (diagnostics)
  local tSwitch
  for _, e in ipairs(r.events or {}) do
    if e.e == "COMPANION_UPDATE" and e.t > 0.03 then
      tSwitch = e.t
      break
    end
  end
  capture.confirmAt = tSwitch
  local h
  if run.stepUsed then
    -- Played the two-step plan: the plateau before the confirmation gives h directly.
    h = PC.Analysis.StepDipGain(r.samples, run.stepUsed, tSwitch, -gm * run.hold)
    capture.stepGain = h
  else
    h = PC.Analysis.FitDipGain(simple, tSwitch)
  end
  if h then
    capture.dipGain = h
    run.dipGains[#run.dipGains + 1] = h
  end
  run.captures[#run.captures + 1] = capture
  run.ratios[#run.ratios + 1] = capture.ratio
  PC.Debug(string.format("dismount ok: ratio %.2f ramp %.2fs, confirmed at %s, dip gain %s", capture.ratio,
    capture.ramp, tSwitch and string.format("%.2fs", tSwitch) or "once", h and string.format("%.2f", h) or "-"))
  return true
end

local Finish, Restore

-- The calibration couldn't finish. kind "big": the camera can't frame this mount even
-- backed off (it keeps failing as "too close") — mark it so the chat stops offering it
-- and use estimated values, unless an older calibration of it exists. kind "obstacle":
-- the two distances disagree — usually a wall or tree behind you pulling the camera in
-- (seen with a house behind an orc): keep whatever was stored and ask to move.
local function GiveUp(why, kind)
  PC.Debug("calibration given up (" .. tostring(kind) .. "): " .. tostring(why))
  local mounts = PC.GetModelStore().mounts
  local old = mounts[run.mountID]
  local hasOld = old and old.captures and #old.captures > 0
  if kind == "big" and not hasOld then
    mounts[run.mountID] = {
      name = run.mountName,
      unmeasurable = true,
      dipGains = old and old.dipGains,
      stepGains = old and old.stepGains,
      dipGain = old and old.dipGain,
    }
    PC.Print(string.format(PC.L.CAL_UNMEASURABLE, tostring(run.mountName or "?")))
  else
    kind = "obstacle"
    PC.Print(string.format(PC.L.CAL_OBSTACLE, tostring(run.mountName or "?")))
  end
  run.summary = { mountName = run.mountName, unmeasurable = kind == "big", obstacle = kind == "obstacle" }
  Restore()
  C.state = "done"
  C.lastSummary = run.summary
  run = nil
  Fire()
  PC.Fire("CALIBRATION_UPDATED")
  PC.ApplyFraming()
end

-- Dismount steps play the same two-step plan as a real dismount, with the measuring
-- offset (run.hold) instead of yours: from the swap hold / h (h = the current best guess
-- for this mount), back to hold when the server confirms. Where the screen settles in
-- between tells the true h (Analysis.StepDipGain) far more precisely than fitting the
-- game's own curve did (0.19 vs a true 0.32 on a blood elf).
PC.On("MOUNT_SWAP", function(mounted, _, confirmed)
  if not run or mounted or confirmed or C.state ~= "recording" or run.action ~= "dismount" or not run.hold then
    return
  end
  run.stepUsed = PC.Profiles.GetDipGain(run.mountID)
  run.stepActive = true
  PC.SetCalibrationHold(PC.Clamp(run.hold / run.stepUsed, 0.5, 20))
end)

PC.On("MOUNT_CONFIRMED", function()
  if run and run.stepUsed and run.stepActive then
    run.stepActive = false
    PC.SetCalibrationHold(run.hold)
  end
end)

local function OnCapture(r)
  if not run or C.state ~= "recording" then
    return
  end
  if run.stepActive then
    run.stepActive = false
    PC.SetCalibrationHold(run.hold) -- no confirmation came
  end
  local step = run.steps[run.index]
  local fromClick = -(r.clickToSwap or 0) -- only judge what happened after the click
  local ok, reason, detail
  local moved, movedDetail = Moved(r.samples, fromClick)
  local drifted, driftDetail = ZoomDrifted(r.samples, fromClick)
  if not r.ok then
    ok, reason = false, r.reason
  elseif r.swapMounted ~= (step.kind == "mount") then
    ok, reason = false, "noswap"
  elseif step.kind == "mount" and not RidingSelectedMount() then
    ok, reason, detail = false, "mount", "riding " .. tostring(PC.GetCurrentMountID())
  elseif moved then
    ok, reason, detail = false, "moved", movedDetail
  elseif drifted then
    ok, reason, detail = false, "zoom", driftDetail
  elseif step.kind == "mount" then
    ok, reason, detail = EvaluateMount(r)
  else
    ok, reason, detail = EvaluateDismount(r)
  end

  if not ok then
    run.failures = run.failures + 1
    run.stepFailures = (run.stepFailures or 0) + 1
    -- Big mount (bubble lost, "too close", mounted move too small): the first time, lower
    -- the vertical framing for the rest of this calibration — on foot the bubble then sits
    -- lower on screen — and, at the near distance, also back the camera off, which is what
    -- helps while mounted (on a ground mount the game ignores the vertical framing).
    local settings = PC.db.settings
    local padHelps = settings.dynamicPitch and (settings.footPitch or 0) > LOW_PAD + 0.05
    local bigMount = reason == "nobubble" or reason == "close" or reason == "small"
    if bigMount and not run.padLowered and padHelps then
      run.padLowered = true
      run.stepFailures = 0 -- a fresh try with the new framing
      PC.SetCalibrationPad(LOW_PAD)
      PC.Debug(string.format("step %d (%s) failed: %s %s -> vertical framing lowered", run.index, step.kind,
        reason, detail or ""))
      SetMessage("WIZ_PAD_LOWERED", "info", detail)
      PC.Print(PC.L.WIZ_PAD_LOWERED)
      local levels = run.levels
      if reason == "close" and run.level == 1 and levels[1] + 1 < levels[2] - 2 then
        levels[1] = math.min(levels[1] + 3, levels[2] - 2)
        EnterZooming(1)
      elseif step.kind == "dismount" and not PC.IsMountedOrInVehicle() then
        Settle(SETTLE) -- dismounted anyway: redo the pair's mount next
      else
        EnterReady()
      end
      return
    end
    if reason == "small" then
      reason = "data" -- same message for the player
    end
    if run.stepFailures >= MAX_STEP_FAILURES then
      GiveUp(string.format("%s %s", reason, detail or ""), (reason == "close" or reason == "data") and "big" or "obstacle")
      return
    end
    PC.Debug(string.format("step %d (%s) failed: %s %s", run.index, step.kind, reason, detail or ""))
    if reason == "close" then
      -- Back the near distance off for this mount (big mounts need room), then redo.
      local levels = run.levels
      if run.level == 1 and levels[1] + 1 < levels[2] - 2 then
        levels[1] = math.min(levels[1] + 3, levels[2] - 2)
        SetMessage("FAIL_close", "warn", detail)
        EnterZooming(1)
        return
      end
      reason = "data"
    end
    SetMessage("FAIL_" .. reason .. (reason == "noswap" and ("_" .. step.kind) or ""), "warn", detail)
    if reason == "zoom" then
      EnterZooming(run.level)
    elseif step.kind == "dismount" and not PC.IsMountedOrInVehicle() then
      Settle(SETTLE) -- dismounted anyway: redo the pair's mount next
    else
      EnterReady()
    end
    return
  end

  SetMessage("WIZ_OK", "ok")
  run.stepFailures = 0
  run.index = run.index + 1
  if run.index > #run.steps then
    Finish()
    return
  end
  local nextStep = run.steps[run.index]
  if nextStep.level ~= run.level then
    EnterZooming(nextStep.level)
  elseif nextStep.kind == "mount" then
    Settle(SETTLE)
  else
    EnterReady()
  end
end

---------------------------------------------------------------------------------------
-- Driver (zooming / settling timers)
---------------------------------------------------------------------------------------
local function DriverUpdate(self)
  if not run then
    self:Hide()
    return
  end
  local now = GetTime()
  if C.state == "settling" then
    if now >= run.settleUntil then
      EnterReady()
    end
  elseif C.state == "zooming" then
    local z = GetCameraZoom()
    local target = run.zoomTarget
    local close = abs(z - target) < 0.15
    local timedOut = now - run.zoomStarted > 8
    if close or (timedOut and abs(z - (run.lastZoom or z)) < 0.01) then
      run.zoomStable = run.zoomStable or now
      if now - run.zoomStable >= 0.3 then
        run.levelZoom = z
        run.hold = C.HoldFor(z)
        PC.SetCalibrationHold(run.hold)
        EnterReady()
        return
      end
    else
      run.zoomStable = nil
      local still = run.lastZoom and abs(z - run.lastZoom) < 0.01
      if not run.zoomIssued or (still and now - run.zoomIssued > 1) then
        ZoomCommand(target)
        run.zoomIssued = now
      end
    end
    run.lastZoom = z
  else
    self:Hide()
  end
end

---------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------
--- quick: one pass per distance (6 steps) whatever this race + sex has calibrated.
function C.Start(mountID, quick)
  if run or C.limitRunning or not C.CanStart(mountID) then
    return false
  end
  C.StopTest() -- the wizard needs the recorder
  local name, _, icon = C_MountJournal.GetMountInfoByID(mountID)
  local repeats = quick and REPEATS_QUICK or C.Repeats()
  local steps = {}
  local levels = C.ZoomLevels()
  for level = 1, #levels do
    for _ = 1, repeats do
      steps[#steps + 1] = { kind = "mount", level = level }
      steps[#steps + 1] = { kind = "dismount", level = level }
    end
  end
  run = {
    mountID = mountID,
    mountName = name,
    icon = icon,
    castName = C.CastName(mountID),
    levels = levels,
    steps = steps,
    index = 1,
    gm = {},
    ratios = {},
    dipGains = {},
    captures = {},
    failures = 0,
    restore = {
      zoom = GetCameraZoom(),
      chatBubbles = C_CVar.GetCVar("chatBubbles"),
    },
  }
  if run.restore.chatBubbles ~= "1" then
    C_CVar.SetCVar("chatBubbles", 1)
  end
  if not driver then
    driver = CreateFrame("Frame", "SteadyCamCalibrationDriver")
    driver:SetScript("OnUpdate", DriverUpdate)
  end
  PC.Recorder.Begin()
  SetMessage(nil)
  EnterZooming(1)
  return true
end

Restore = function()
  PC.Recorder.End()
  if driver then
    driver:Hide()
  end
  PC.calibrationPad = nil -- the player's vertical framing again (applied just below)
  PC.SetCalibrationHold(nil)
  if run then
    if run.restore.chatBubbles and run.restore.chatBubbles ~= "1" then
      C_CVar.SetCVar("chatBubbles", run.restore.chatBubbles)
    end
    if run.restore.zoom then
      ZoomCommand(run.restore.zoom)
    end
  end
end

Finish = function()
  local kept, trusted = PC.Analysis.ConsistentCaptures(run.captures)
  if not trusted then
    GiveUp("size factors disagree between distances", "obstacle")
    return
  end
  local ratios, dips = {}, {}
  for _, c in ipairs(kept) do
    ratios[#ratios + 1] = c.ratio
    dips[#dips + 1] = c.dipGain
  end
  run.captures, run.ratios, run.dipGains = kept, ratios, dips
  local mounts = PC.GetModelStore().mounts
  local old = mounts[run.mountID]
  local entry = {
    name = run.mountName,
    ratio = Median(run.ratios),
    captures = run.captures,
    calibratedAt = _G.time and _G.time() or 0,
    levels = run.levels,
    dipGains = old and old.dipGains,
    stepGains = old and old.stepGains, -- plan measurements of this mount stay valid
    dipGain = old and old.dipGain,
  }
  mounts[run.mountID] = entry
  for _, c in ipairs(run.captures) do
    if c.dipGain then
      PC.Profiles.LearnDipGain(run.mountID, c.dipGain, nil, c.stepGain ~= nil)
    end
  end
  local ramps = {}
  for level = 1, #run.levels do
    local list = {}
    for _, c in ipairs(run.captures) do
      if abs(c.zoom - run.levels[level]) < 2 then
        list[#list + 1] = c.ramp
      end
    end
    ramps[level] = Median(list)
  end
  run.summary = {
    mountName = run.mountName,
    ratio = entry.ratio,
    ramps = ramps,
    captures = #run.captures,
    failures = run.failures,
  }
  local others = 0
  for _, id in ipairs(PC.MountFamily(run.mountID)) do
    if id ~= run.mountID then
      others = others + 1
    end
  end
  PC.Print(string.format(PC.L.CAL_DONE_CHAT, tostring(run.mountName or "?"))
    .. (others > 0 and (" " .. string.format(PC.L.CAL_DONE_FAMILY, others)) or ""))
  Restore()
  C.state = "done"
  C.lastSummary = run.summary
  run = nil
  Fire()
  PC.Fire("CALIBRATION_UPDATED")
  PC.ApplyFraming()
end

PC.On("SETTINGS_CHANGED", function(key, value)
  if run and ((key == "enabled" and not value) or (key == "respectMotionSickness" and value)) then
    C.Cancel() -- otherwise its shoulder hold would outlive SteadyCam being off
  end
end)

function C.Cancel()
  if not run then
    C.state = "idle"
    Fire()
    return
  end
  Restore()
  run = nil
  C.state = "idle"
  Fire()
end

function C.Reset()
  if run then
    C.Cancel()
  end
  C.state = "idle"
  C.lastSummary = nil
  Fire()
end

--- Called from the secure button's PreClick on the edge that actually runs the macro.
function C.OnClick()
  if not run or C.state ~= "ready" then
    return
  end
  local action = run.action
  SetMessage(nil)
  if action == "prep" then
    C.state = "settling"
    run.settleUntil = GetTime() + 2.5 -- waits for the dismount below
    driver:Show()
    Fire()
    return
  end
  C.state = "recording"
  run.stepUsed, run.stepActive = nil, false
  PC.Recorder.Capture({
    after = action == "mount" and MOUNT_AFTER or DISMOUNT_AFTER,
    timeout = action == "mount" and MOUNT_TIMEOUT or DISMOUNT_TIMEOUT,
    onDone = OnCapture,
  })
  Fire()
end

--- Macro the secure button must run right now ("" = nothing).
function C.MacroText()
  if not run or C.state ~= "ready" then
    return ""
  end
  local say = "/say " .. string.format(PC.L.SAY_TEXT, run.index, #run.steps)
  if run.action == "mount" then
    return say .. "\n/cast [nomounted] " .. tostring(run.castName)
  elseif run.action == "dismount" then
    -- Not /dismount: it waits for the server and hides the delay your usual dismount has.
    -- These three are shown at once and confirmed later, like the mount button
    -- (KNOWLEDGE.md §4). Each fallback only runs if you are still mounted; if none works,
    -- the step waits for you to dismount yourself.
    local spell = tostring(run.castName)
    return say
      .. "\n/run C_MountJournal.Dismiss()"
      .. "\n/cast [mounted] " .. spell
      .. "\n/cancelaura [mounted] " .. spell
  end
  return "/dismount [mounted]"
end

--- Snapshot for the UI.
function C.View()
  if not run then
    return { state = C.state, summary = C.lastSummary }
  end
  return {
    state = C.state,
    step = run.index,
    total = #run.steps,
    level = run.level,
    zoom = run.levelZoom or run.zoomTarget,
    zoomTarget = run.zoomTarget,
    mountName = run.mountName,
    icon = run.icon,
    action = run.action,
    message = run.message,
    messageKind = run.messageKind,
    detail = run.detail,
  }
end

function C.IsRunning()
  return run ~= nil
end

---------------------------------------------------------------------------------------
-- /steady test: measure your next ordinary mount AND dismount (your current plan).
-- /steady test raw: dismounts keep the mounted offset for a moment, so the game's own
-- camera move is measured the way calibration does it — but with your own way of
-- dismounting (key, spell, /dismount...).
---------------------------------------------------------------------------------------
local TEST_SWAPS, TEST_WINDOW = 2, 120 -- one mount + one dismount, 2 minutes
local RAW_SWAPS, RAW_WINDOW = 6, 300 -- raw tests count dismounts only
local TEST_LOG_MAX = 16 -- tests kept in SteadyCamDB.testLog (oldest dropped)
local testing = false
local testLeft, testTotal, testUntil = 0, 0, 0

-- How a dismount was triggered, from what happened just before the swap.
local function DismountMethod(events)
  local by
  for _, e in ipairs(events or {}) do
    if e.t >= -1.5 and e.t <= 0.05 then
      if e.e == "Dismount()" or e.e == "Dismiss()" then
        by = e.e
      elseif e.e == "SummonByID()" and by ~= "Dismount()" and by ~= "Dismiss()" then
        by = e.e
      elseif e.e == "UNIT_SPELLCAST_SENT" and by ~= "Dismount()" and by ~= "Dismiss()" then
        by = "spell " .. tostring(e.a or "?")
      end
    end
  end
  return by or "other"
end

-- Raw dismount: the game's own curve, normalized like a calibration capture.
local function RawCurve(r, zoom)
  local gmPre, simple = {}, {}
  for _, s in ipairs(r.samples) do
    if s.x and s.sh and abs(s.sh) > 0.2 and s.t >= -0.6 and s.t <= -0.03 then
      gmPre[#gmPre + 1] = -s.x / s.sh
    end
    simple[#simple + 1] = { t = s.t, x = s.x, sh = s.sh }
  end
  if #gmPre < 4 then
    return nil
  end
  local capture = PC.Analysis.NormalizeDismount(simple, zoom or 15, Median(gmPre))
  if not capture then
    return nil
  end
  local dip = math.huge
  for i = 3, math.min(#capture.g, 31) do
    dip = min(dip, capture.g[i])
  end
  capture.dip = dip
  return capture
end

-- A dismount with the two-step plan also measures the dip gain: until the server
-- confirms, the screen settles at h_true / h_used of where it started.
local function StepGain(r, used, confirmAt)
  return PC.Analysis.StepDipGain(r.samples, used, confirmAt)
end

local function ReportTest(r)
  local L = PC.L
  local rows, xs = {}, {}
  local after, seen = 0, 0
  for _, s in ipairs(r.samples) do
    if s.t >= -0.1 and s.t <= 1.2 then
      if s.x then
        xs[#xs + 1] = s.x
      end
      rows[#rows + 1] = string.format(
        "%.4f,%s,%s,%s",
        s.t,
        s.x and string.format("%.1f", s.x) or "",
        s.x and type(s.y) == "number" and string.format("%.1f", s.y) or "",
        s.sh and string.format("%.4f", s.sh) or ""
      )
    end
    -- The /say bubble may need a moment to (re)appear after a model swap.
    if s.t >= 0.15 and s.t <= 0.8 then
      after = after + 1
      if s.x then
        seen = seen + 1
      end
    end
  end
  if #xs < 20 or after == 0 or seen / after < MIN_COVERAGE then
    PC.Print(L.TEST_NOBUBBLE)
    PC.Debug(string.format("test: bubble seen in %d of %d frames after the swap", seen, after))
    return
  end
  local total = 0
  for i = 2, #xs do
    total = total + abs(xs[i] - xs[i - 1])
  end
  local extra = total - abs(xs[#xs] - xs[1])
  local info = PC.lastSwapInfo or {}
  local kind = r.swapMounted and "mount" or "dismount"
  local mountName = PC.GetMountName(info.mountID)
  local events = {}
  for _, e in ipairs(r.events or {}) do
    if e.t >= -2 and e.t <= 1.5 then
      events[#events + 1] = string.format("%.4f,%s,%s", e.t, e.e, e.a or "")
    end
  end
  local by = kind == "dismount" and DismountMethod(r.events) or nil
  local curve = kind == "dismount" and info.kind == "raw" and RawCurve(r, info.zoom) or nil
  local confirmAt
  for _, e in ipairs(r.events or {}) do
    if e.e == "COMPANION_UPDATE" and e.t > 0.03 then
      confirmAt = e.t
      break
    end
  end
  local learnedGain = curve and PC.Analysis.FitDipGain(r.samples, confirmAt) or nil
  if not learnedGain and kind == "dismount" and info.kind == "step" then
    learnedGain = StepGain(r, info.dipGain, confirmAt)
  end
  if learnedGain then
    PC.Profiles.LearnDipGain(info.mountID, learnedGain, nil, info.kind == "step")
  end
  local testRatio = kind == "dismount" and info.kind ~= "raw" and PC.Analysis.TestRatio(r.samples) or nil
  if testRatio then
    PC.Profiles.LearnTestRatio(info.mountID, testRatio)
  end
  if curve then
    PC.Print(string.format(L.TEST_RAW, tostring(mountName or "?"), info.zoom or 0, curve.ramp, curve.dip, curve.ratio))
    PC.Print(string.format(L.TEST_RAW_METHOD, tostring(by or "?"),
      confirmAt and string.format("%.2f s", confirmAt) or L.TEST_RAW_SAME_FRAME))
  else
    PC.Print(string.format(
      L.TEST_RESULT,
      r.swapMounted and L.TEST_MOUNT or L.TEST_DISMOUNT,
      tostring(mountName or "?"),
      info.zoom or 0,
      tostring(info.kind or "?"),
      extra,
      xs[1],
      xs[#xs]
    ))
  end
  if by then
    PC.Debug("test: dismount made by " .. by)
  end
  local log = PC.db.testLog or {}
  PC.db.testLog = log
  PC.db.lastTests = nil -- replaced by testLog
  log[#log + 1] = {
    kind = kind,
    version = PC.version,
    model = PC.GetModelKey(),
    mountID = info.mountID,
    mount = mountName,
    zoom = info.zoom,
    plan = info.kind,
    by = by,
    inAir = kind == "dismount" and info.inAir or nil,
    confirmAt = confirmAt,
    dipGain = info.dipGain, -- the one used
    dipGainMeasured = learnedGain,
    ratioMeasured = testRatio,
    ratioChecked = true,
    learned = true,
    extra = extra,
    ramp = curve and curve.ramp or nil,
    dip = curve and curve.dip or nil,
    ratio = curve and curve.ratio or nil,
    g = curve and curve.g or nil,
    date = date and date("%Y-%m-%d %H:%M:%S") or nil,
    columns = "t,x,y,shoulder",
    rows = rows,
    events = events,
  }
  while #log > TEST_LOG_MAX do
    table.remove(log, 1)
  end
end

local function StopTest()
  if testLeft < testTotal then
    PC.Print(PC.L.TEST_DONE)
  end
  testing = false
  PC.testRaw = nil
  PC.Recorder.End()
end

local function ArmNextTestCapture()
  PC.Recorder.Capture({
    after = 1.2,
    timeout = math.max(1, testUntil - GetTime()),
    dismountOnly = PC.testRaw,
    onDone = function(r)
      if r.ok then
        ReportTest(r)
        testLeft = testLeft - 1
      end
      if r.ok and testLeft > 0 and GetTime() < testUntil then
        if PC.testRaw then
          PC.Print(string.format(PC.L.TEST_RAW_LEFT, testLeft))
        else
          PC.Print(r.swapMounted and PC.L.TEST_NEXT_DISMOUNT or PC.L.TEST_NEXT_MOUNT)
        end
        ArmNextTestCapture()
        return
      end
      if not r.ok and testLeft == testTotal then
        PC.Print(PC.L.TEST_TIMEOUT)
      end
      StopTest()
    end,
  })
end

--- Stop a running test (the wizard takes the recorder over).
function C.StopTest()
  if testing then
    StopTest()
  end
end

--- Arm measurements of your next mount and dismount (you /say right before each).
--- raw: dismounts keep the mounted offset (up to 6 dismounts in 5 minutes).
--- false if a calibration or test is already running.
function C.StartTest(raw)
  if run or testing then
    return false
  end
  testing = true
  testTotal = raw and RAW_SWAPS or TEST_SWAPS
  testLeft, testUntil = testTotal, GetTime() + (raw and RAW_WINDOW or TEST_WINDOW)
  PC.testRaw = raw or nil
  PC.Recorder.Begin()
  ArmNextTestCapture()
  return true
end

---------------------------------------------------------------------------------------
-- /steady test form (debug): record the next shapeshift / model / control change (druid
-- forms, dracthyr Soar, taxis) — or mount swap — with the offset left alone, and report
-- how the camera's px per offset unit changed.
---------------------------------------------------------------------------------------
local FORM_TRIGGERS = {
  UPDATE_SHAPESHIFT_FORM = true,
  UNIT_MODEL_CHANGED = true,
  PLAYER_CONTROL_LOST = true,
  PLAYER_CONTROL_GAINED = true,
}

local function Gain(samples, t0, t1)
  local sum, n = 0, 0
  for _, s in ipairs(samples) do
    if s.x and s.sh and abs(s.sh) > 0.2 and abs(s.x) >= 5 and s.t >= t0 and s.t <= t1 then
      sum, n = sum + s.x / s.sh, n + 1
    end
  end
  return n >= 3 and sum / n or nil
end

local function ReportForm(r)
  local before, after = Gain(r.samples, -0.4, -0.05), Gain(r.samples, 1.8, 2.5)
  local xs, rows = {}, {}
  for _, s in ipairs(r.samples) do
    if s.t >= -0.3 and s.t <= 2.5 then
      if s.x then
        xs[#xs + 1] = s.x
      end
      rows[#rows + 1] = string.format("%.4f,%s,%s,%s", s.t, s.x and string.format("%.1f", s.x) or "",
        s.x and type(s.y) == "number" and string.format("%.1f", s.y) or "", s.sh and string.format("%.4f", s.sh) or "")
    end
  end
  local total = 0
  for i = 2, #xs do
    total = total + abs(xs[i] - xs[i - 1])
  end
  local extra = #xs > 1 and (total - abs(xs[#xs] - xs[1])) or 0
  PC.Print(string.format(PC.L.TEST_FORM, tostring(r.trigger or (r.swapMounted and "mount" or "dismount")),
    before and string.format("%.1f", before) or "?", after and string.format("%.1f", after) or "?",
    (before and after) and string.format("%.2f", after / before) or "?", extra, xs[1] or 0, xs[#xs] or 0))
  local events = {}
  for _, e in ipairs(r.events or {}) do
    if e.t >= -1 and e.t <= 2.5 then
      events[#events + 1] = string.format("%.4f,%s,%s", e.t, e.e, e.a or "")
    end
  end
  local log = PC.db.testLog or {}
  PC.db.testLog = log
  log[#log + 1] = {
    kind = "form",
    trigger = r.trigger,
    version = PC.version,
    model = PC.GetModelKey(),
    zoom = GetCameraZoom(),
    gainBefore = before,
    gainAfter = after,
    extra = extra,
    date = date and date("%Y-%m-%d %H:%M:%S") or nil,
    columns = "t,x,y,shoulder",
    rows = rows,
    events = events,
  }
  while #log > 16 do
    table.remove(log, 1)
  end
end

local formLeft, formUntil = 0, 0

local function ArmForm()
  PC.Recorder.Capture({
    after = 2.5,
    timeout = math.max(1, formUntil - GetTime()),
    triggers = FORM_TRIGGERS,
    onDone = function(r)
      if r.ok then
        ReportForm(r)
        formLeft = formLeft - 1
        if formLeft > 0 and GetTime() < formUntil then
          ArmForm()
          return
        end
      end
      testing = false
      PC.Recorder.End()
      PC.Print(PC.L.TEST_DONE)
    end,
  })
end

function C.StartFormTest()
  if run or testing then
    return false
  end
  testing = true
  formLeft, formUntil = 6, GetTime() + 300
  PC.Recorder.Begin()
  ArmForm()
  return true
end

---------------------------------------------------------------------------------------
-- /steady test limit (debug, on foot, right after a long /say): zoom all the way out and
-- step the offset through LIMIT_STEPS, measuring the bubble on each plateau — where the
-- px per unit stops growing is the game's own limit for test_cameraOverShoulder.
---------------------------------------------------------------------------------------
local LIMIT_STEPS = { 0, 1, 2, 4, 6, 8, 10, 12, 15, 20, 25, 30 }
local LIMIT_SETTLE, LIMIT_MEASURE = 0.35, 0.15
local limit

local function LimitFinish()
  local f = limit.frame
  f:SetScript("OnUpdate", nil)
  C_CVar.SetCVar("test_cameraOverShoulder", limit.prior)
  ZoomCommand(limit.zoom)
  PC.SetCalibrationHold(nil)
  local base = limit.x[0]
  local parts, saved = {}, {}
  for _, v in ipairs(LIMIT_STEPS) do
    local x = limit.x[v]
    if v > 0 then
      local g = (x and base) and (x - base) / v or nil
      parts[#parts + 1] = string.format("%d:%s", v, g and string.format("%.1f", -g) or "-")
      saved[#saved + 1] = string.format("%d,%s", v, x and string.format("%.1f", x) or "")
    end
  end
  PC.Print(string.format(PC.L.TEST_LIMIT, limit.atZoom or 0, table.concat(parts, "  ")))
  local log = PC.db.testLog or {}
  PC.db.testLog = log
  log[#log + 1] = {
    kind = "limit",
    version = PC.version,
    model = PC.GetModelKey(),
    zoom = limit.atZoom,
    base = base,
    date = date and date("%Y-%m-%d %H:%M:%S") or nil,
    columns = "offset,x",
    rows = saved,
  }
  limit = nil
  testing = false
  C.limitRunning = nil
end

local function LimitUpdate(_, elapsed)
  local l = limit
  l.t = l.t + elapsed
  if l.phase == "zoom" then
    local z = GetCameraZoom()
    if abs(z - (l.lastZoom or -1)) < 0.01 then
      l.still = l.still + elapsed
    else
      l.still = 0
    end
    l.lastZoom = z
    if l.still > 0.4 or l.t > 6 then
      l.atZoom, l.phase, l.i, l.t = z, "step", 1, 0
      C_CVar.SetCVar("test_cameraOverShoulder", LIMIT_STEPS[1])
    end
    return
  end
  if l.t >= LIMIT_SETTLE then
    local x = PC.Probe.Read()
    if type(x) == "number" then
      l.sum, l.n = l.sum + x, l.n + 1
    end
  end
  if l.t >= LIMIT_SETTLE + LIMIT_MEASURE then
    local v = LIMIT_STEPS[l.i]
    l.x[v] = l.n > 0 and l.sum / l.n or nil
    l.sum, l.n, l.t = 0, 0, 0
    l.i = l.i + 1
    if l.i > #LIMIT_STEPS then
      LimitFinish()
      return
    end
    C_CVar.SetCVar("test_cameraOverShoulder", LIMIT_STEPS[l.i])
  end
end

function C.StartLimitTest()
  if run or testing or PC.IsMountedOrInVehicle() then
    return false
  end
  testing = true
  C.limitRunning = true
  limit = {
    prior = C_CVar.GetCVar("test_cameraOverShoulder"),
    zoom = GetCameraZoom(),
    x = {},
    phase = "zoom",
    t = 0,
    still = 0,
    sum = 0,
    n = 0,
    frame = limit and limit.frame or CreateFrame("Frame"),
  }
  PC.SetCalibrationHold(tonumber(limit.prior) or 0) -- keep SteadyCam's own writes away
  CameraZoomOut(50)
  limit.frame:SetScript("OnUpdate", LimitUpdate)
  return true
end

-- Combat: pause (secure attributes are locked), resume by re-checking the zoom.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LEAVING_WORLD")
events:SetScript("OnEvent", function(_, event)
  if not run then
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    PC.Recorder.Cancel()
    C.state = "paused"
    if driver then
      driver:Hide()
    end
    Fire() -- still out of lockdown here: the UI clears the macro
  elseif event == "PLAYER_REGEN_ENABLED" then
    if C.state == "paused" then
      EnterZooming(run.level)
    end
  elseif event == "PLAYER_LEAVING_WORLD" then
    C.Cancel()
  end
end)
