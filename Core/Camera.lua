---------------------------------------------------------------------------------------
--  Core/Camera.lua — camera CVar ownership, shoulder driver, mount transitions
---------------------------------------------------------------------------------------
--  Rules learned with Camera Trace (KNOWLEDGE.md §3–4):
--    • ActionCam features need CameraKeepCharacterCentered = 0 and
--      CameraReduceUnexpectedMovement = 0.
--    • Static camera CVars are written only when they change — rewriting the same value
--      can reset the game's dynamic-pitch state (a visible camera "re-center").
--    • Both pitch pads stay constant through mount swaps: the ground pad does nothing on
--      a ground mount, and on foot the game lags pad changes (~0.14 s), so changing it
--      at a swap only adds a vertical bounce.
--    • Mounting: set the mounted offset instantly — the game smooths it itself (~0.2 s).
--    • Dismounting: hold the mounted offset, then smoothstep to the on-foot offset,
--      timed by Profiles (zoom + race + mount) so the move spans the game's own switch.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local CreateFrame = _G.CreateFrame
local GetCameraZoom = _G.GetCameraZoom
local GetTime = _G.GetTime

local abs = math.abs

local CV = {
  SHOULDER = "test_cameraOverShoulder",
  PITCH = "test_cameraDynamicPitch",
  PAD = "test_cameraDynamicPitchBaseFovPad",
  PAD_FLYING = "test_cameraDynamicPitchBaseFovPadFlying",
  PAD_DOWNSCALE = "test_cameraDynamicPitchBaseFovPadDownScale",
  PIVOT_CUTOFF = "test_cameraDynamicPitchSmartPivotCutoffDist",
  KEEP_CENTERED = "CameraKeepCharacterCentered",
  REDUCE_MOVEMENT = "CameraReduceUnexpectedMovement",
  YAW_SPEED = "cameraYawMoveSpeed",
  PITCH_SPEED = "cameraPitchMoveSpeed",
}
PC.CVars = CV

local MANAGED = {
  CV.SHOULDER,
  CV.PITCH,
  CV.PAD,
  CV.PAD_FLYING,
  CV.PAD_DOWNSCALE,
  CV.PIVOT_CUTOFF,
  CV.KEEP_CENTERED,
  CV.REDUCE_MOVEMENT,
  CV.YAW_SPEED,
  CV.PITCH_SPEED,
}

-- Values the reference was measured with (KNOWLEDGE.md §3).
local PAD_DOWNSCALE = 0.25
local PIVOT_CUTOFF = 39
local SHOULDER_LIMIT = 30 -- sanity clamp; the game follows the offset linearly at least to 30 (measured)
-- Flight paths: size factor of the taxi camera for the gnome's scale (Highmountain tauren
-- measured 2.41 = 1.68 × its race factor 1.43), scaled to your race like a mount.
local TAXI_RATIO_GNOME = 1.68

-- test_* CVars pop an "experimental features" confirmation on every change; silence it.
-- WoW 12.1 moved the event into Blizzard_Game's internal router.
pcall(function()
  if _G.GameEvent and _G.GameEvent.UnregisterInternalEvent then
    _G.GameEvent.UnregisterInternalEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
  else
    _G.UIParent:UnregisterEvent("EXPERIMENTAL_CVAR_CONFIRMATION_NEEDED")
  end
end)

local function ReadNumber(name)
  return tonumber(C_CVar.GetCVar(name))
end

local function SetIfChanged(name, value)
  if PC.NoteWrite then
    PC.NoteWrite(name, value)
  end
  local cur = ReadNumber(name)
  if cur ~= nil and abs(cur - value) < 1e-4 then
    return
  end
  C_CVar.SetCVar(name, value)
end

---------------------------------------------------------------------------------------
-- Ownership
---------------------------------------------------------------------------------------
--- SteadyCam drives the camera. DynamicCam doesn't pause it: the player is told the two
--- fight and offered to disable DynamicCam (Runtime.lua).
function PC.IsActive()
  return PC.db.settings.enabled
end

--- Framing CVars are ours to write (active and not deferring to motion sickness).
function PC.FramingActive()
  return PC.IsActive() and not PC.db.settings.respectMotionSickness
end

--- Remember the player's camera CVars once, before the first write. Settings added in a
--- later version are filled in on their own (never overwriting what was remembered).
function PC.CaptureSnapshot()
  local snap = PC.db.priorCVars or {}
  PC.db.priorCVars = snap
  for _, name in ipairs(MANAGED) do
    if snap[name] == nil then
      snap[name] = C_CVar.GetCVar(name)
    end
  end
end

--- Put back the camera CVars remembered before SteadyCam. The turn speed is left alone
--- while SteadyCam is still on (Motion Sickness Protection has nothing to do with it) and
--- when the game's own options set it (that is already the player's choice).
function PC.RestoreSnapshot()
  local snap = PC.db.priorCVars
  if not snap then
    return false
  end
  local keepTurn = PC.IsActive() or PC.db.settings.turnSpeedFromGame
  for name, value in pairs(snap) do
    if value ~= nil and not (keepTurn and (name == CV.YAW_SPEED or name == CV.PITCH_SPEED)) then
      C_CVar.SetCVar(name, value)
      if PC.NoteWrite then
        PC.NoteWrite(name, value) -- SteadyCam's own write: not "something outside"
      end
    end
  end
  return true
end

---------------------------------------------------------------------------------------
-- Framing targets
---------------------------------------------------------------------------------------
-- Races with two models (dracthyr dragon / visage, worgen / human) see the same offset
-- at a different scale in each form (a dracthyr's dragon form about doubles it: the
-- character jumped ~50 px when Soar shifted her out of visage form). The on-foot offset
-- is kept for the form it was set in (footOffsetKey) and scaled by the two forms'
-- factors in the other one, so the character stays put.
local function BaseKey(key)
  return (key or ""):gsub("%-Alt$", "")
end

local sessionKey -- the form you logged in with: the reference for another race's offset

-- Measured on-foot scale of a form relative to its "-Alt" twin, where the race factors
-- (measured mounted) don't tell it well: a dracthyr's dragon form shows the offset 2.02×
-- as big as her visage (2.05 / 2.0 in two Soar tests; race factors said 1.68). Male:
-- 1.89 left the character within 1 px at the Soar cast in two tests.
local FORM_FOOT_SCALE = {
  ["Dracthyr-F"] = 2.02,
  ["Dracthyr-M"] = 1.9,
}

-- On-foot scale of `to` relative to `from` (two forms of one race), or nil.
local function FormScale(from, to)
  local direct = FORM_FOOT_SCALE[to]
  if direct and from == to .. "-Alt" then
    return direct
  end
  local inverse = FORM_FOOT_SCALE[from]
  if inverse and to == from .. "-Alt" then
    return 1 / inverse
  end
  local f1, ok1 = PC.RaceFactor(from)
  local f2, ok2 = PC.RaceFactor(to)
  if ok1 and ok2 and f1 > 0 then
    return f2 / f1
  end
  return nil
end

function PC.FootShoulder()
  local s = PC.db.settings
  local key, setIn = PC.GetModelKey(), s.footOffsetKey
  if not setIn or BaseKey(setIn) ~= BaseKey(key) then
    setIn = sessionKey -- set on another character: keep this one's login form as reference
  end
  if setIn and setIn ~= key and BaseKey(setIn) == BaseKey(key) then
    local scale = FormScale(setIn, key)
    if scale and scale > 0 then
      return s.footOffset / scale
    end
  end
  return s.footOffset
end

-- The offset was set in this form (slider moved, or first login).
local function RememberFootKey()
  PC.db.settings.footOffsetKey = PC.GetModelKey()
end

PC.On("SETTINGS_CHANGED", function(key)
  if key == "footOffset" then
    RememberFootKey()
  end
end)

--- Mounted offset for a mount: "match" scales the foot offset by the mount's measured
--- on-foot / mounted gain ratio so the character keeps the same screen spot.
function PC.MountedShoulder(mountID)
  local s = PC.db.settings
  local value
  if s.mountedMode == "center" then
    value = 0
  elseif s.mountedMode == "custom" then
    value = s.mountedOffset
  elseif mountID == "taxi" then
    value = s.footOffset * TAXI_RATIO_GNOME * PC.RaceFactor(PC.GetModelKey())
  else
    value = s.footOffset * PC.Profiles.GetRatio(mountID)
  end
  return PC.Clamp(value, -SHOULDER_LIMIT, SHOULDER_LIMIT)
end

function PC.CurrentShoulderTarget()
  if PC.IsMountedOrInVehicle() then
    return PC.MountedShoulder(PC.GetCurrentMountID())
  end
  return PC.FootShoulder()
end

---------------------------------------------------------------------------------------
-- Shoulder driver
---------------------------------------------------------------------------------------
-- { from, to, elapsed (negative while delayed), duration, current } for eases, or
-- { path, final, elapsed, current } while playing a dismount path.
local fade = nil
local driver
local RAW_TEST_HOLD = 1.4 -- s the mounted offset is kept after a raw-test dismount
-- Dismount made the usual way: { to, untilT } while the game still uses the mounted
-- camera; the server's confirmation (MOUNT_CONFIRMED) drops the offset to `to`.
local pendingSwitch = nil
local SWITCH_TIMEOUT = 0.6 -- no confirmation by then: ease to the on-foot offset anyway

-- WoW bug (corrected the same way by CameraOverShoulderFix and W2UI): with the mounted
-- camera, a negative offset moves the camera about ten times as far as the same positive
-- one, so a custom -1 looked like +8-10. SteadyCam's values stay symmetric; negative ones
-- are written a tenth as large while the game uses the mounted camera (mounted, or
-- dismounting until the server confirms).
local NEGATIVE_MOUNTED_GAIN = 10

local function MountedCamera()
  return pendingSwitch ~= nil or (_G.IsMounted and _G.IsMounted()) or false
end

--- SteadyCam's offset → the value the game needs, and back.
local function ToGame(value)
  if value < 0 and MountedCamera() then
    return value / NEGATIVE_MOUNTED_GAIN
  end
  return value
end
local function FromGame(value)
  if value and value < 0 and MountedCamera() then
    return value * NEGATIVE_MOUNTED_GAIN
  end
  return value
end
PC.ShoulderToGame = ToGame -- for the tests

local function WriteShoulder(value)
  SetIfChanged(CV.SHOULDER, ToGame(PC.Clamp(value, -SHOULDER_LIMIT, SHOULDER_LIMIT)))
end

--- Move the shoulder offset to `target`: hold for `delay`, then ease over `duration`.
--- Both 0 = instant.
function PC.MoveShoulder(target, delay, duration)
  delay, duration = delay or 0, duration or 0
  local current = fade and fade.current or FromGame(ReadNumber(CV.SHOULDER)) or target
  if delay <= 0 and duration <= 0 then
    fade = nil
    WriteShoulder(target)
    return
  end
  fade = {
    from = current,
    to = target,
    elapsed = -delay,
    duration = math.max(duration, 0.001),
    current = current,
  }
  driver:Show()
end

--- Play a dismount path (shoulder every Analysis.SAMPLE_DT from now), then hold `final`.
function PC.PlayShoulderPath(path, final)
  fade = { path = path, final = final, elapsed = 0, current = path[1] }
  WriteShoulder(path[1])
  driver:Show()
end

local function DriverUpdate(self, elapsed)
  if pendingSwitch and GetTime() > pendingSwitch.untilT then
    local to = pendingSwitch.to
    pendingSwitch = nil
    PC.Debug("dismount: no confirmation from the server, easing to the on-foot offset")
    PC.MoveShoulder(to, 0, 0.15)
  end
  if not fade then
    if not pendingSwitch then
      self:Hide()
    end
    return
  end
  fade.elapsed = fade.elapsed + elapsed
  if fade.path then
    local done = fade.elapsed >= (#fade.path - 1) * PC.Analysis.SAMPLE_DT
    fade.current = done and fade.final or PC.Analysis.PathValue(fade.path, fade.elapsed, fade.final)
    WriteShoulder(fade.current)
    if done then
      fade = nil
      self:Hide()
    end
    return
  end
  if fade.elapsed < 0 then
    return -- holding the mounted offset (dismount delay)
  end
  local u = math.min(1, fade.elapsed / fade.duration)
  fade.current = fade.from + (fade.to - fade.from) * PC.Smoothstep(u)
  WriteShoulder(fade.current)
  if u >= 1 then
    fade = nil
    self:Hide()
  end
end

---------------------------------------------------------------------------------------
-- Calibration hold: a constant shoulder through mount swaps, so X = -G·hold measures
-- the game alone (KNOWLEDGE.md §5). nil releases it and re-applies your framing.
---------------------------------------------------------------------------------------
PC.calibrationHold = nil

--- Temporary vertical framing for a calibration (nil = the player's own values again).
function PC.SetCalibrationPad(value)
  PC.calibrationPad = value
  PC.ApplyStaticCVars()
end

function PC.SetCalibrationHold(value)
  PC.calibrationHold = value
  pendingSwitch = nil
  if value then
    fade = nil
    WriteShoulder(value)
  else
    PC.ApplyFraming()
  end
end

---------------------------------------------------------------------------------------
-- Apply
---------------------------------------------------------------------------------------
local framingWasActive = nil -- nil until the first apply

--- Static CVars (pitch, pads, motion-sickness gates). When framing turns off, the
--- player's own values come back once (never re-applied after that, so manual camera
--- changes made while SteadyCam is off are kept).
function PC.ApplyStaticCVars()
  if not PC.FramingActive() then
    if framingWasActive then
      PC.RestoreSnapshot()
    end
    framingWasActive = false
    return
  end
  if framingWasActive == false then
    PC.CaptureSnapshot() -- first activation this session after being off
  end
  framingWasActive = true
  local s = PC.db.settings
  SetIfChanged(CV.KEEP_CENTERED, 0)
  SetIfChanged(CV.REDUCE_MOVEMENT, 0)
  SetIfChanged(CV.PAD_DOWNSCALE, PAD_DOWNSCALE)
  SetIfChanged(CV.PIVOT_CUTOFF, PIVOT_CUTOFF)
  -- Pads first: the game lags pad changes itself, so no tween is needed (and a pad
  -- written before enabling pitch avoids a visible jump).
  -- 0 and 1 exactly are ignored by the game (the framing snaps back to its default).
  -- During a calibration of a big mount both pads can be lowered for a while
  -- (PC.SetCalibrationPad) so the chat bubble stays in view; it doesn't change what is
  -- measured (KNOWLEDGE.md §4: the pad leaves the size factor alone).
  local override = PC.calibrationPad
  SetIfChanged(CV.PAD, PC.Clamp(override or s.footPitch, 0.05, 0.95))
  SetIfChanged(CV.PAD_FLYING, PC.Clamp(override or s.flyingPitch, 0.05, 0.95))
  SetIfChanged(CV.PITCH, s.dynamicPitch and 1 or 0)
end

---------------------------------------------------------------------------------------
-- Camera turn speed (mouse look / dragging the camera)
---------------------------------------------------------------------------------------
-- settings.turnSpeed is a percentage of the game's default (100 out of the box; nil =
-- leave the game's value alone). The player's own vertical / horizontal balance is kept
-- (settings.turnPitchRatio, from their speeds before SteadyCam). When the speed changes
-- in the game's own options (Conflicts.lua notices), SteadyCam stops writing it
-- (settings.turnSpeedFromGame): the slider shows the game's value, dimmed, and touching
-- the slider hands the speed back to SteadyCam.
local TURN_DEFAULT_FALLBACK = 180

local function TurnSpeedDefault()
  local get = C_CVar.GetCVarDefault
  local value = get and tonumber(get(CV.YAW_SPEED))
  return (value and value > 0) and value or TURN_DEFAULT_FALLBACK
end

--- Current turn speed as % of the game's default (the live value when the game sets it).
function PC.GetTurnSpeed()
  local s = PC.db.settings
  if s.turnSpeed and not s.turnSpeedFromGame then
    return s.turnSpeed
  end
  local live = ReadNumber(CV.YAW_SPEED) or TurnSpeedDefault()
  return live / TurnSpeedDefault() * 100
end

function PC.SetTurnSpeed(percent)
  local s = PC.db.settings
  s.turnSpeedFromGame = nil -- SteadyCam sets it again
  if not s.turnPitchRatio then
    local yaw, pitch = ReadNumber(CV.YAW_SPEED), ReadNumber(CV.PITCH_SPEED)
    s.turnPitchRatio = (yaw and pitch and yaw > 0) and PC.Clamp(pitch / yaw, 0.25, 2) or 0.5
  end
  PC.SetSetting("turnSpeed", percent)
end

--- The game's own Mouse Look Speed (or another addon) changed the speed: leave it to the
--- game, and show it (dimmed) on the slider until the player takes it back.
function PC.TurnSpeedFromGame()
  PC.db.settings.turnSpeedFromGame = true
  PC.Fire("TURN_SPEED_GAME")
end

local turnWritten = false -- SteadyCam's speed is in the CVars (to undo when it turns off)

local function ApplyTurnSpeed()
  local s = PC.db.settings
  if not PC.IsActive() then
    -- Turned off: give the player's own speed back (the framing restore skips it while
    -- Motion Sickness Protection is on, so it is done here, once).
    local snap = PC.db.priorCVars
    if turnWritten and snap and not s.turnSpeedFromGame then
      for _, name in ipairs({ CV.YAW_SPEED, CV.PITCH_SPEED }) do
        if snap[name] then
          C_CVar.SetCVar(name, snap[name])
          if PC.NoteWrite then
            PC.NoteWrite(name, snap[name])
          end
        end
      end
    end
    turnWritten = false
    return
  end
  if not s.turnSpeed or s.turnSpeedFromGame then
    return
  end
  PC.CaptureSnapshot() -- the player's own speed is remembered before the first write
  if not s.turnPitchRatio then
    -- Keep the player's own vertical / horizontal balance (as it was before SteadyCam).
    local snap = PC.db.priorCVars or {}
    local yaw, pitch = tonumber(snap[CV.YAW_SPEED]), tonumber(snap[CV.PITCH_SPEED])
    s.turnPitchRatio = (yaw and pitch and yaw > 0) and PC.Clamp(pitch / yaw, 0.25, 2) or 0.5
  end
  local yaw = TurnSpeedDefault() * s.turnSpeed / 100
  turnWritten = true
  SetIfChanged(CV.YAW_SPEED, yaw)
  SetIfChanged(CV.PITCH_SPEED, yaw * (s.turnPitchRatio or 0.5))
end

--- Settings changed or login: apply everything for the current state, instantly (so
--- sliders preview live), and pre-compute the next dismount's timing.
function PC.ApplyFraming()
  PC.ApplyStaticCVars()
  -- After the static CVars: with Motion Sickness Protection on they restore the
  -- snapshot, but the turn speed has nothing to do with motion sickness.
  ApplyTurnSpeed()
  pendingSwitch = nil
  if not PC.FramingActive() then
    fade = nil
    return
  end
  if PC.calibrationHold then
    WriteShoulder(PC.calibrationHold)
    return
  end
  PC.MoveShoulder(PC.CurrentShoulderTarget(), 0, 0)
end

PC.On("MOUNT_SWAP", function(mounted, mountID, confirmed)
  if not PC.FramingActive() or PC.calibrationHold then
    return
  end
  local s = PC.db.settings
  pendingSwitch = nil
  if mounted then
    local target = PC.MountedShoulder(mountID)
    PC.lastSwapInfo = { mountID = mountID, zoom = GetCameraZoom(), kind = "instant" }
    PC.MoveShoulder(target, 0, s.mountTransitionTime)
    PC.Debug(string.format("mount %s → shoulder %.2f", tostring(mountID), target))
    return
  end
  local to = PC.FootShoulder()
  if PC.testRaw then
    -- /steady test raw: keep the mounted offset while the game moves the camera alone.
    PC.lastSwapInfo = { mountID = mountID, zoom = GetCameraZoom(), kind = "raw" }
    PC.MoveShoulder(to, RAW_TEST_HOLD, 0.3)
    return
  end
  -- The game smooths the screen itself (KNOWLEDGE.md §4), so steps are what keep the
  -- character still: one for the gain the game uses until the server confirms, one for
  -- the on-foot camera after.
  local zoom = GetCameraZoom()
  if confirmed or type(mountID) ~= "number" then
    PC.lastSwapInfo = { mountID = mountID, zoom = zoom, kind = "instant", inAir = PC.dismountedInAir }
    PC.MoveShoulder(to, 0, 0)
    PC.Debug(string.format("dismount %s confirmed → shoulder %.2f", tostring(mountID), to))
    return
  end
  local from = PC.MountedShoulder(mountID)
  local h = PC.Profiles.GetDipGain(mountID)
  local hold = PC.Clamp(from / h, -SHOULDER_LIMIT, SHOULDER_LIMIT)
  PC.lastSwapInfo = { mountID = mountID, zoom = zoom, kind = "step", dipGain = h, inAir = PC.dismountedInAir }
  -- Set first: the game still uses the mounted camera, and the hold is written for it.
  pendingSwitch = { to = to, untilT = GetTime() + SWITCH_TIMEOUT }
  PC.MoveShoulder(hold, 0, 0)
  driver:Show()
  PC.Debug(string.format("dismount %s → shoulder %.2f (gain %.2f) until the server confirms", tostring(mountID), hold, h))
end)

-- The server confirmed the dismount: the game switches to the on-foot camera now.
PC.On("MOUNT_CONFIRMED", function()
  if not pendingSwitch then
    return
  end
  local to = pendingSwitch.to
  pendingSwitch = nil
  PC.MoveShoulder(to, 0, 0)
  PC.Debug(string.format("dismount confirmed → shoulder %.2f", to))
end)

-- The journal can report the mount a few frames after the swap: re-aim (the game
-- smooths the change) so "Same as on foot" uses that mount's ratio.
PC.On("MOUNT_IDENTIFIED", function(mountID)
  if PC.FramingActive() and not PC.calibrationHold and PC.db.settings.mountedMode == "match" then
    PC.MoveShoulder(PC.MountedShoulder(mountID), 0, 0)
  end
end)

function PC.InitCamera()
  driver = CreateFrame("Frame", "SteadyCamShoulderDriver")
  driver:Hide()
  driver:SetScript("OnUpdate", DriverUpdate)
  sessionKey = PC.GetModelKey()
  if not PC.db.settings.footOffsetKey then
    RememberFootKey()
  end
  -- A form change on foot (Soar's dragon form, worgen ↔ human): re-aim in the same
  -- frame as the model swap; the game eases the screen itself.
  local forms = CreateFrame("Frame")
  pcall(forms.RegisterUnitEvent, forms, "UNIT_MODEL_CHANGED", "player")
  pcall(forms.RegisterEvent, forms, "UPDATE_SHAPESHIFT_FORM")
  local lastKey = PC.GetModelKey()
  forms:SetScript("OnEvent", function()
    local key = PC.GetModelKey()
    if key == lastKey then
      return
    end
    lastKey = key
    if PC.FramingActive() and not PC.calibrationHold and not PC.IsMountedOrInVehicle() then
      PC.MoveShoulder(PC.FootShoulder(), 0, 0)
      PC.Debug(string.format("form change → %s, shoulder %.2f", key, PC.FootShoulder()))
    end
  end)
end
