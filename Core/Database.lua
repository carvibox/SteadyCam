---------------------------------------------------------------------------------------
--  Core/Database.lua — saved settings and calibration store
---------------------------------------------------------------------------------------
--  SteadyCamDB (account-wide):
--    settings  — the four visible framing values + hidden advanced options
--    models    — calibration per character model ("<raceFile>-<M|F>"):
--                models[key].mounts[mountID] = { name, ratio, captures, calibratedAt }
--    priorCVars — camera CVars as they were before SteadyCam first touched them
--  Framing is account-wide (one camera taste); calibration is per race + sex because
--  the character model changes how the game frames you (KNOWLEDGE.md §5).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

-- SteadyCam's recommended framing: what it ships with, and what the "Recommended values"
-- button (Advanced) puts back. ("Restore Blizzard camera" is the game's own camera.)
local R = {
  footOffset = 0.8,
  footPitch = 0.7,
  mountedMode = "match",
  flyingPitch = 0.6,
  turnSpeed = 100,
}
PC.Recommended = R

PC.Defaults = {
  settings = {
    enabled = true,
    -- Step 1 · on foot (recommended values: PC.Recommended below)
    footOffset = R.footOffset, -- test_cameraOverShoulder
    footPitch = R.footPitch, -- test_cameraDynamicPitchBaseFovPad (Blizzard: 0.4)
    -- Step 2 · mounted
    mountedMode = R.mountedMode, -- "match" | "center" | "custom"
    mountedOffset = 2.5, -- only used by "custom"
    flyingPitch = R.flyingPitch, -- test_cameraDynamicPitchBaseFovPadFlying (Blizzard: 0.75)
    turnSpeed = R.turnSpeed, -- camera turn speed, % of the game's default
    -- turnPitchRatio (vertical / horizontal turn speed) is taken from the player's own
    -- speeds the first time the slider is moved; until then the game's 1/2.
    -- Advanced (hidden by default)
    dynamicPitch = true,
    respectMotionSickness = false,
    mountTransitionTime = 0, -- the game already smooths the offset on mount
    onboardingSeen = false,
    showAdvanced = false,
    research = false, -- research mode: measure each race (Core/Research.lua)
    notifyUncalibrated = false, -- chat link when you ride an uncalibrated mount (opt-in: calibration is optional)
    mountFilter = "favorites", -- calibration picker: "favorites" | "usable" | "all"
    debug = false,
  },
  models = {},
  mountUse = {},
  research = {}, -- { mountID = reference mount } -- [mountID] = times ridden (the picker lists your most used first)
  priorCVars = nil,
}

local function MergeDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if type(v) == "table" then
      if type(target[k]) ~= "table" then
        target[k] = {}
      end
      MergeDefaults(target[k], v)
    elseif target[k] == nil then
      target[k] = v
    end
  end
  return target
end

function PC.InitDatabase()
  _G.SteadyCamDB = _G.SteadyCamDB or {}
  local db = MergeDefaults(_G.SteadyCamDB, PC.Defaults)
  -- Options of the old timed dismount (replaced by the measured two-step plan).
  db.settings.dismountAuto, db.settings.dismountDelay, db.settings.dismountTime = nil, nil, nil
  db.lastTests = nil
  -- v1.0: the "not calibrated" chat notice became opt-in. Saves from earlier builds stored
  -- the old default (on); switch it off once, then it is the player's choice again.
  if not db.notifyOptIn then
    db.settings.notifyUncalibrated = false
    db.notifyOptIn = true
  end
  PC.db = db
  return db
end

-- Dracthyr (dragon / visage) and worgen (worgen / human) switch between two models: the
-- dracthyr's dragon form gets bigger mounts, its visage doesn't (game tables, 12.1).
local function InAlternateForm()
  local get = _G.C_PlayerInfo and _G.C_PlayerInfo.GetAlternateFormInfo
  if not get then
    return false
  end
  local ok, hasAlt, inAlt = pcall(get)
  return ok and hasAlt and inAlt and true or false
end

--- Model key for calibration data: race file + sex, e.g. "Human-M", "Tauren-F", plus
--- "-Alt" in a dracthyr's / worgen's alternate form ("Dracthyr-M-Alt").
function PC.GetModelKey()
  local _, raceFile = UnitRace("player")
  local sex = UnitSex("player")
  local key = (raceFile or "Unknown") .. "-" .. (sex == 3 and "F" or "M")
  return InAlternateForm() and (key .. "-Alt") or key
end

--- Localized race name plus sex, for the status line.
function PC.GetModelLabel()
  local race = UnitRace("player") or "?"
  local sex = UnitSex("player")
  local sexLabel = sex == 3 and (_G.FEMALE or "Female") or (_G.MALE or "Male")
  return race .. " (" .. sexLabel .. (InAlternateForm() and (", " .. PC.L.FORM_ALT) or "") .. ")"
end

--- Calibration store for the current model (created on demand).
function PC.GetModelStore()
  local key = PC.GetModelKey()
  local models = PC.db.models
  models[key] = models[key] or { mounts = {} }
  return models[key]
end

function PC.SetSetting(key, value)
  PC.db.settings[key] = value
  PC.Fire("SETTINGS_CHANGED", key, value)
end

--- Restore / Recommended / Load change the camera under a running calibration: end it.
local function StopCalibration()
  if PC.Calibration and PC.Calibration.IsRunning() then
    PC.Calibration.Cancel()
  end
end

--- "Restore Blizzard camera": SteadyCam's values set to what the game does on its own —
--- camera centered, no vertical framing (pads at the game's defaults), the game's turn
--- speed and balance. SteadyCam stays on, so the player can start again from there.
function PC.ApplyGameCamera()
  local get = _G.C_CVar.GetCVarDefault
  local function Default(name, fallback)
    local value = get and tonumber(get(name))
    return value or fallback
  end
  StopCalibration()
  local s = PC.db.settings
  s.turnSpeedFromGame = nil
  local yaw, pitch = Default("cameraYawMoveSpeed", 180), Default("cameraPitchMoveSpeed", 90)
  s.turnPitchRatio = yaw > 0 and pitch / yaw or 0.5
  PC.SetSetting("mountedMode", "center")
  PC.SetSetting("footOffset", 0)
  PC.SetSetting("footPitch", Default("test_cameraDynamicPitchBaseFovPad", 0.4))
  PC.SetSetting("flyingPitch", Default("test_cameraDynamicPitchBaseFovPadFlying", 0.75))
  PC.SetSetting("dynamicPitch", Default("test_cameraDynamicPitch", 0) == 1)
  if PC.SetTurnSpeed then
    PC.SetTurnSpeed(100)
  end
end

-- "Save my preferences": a copy of the framing choices in the main window.
local PREF_KEYS = { "turnSpeed", "footOffset", "footPitch", "dynamicPitch", "mountedMode", "mountedOffset",
  "flyingPitch" }

--- A setting as the player sees it: the turn speed is the one in use (also when the
--- game's own options set it), on the slider's 5% steps.
local function PrefValue(key)
  if key == "turnSpeed" and PC.GetTurnSpeed then
    return math.floor(PC.GetTurnSpeed() / 5 + 0.5) * 5
  end
  return PC.db.settings[key]
end

function PC.SavePreferences()
  local saved = {}
  for _, key in ipairs(PREF_KEYS) do
    saved[key] = PrefValue(key)
  end
  saved.footOffsetKey = PC.db.settings.footOffsetKey -- the form the on-foot offset was set in
  PC.db.savedPrefs = saved
  PC.Fire("PREFS_SAVED")
end

--- Bring back the saved choices (SteadyCam on).
function PC.LoadPreferences()
  local saved = PC.db.savedPrefs
  if type(saved) ~= "table" then
    return false
  end
  StopCalibration()
  PC.SetSetting("enabled", true)
  for _, key in ipairs(PREF_KEYS) do
    if key ~= "turnSpeed" and saved[key] ~= nil then
      PC.SetSetting(key, saved[key])
    end
  end
  if saved.turnSpeed and PC.SetTurnSpeed then
    PC.SetTurnSpeed(saved.turnSpeed)
  end
  if saved.footOffsetKey then
    -- Setting footOffset above stamped the current form; the value belongs to this one.
    PC.db.settings.footOffsetKey = saved.footOffsetKey
    PC.ApplyFraming()
  end
  return true
end

function PC.HasSavedPreferences()
  return type(PC.db.savedPrefs) == "table"
end

--- True when the current choices are exactly the saved ones.
function PC.PreferencesSaved()
  local saved = PC.db.savedPrefs
  if type(saved) ~= "table" then
    return false
  end
  for _, key in ipairs(PREF_KEYS) do
    local a, b = PrefValue(key), saved[key]
    if type(a) == "number" and type(b) == "number" then
      if math.abs(a - b) > 1e-6 then
        return false
      end
    elseif a ~= b then
      return false
    end
  end
  return true
end

--- "Recommended values": SteadyCam on, with its recommended framing and turn speed.
--- (Motion Sickness Protection is the player's call and stays as it is.)
function PC.ApplyRecommended()
  StopCalibration()
  PC.SetSetting("enabled", true)
  PC.SetSetting("dynamicPitch", true) -- vertical framing needs it
  for _, key in ipairs({ "mountedMode", "footPitch", "flyingPitch", "footOffset" }) do
    PC.SetSetting(key, R[key])
  end
  if PC.SetTurnSpeed then
    PC.SetTurnSpeed(R.turnSpeed)
  else
    PC.SetSetting("turnSpeed", R.turnSpeed)
  end
end
