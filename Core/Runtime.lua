---------------------------------------------------------------------------------------
--  Core/Runtime.lua — lifecycle, coexistence, slash commands
---------------------------------------------------------------------------------------
--  ADDON_LOADED → database; PLAYER_LOGIN → detect DynamicCam / Combat Mode, snapshot
--  CVars, start the watchers, apply framing, first-run onboarding; PLAYER_ENTERING_WORLD
--  → re-apply (zoning and other addons can touch camera CVars).
--  Coexistence: DynamicCam writes the same CVars. SteadyCam keeps working and says so at
--  login (chat link + window button to disable DynamicCam and reload).
--  Combat Mode (local build) relinquishes shoulder / pitch / motion-sickness CVars when
--  it sees SteadyCam loaded.
---------------------------------------------------------------------------------------
local addonName, PC = ...
local _G = _G

local C_AddOns = _G.C_AddOns
local C_Timer = _G.C_Timer
local CreateFrame = _G.CreateFrame

local L = PC.L

local function IsLoaded(name)
  return C_AddOns and C_AddOns.IsAddOnLoaded(name) and true or false
end

PC.On("SETTINGS_CHANGED", function()
  PC.ApplyFraming()
end)

-- Public, read-only answers for other addons. Combat Mode delegates its camera options to
-- SteadyCam and asks here, e.g. whether Motion Sickness Protection is on (it gates
-- Combat Mode's Focus Locked Target).
_G.SteadyCamAPI = {
  version = 1,
  IsActive = function()
    return PC.db ~= nil and PC.IsActive() and true or false
  end,
  RespectsMotionSickness = function()
    return PC.db ~= nil and PC.db.settings.respectMotionSickness == true
  end,
}

local DISABLE_DC_LINK ="|Haddon:steadycam:disabledc|h|cff69ccf0[%s]|r|h"

--- Turn DynamicCam off (it writes the same camera CVars) and reload so it unloads.
function PC.DisableDynamicCam()
  if C_AddOns and C_AddOns.DisableAddOn then
    C_AddOns.DisableAddOn("DynamicCam")
  end
  if _G.ReloadUI then
    _G.ReloadUI()
  end
end

--- Ask in the game's own dialog (like a group invite). onAccept runs on "Yes".
local CONFIRM = "STEADYCAM_CONFIRM"
function PC.Confirm(text, onAccept)
  local dialogs, show = _G.StaticPopupDialogs, _G.StaticPopup_Show
  if not (dialogs and show) then
    onAccept()
    return
  end
  dialogs[CONFIRM] = dialogs[CONFIRM] or {
    text = "%s",
    button1 = _G.YES or "Yes",
    button2 = _G.NO or "No",
    OnAccept = function(_, data)
      if type(data) == "function" then
        data()
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  show(CONFIRM, text, nil, onAccept)
end

-- The game's own confirmation dialog (like deleting an item or a group invite).
local POPUP = "STEADYCAM_DISABLE_DYNAMICCAM"

--- Ask, in a game dialog, to disable DynamicCam. Falls back to a chat line with a link.
function PC.ShowDynamicCamPopup()
  local dialogs, show = _G.StaticPopupDialogs, _G.StaticPopup_Show
  if not (dialogs and show) then
    PC.Print(L.DYNAMICCAM .. " " .. string.format(DISABLE_DC_LINK, L.DISABLE_DYNAMICCAM))
    return
  end
  dialogs[POPUP] = dialogs[POPUP] or {
    text = "SteadyCam\n\n" .. L.DYNAMICCAM .. "\n\n" .. L.RELOAD_NOTE,
    button1 = L.DISABLE_SHORT,
    button2 = L.NOT_NOW,
    OnAccept = function()
      PC.DisableDynamicCam()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3, -- a slot Blizzard's own dialogs rarely use (avoids taint)
  }
  show(POPUP)
end

local popupWaitsForCombat = false

local function AskAboutDynamicCam()
  if _G.InCombatLockdown and _G.InCombatLockdown() then
    popupWaitsForCombat = true -- don't interrupt a fight; ask when it ends
    return
  end
  PC.ShowDynamicCamPopup()
end

local function OnLogin()
  PC.dynamicCamLoaded = IsLoaded("DynamicCam")
  PC.combatModeLoaded = IsLoaded("CombatMode")
  if PC.dynamicCamLoaded then
    C_Timer.After(3, AskAboutDynamicCam)
  end
  if PC.combatModeLoaded then
    PC.Print(L.COMBATMODE)
  end

  PC.InitCamera()
  PC.Profiles.Init()
  PC.StartMountWatcher()
  PC.cameraReady = true
  if PC.IsActive() then
    PC.CaptureSnapshot()
  end
  PC.ApplyFraming()

  if not PC.db.settings.onboardingSeen then
    C_Timer.After(2, function()
      if PC.OpenWindow then
        PC.OpenWindow()
      end
    end)
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_REGEN_ENABLED" then
    if popupWaitsForCombat then
      popupWaitsForCombat = false
      PC.ShowDynamicCamPopup()
    end
    return
  end
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      PC.InitDatabase()
    end
  elseif event == "PLAYER_LOGIN" then
    OnLogin()
  elseif event == "PLAYER_ENTERING_WORLD" then
    if PC.cameraReady then
      PC.ApplyFraming()
    end
  end
end)

_G.SLASH_STEADYCAM1 = "/steady"
_G.SLASH_STEADYCAM2 = "/steadycam"
_G.SlashCmdList.STEADYCAM = function(msg)
  -- Players only need the window. The measuring tools stay for development and only
  -- answer with "Debug messages" on (Advanced).
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
  if cmd == "test" and not PC.db.settings.debug then
    PC.Print(L.TEST_NEEDS_DEBUG)
  elseif cmd == "test" then
    local ok
    if arg == "limit" then
      ok = PC.Calibration.StartLimitTest()
      PC.Print(ok and L.TEST_ARMED_LIMIT or L.TEST_BUSY_LIMIT)
      return
    elseif arg == "form" then
      ok = PC.Calibration.StartFormTest()
      PC.Print(ok and L.TEST_ARMED_FORM or L.TEST_BUSY)
      return
    end
    if PC.Calibration.StartTest(arg == "raw") then
      PC.Print(arg == "raw" and L.TEST_ARMED_RAW or L.TEST_ARMED)
    else
      PC.Print(L.TEST_BUSY)
    end
    return
  end
  if PC.ToggleWindow then
    PC.ToggleWindow()
  end
end
