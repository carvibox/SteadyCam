---------------------------------------------------------------------------------------
--  Core/Recorder.lua — per-frame samples during calibration
---------------------------------------------------------------------------------------
--  Runs for the whole calibration so a capture can include the moments before the click
--  (the previous bubble may still be up). R.Capture{...} watches for the next mount swap
--  and hands back samples with t relative to the swap:
--    { t, x, y (probe), sh (shoulder CVar), zoom, mounted, wx, wy, speed }
--  plus the mount-related events seen meanwhile ({ t, e = name, a = spellID }), and
--  calls to Dismount() / C_MountJournal.Dismiss() — to tell how a dismount was made.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local CreateFrame = _G.CreateFrame
local GetCameraZoom = _G.GetCameraZoom
local GetTime = _G.GetTime
local GetUnitSpeed = _G.GetUnitSpeed
local UnitPosition = _G.UnitPosition
local hooksecurefunc = _G.hooksecurefunc
local issecretvalue = _G.issecretvalue

local R = {}
PC.Recorder = R

local PRE_ROLL = 0.6 -- seconds of history copied into a capture at the click
local WAIT_KEEP = 4 -- seconds kept while a capture waits a long time for its swap
local HISTORY_MAX = 600

local frame
local history = {}
local capture -- { clickAt, swapAt, swapMounted, after, timeout, samples, onDone }

local EVENT_MAX = 400
local events = {} -- { t, e, a } while the recorder runs
local eventFrame
local WORLD_EVENTS = {
  "PLAYER_MOUNT_DISPLAY_CHANGED",
  "COMPANION_UPDATE",
  "UPDATE_SHAPESHIFT_FORM",
  "PLAYER_CONTROL_LOST",
  "PLAYER_CONTROL_GAINED",
}
local PLAYER_EVENTS = {
  "UNIT_AURA",
  "UNIT_MODEL_CHANGED",
  "UNIT_FLAGS",
  "UNIT_SPELLCAST_SENT",
  "UNIT_SPELLCAST_START",
  "UNIT_SPELLCAST_SUCCEEDED",
}

local function Plain(v)
  if v == nil or (issecretvalue and issecretvalue(v)) then
    return v ~= nil and "secret" or nil
  end
  local kind = type(v)
  if kind == "number" or kind == "string" or kind == "boolean" then
    return tostring(v)
  end
  return nil
end

local function LogEvent(name, arg)
  if not (frame and frame:IsShown()) then
    return
  end
  events[#events + 1] = { t = GetTime(), e = name, a = arg }
  if #events > EVENT_MAX then
    table.remove(events, 1)
  end
  -- Captures can also start on a form / model / control change (shapeshift, taxi...).
  if capture and not capture.swapAt and capture.triggers and capture.triggers[name] then
    capture.swapAt = GetTime()
    capture.trigger = name
  end
end

local function OnEvent(_, event, ...)
  local arg
  if event == "UNIT_SPELLCAST_SENT" then
    arg = Plain(select(4, ...))
  elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
    arg = Plain(select(3, ...))
  end
  LogEvent(event, arg)
end

if hooksecurefunc then
  pcall(function()
    if _G.Dismount then
      hooksecurefunc("Dismount", function()
        LogEvent("Dismount()")
      end)
    end
    if _G.C_MountJournal and _G.C_MountJournal.Dismiss then
      hooksecurefunc(_G.C_MountJournal, "Dismiss", function()
        LogEvent("Dismiss()")
      end)
    end
    if _G.C_MountJournal and _G.C_MountJournal.SummonByID then
      hooksecurefunc(_G.C_MountJournal, "SummonByID", function(id)
        LogEvent("SummonByID()", Plain(id))
      end)
    end
  end)
end

local function Num(v)
  if v == nil or (issecretvalue and issecretvalue(v)) or type(v) ~= "number" then
    return nil
  end
  return v
end

local function TakeSample(now)
  local x, y = PC.Probe.Read()
  local okPos, wy, wx = pcall(UnitPosition, "player")
  local s = {
    t = now,
    x = x,
    y = y,
    sh = tonumber(C_CVar.GetCVar("test_cameraOverShoulder")),
    zoom = GetCameraZoom(),
    mounted = PC.IsMountedOrInVehicle(),
    wx = okPos and Num(wx) or nil,
    wy = okPos and Num(wy) or nil,
    speed = GetUnitSpeed and Num(GetUnitSpeed("player")) or 0,
  }
  history[#history + 1] = s
  if #history > HISTORY_MAX then
    local keep = {}
    for i = #history - HISTORY_MAX / 2 + 1, #history do
      keep[#keep + 1] = history[i]
    end
    history = keep
  end
  return s
end

local function Finish(ok, reason)
  local c = capture
  capture = nil
  if not c then
    return
  end
  local samples = {}
  local zero = c.swapAt or c.clickAt
  for _, s in ipairs(c.samples) do
    local copy = {}
    for k, v in pairs(s) do
      copy[k] = v
    end
    copy.t = s.t - zero
    samples[#samples + 1] = copy
  end
  local evs = {}
  for _, e in ipairs(events) do
    if e.t >= c.clickAt - PRE_ROLL then
      evs[#evs + 1] = { t = e.t - zero, e = e.e, a = e.a }
    end
  end
  c.onDone({
    ok = ok,
    reason = reason,
    swapMounted = c.swapMounted,
    clickToSwap = c.swapAt and (c.swapAt - c.clickAt) or nil,
    trigger = c.trigger,
    samples = samples,
    events = evs,
  })
end

local function OnUpdate()
  local now = GetTime()
  local s = TakeSample(now)
  if not capture then
    return
  end
  local samples = capture.samples
  samples[#samples + 1] = s
  if not capture.swapAt and #samples > 1000 then
    -- Still waiting (a test can stay armed for minutes): keep the last few seconds.
    local keep = {}
    for i = 1, #samples do
      if samples[i].t >= now - WAIT_KEEP then
        keep[#keep + 1] = samples[i]
      end
    end
    capture.samples = keep
  end
  if capture.swapAt then
    if now - capture.swapAt >= capture.after then
      Finish(true)
    end
  elseif now - capture.clickAt > capture.timeout then
    Finish(false, "noswap")
  end
end

PC.On("MOUNT_SWAP", function(mounted)
  if capture and not capture.swapAt and not (capture.dismountOnly and mounted) then
    capture.swapAt = GetTime()
    capture.swapMounted = mounted
  end
end)

--- Start recording in the background (calibration running).
function R.Begin()
  if not frame then
    frame = CreateFrame("Frame", "SteadyCamRecorder")
    frame:SetScript("OnUpdate", OnUpdate)
  end
  history = {}
  events = {}
  PC.Probe.Reset()
  frame:Show()
  if not eventFrame then
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", OnEvent)
  end
  for _, e in ipairs(WORLD_EVENTS) do
    pcall(eventFrame.RegisterEvent, eventFrame, e)
  end
  for _, e in ipairs(PLAYER_EVENTS) do
    if eventFrame.RegisterUnitEvent then
      pcall(eventFrame.RegisterUnitEvent, eventFrame, e, "player")
    else
      pcall(eventFrame.RegisterEvent, eventFrame, e)
    end
  end
end

function R.End()
  capture = nil
  if frame then
    frame:Hide()
  end
  if eventFrame and eventFrame.UnregisterAllEvents then
    eventFrame:UnregisterAllEvents()
  end
end

--- Watch for the next mount swap. opts: after (s recorded after the swap), timeout (s
--- to wait for the swap), dismountOnly (ignore mounting), onDone(result).
function R.Capture(opts)
  local now = GetTime()
  local samples = {}
  for _, s in ipairs(history) do
    if s.t >= now - PRE_ROLL then
      samples[#samples + 1] = s
    end
  end
  capture = {
    clickAt = now,
    after = opts.after,
    timeout = opts.timeout,
    dismountOnly = opts.dismountOnly,
    triggers = opts.triggers,
    samples = samples,
    onDone = opts.onDone,
  }
end

function R.Cancel()
  capture = nil
end

function R.IsCapturing()
  return capture ~= nil
end
