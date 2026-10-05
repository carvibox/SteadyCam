---------------------------------------------------------------------------------------
--  Core/Conflicts.lua — other things moving the same camera settings
---------------------------------------------------------------------------------------
--  SteadyCam writes the shoulder offset and the dynamic-pitch CVars. If another addon (or
--  a macro) writes them too, the two fight and the camera jumps — and the player blames
--  SteadyCam. So: at login, name known camera addons that are loaded; while playing, once
--  a second, check that what SteadyCam wrote is still there and say so (once per session
--  and setting) if something else keeps changing it. Nothing is overwritten back: fighting
--  would make it worse; the player decides.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local GetTime = _G.GetTime

local CHECK_EVERY = 1 -- s
local TOLERANCE = 1e-3
-- Settings the player may change on purpose through the game's own options (motion
-- sickness) are not watched.
local WATCHED = {
  test_cameraOverShoulder = "NAME_SHOULDER",
  test_cameraDynamicPitch = "NAME_PITCH",
  test_cameraDynamicPitchBaseFovPad = "NAME_PAD",
  test_cameraDynamicPitchBaseFovPadFlying = "NAME_PAD_FLYING",
  cameraYawMoveSpeed = "NAME_TURN_SPEED", -- left to the game, not reported (see Check)
}
-- Addons known to drive these settings themselves.
local KNOWN = { "CameraOverShoulderFix", "ActionCamPlus", "ActionCam", "ConsolePort", "BetterCamera" }

local written = {} -- [cvar] = value SteadyCam last wrote
local warned = {}

--- Called by Camera.lua for every write.
function PC.NoteWrite(name, value)
  if WATCHED[name] then
    written[name] = tonumber(value)
  end
end

local function Check()
  if not PC.IsActive or not PC.IsActive() or (PC.Calibration and PC.Calibration.IsRunning()) then
    return
  end
  if PC.dynamicCamLoaded then
    return -- already told at login, with a link to disable it
  end
  for name, want in pairs(written) do
    local cur = tonumber(C_CVar.GetCVar(name))
    if cur and want and math.abs(cur - want) > TOLERANCE then
      if name == "cameraYawMoveSpeed" then
        -- Most likely the game's own Mouse Look Speed option: the player's choice. Leave it
        -- to the game (the slider shows it) instead of writing ours back and blaming an addon.
        PC.TurnSpeedFromGame()
      elseif not warned[name] then
        warned[name] = true
        PC.Print(string.format(PC.L.CONFLICT_CHANGED, PC.L[WATCHED[name]]))
      end
    end
    written[name] = cur -- follow it, so one external change is reported once
  end
end

local function AnnounceKnown()
  local found = {}
  local loaded = _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded
  for _, name in ipairs(KNOWN) do
    if loaded and loaded(name) then
      found[#found + 1] = name
    end
  end
  if #found > 0 then
    PC.Print(string.format(PC.L.CONFLICT_ADDONS, table.concat(found, ", ")))
  end
end

local frame = _G.CreateFrame("Frame")
local since = 0
frame:SetScript("OnUpdate", function(_, elapsed)
  since = since + elapsed
  if since >= CHECK_EVERY then
    since = 0
    Check()
  end
end)
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
  if _G.C_Timer then
    _G.C_Timer.After(4, AnnounceKnown)
  else
    AnnounceKnown()
  end
end)
