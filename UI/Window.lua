---------------------------------------------------------------------------------------
--  UI/Window.lua — the SteadyCam window (onboarding flow)
---------------------------------------------------------------------------------------
--  Status → 1 · On foot → 2 · Mounted → 3 · Calibration, plus a hidden Advanced card.
--  Only the four framing values are visible by default; everything else is automatic.
--  Opens by itself the first time; later from the minimap AddOns button or Esc → Options →
--  AddOns → SteadyCam (/steady also works).
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local CreateFrame = _G.CreateFrame
local UIParent = _G.UIParent

local T, W, L = PC.Theme, PC.Widgets, PC.L

local win, scroll, content
local blocks = {}
local CONTENT_W = T.width - 2 * T.margin
local BLOCK_GAP = 20
local HEADER_TOP, HEADER_H = 20, 40 -- the wordmark: its distance from the top edge, its height

local function S()
  return PC.db.settings
end

local function Set(key)
  return function(value)
    PC.SetSetting(key, value)
  end
end

local function Get(key)
  return function()
    return S()[key]
  end
end

local function FramingOff()
  return not PC.FramingActive()
end

--- Center a fixed-width control in its card.
local function Centered(card, ctrl)
  ctrl.indent = math.floor((card.inner - ctrl:GetWidth()) / 2)
  return ctrl
end

-- Two buttons side by side fill a row: in a card, and in the window's bottom row.
local HALF_CARD = math.floor((CONTENT_W - 2 * T.pad - 12) / 2)
local HALF_ROW = math.floor((CONTENT_W - 16) / 2)

--- Names of the mounts calibrated for this race and sex (any of your characters).
local function CalibratedNames()
  local names = {}
  for _, m in pairs(PC.GetModelStore().mounts) do
    if m.captures and #m.captures > 0 then
      names[#names + 1] = m.name or "?"
    end
  end
  table.sort(names)
  return names
end

--- Mounts in the Calibrated tab of the mounts window (own + same model).
local function CalibratedCount()
  if PC.MountCounts then
    return (PC.MountCounts())
  end
  return #CalibratedNames()
end

local function Relayout()
  if not content then
    return
  end
  local y = 0
  for _, block in ipairs(blocks) do
    if block.Layout then
      block.Layout()
    end
    if block:IsShown() then
      block:ClearAllPoints()
      block:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      y = y + block:GetHeight() + BLOCK_GAP
    end
  end
  content:SetHeight(math.max(1, y))
  if scroll and scroll.UpdateBar then
    scroll.UpdateBar()
  end
end

local function Refresh()
  if win and win:IsShown() then
    W.RefreshAll()
    Relayout()
  end
end

---------------------------------------------------------------------------------------
-- Preview math: where your character's head shows on the screen, measured in game on
-- foot (2026-10-05, 16:9): the horizontal offset moves it 4.6% of the screen width per
-- unit (at a usual zoom; the game scales it with 1/zoom, KNOWLEDGE.md §4), the vertical
-- position 40.8% of the screen height per unit, from 81.9% down at 0. So offset 0.8 /
-- vertical 0.7 → 46% across, 53% down; 2 / 0.95 → 41% across, 43% down.
-- Mounted, "match" keeps the on-foot spot; a custom offset counts as offset / ratio. The
-- mounted vertical reuses the on-foot curve for the flying pad: not measured (KNOWLEDGE.md
-- §8), and it applies only while flying. With dynamic pitch off the game ignores the pads:
-- the head is drawn on the center line, where the game's own camera looks (not measured).
---------------------------------------------------------------------------------------
local SCREEN_X_PER_OFFSET, HEAD_Y_AT_ZERO, HEAD_Y_PER_PITCH = 0.046, 0.819, 0.408
local PITCH_OFF_Y = 0

--- The head's spot as the preview wants it: -1..1 from the screen's center, up positive.
local function OnScreen(offset, pitch)
  local across = 0.5 - SCREEN_X_PER_OFFSET * offset
  local down = HEAD_Y_AT_ZERO - HEAD_Y_PER_PITCH * pitch
  return (across - 0.5) * 2, (0.5 - down) * 2
end
PC.PreviewSpot = OnScreen -- for the tests

local function FootPoint()
  local x, y = OnScreen(S().footOffset, S().footPitch)
  return x, S().dynamicPitch and y or PITCH_OFF_Y
end

local function MountedPoint()
  local s = S()
  local offset = s.footOffset -- the on-foot offset that gives the same spot
  if s.mountedMode == "center" then
    offset = 0
  elseif s.mountedMode == "custom" then
    offset = s.mountedOffset / PC.Profiles.GetRatio(PC.GetCurrentMountID())
  end
  local x, y = OnScreen(offset, s.flyingPitch)
  return x, s.dynamicPitch and y or PITCH_OFF_Y
end
PC.PreviewPoints = function() -- for the tests
  local fx, fy = FootPoint()
  local mx, my = MountedPoint()
  return fx, fy, mx, my
end

---------------------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------------------
local function StatusCard()
  local card = W.Card(content, {}, CONTENT_W)
  card.Add(W.Toggle(card, {
    label = L.ENABLED,
    desc = L.ENABLED_DESC,
    get = Get("enabled"),
    set = Set("enabled"),
  }, card.inner))
  -- What the player has to do: almost nothing. Step names come from the cards below.
  card.Add(W.Callout(card, {
    title = L.HOWTO_TITLE,
    steps = {
      string.format(L.HOWTO_1, "1 · " .. L.STEP1_TITLE),
      string.format(L.HOWTO_2, L.MODE_MATCH, "2 · " .. L.STEP2_TITLE),
    },
    footer = L.HOWTO_3,
  }, card.inner), 16)
  card.Add(W.Paragraph(card, {
    font = "GameFontHighlightSmall",
    color = T.text,
    textFn = function()
      local mountID = PC.GetCurrentMountID()
      local mountText = not PC.IsMountedOrInVehicle() and L.STATUS_ON_FOOT
        or mountID == "taxi" and L.STATUS_TAXI
        or PC.GetMountName(mountID) or "..." -- the journal names it a moment after mounting
      local lines = {
        "|cff8c8c8c" .. L.STATUS_CHARACTER .. ":|r " .. PC.GetModelLabel(),
        "|cff8c8c8c" .. L.STATUS_MOUNT .. ":|r " .. mountText,
      }
      if PC.IsMountedOrInVehicle() and type(mountID) == "number" then
        local kind, extra = PC.Profiles.Describe(mountID)
        local ownCount = #CalibratedNames()
        local profileText = kind == "mount" and L.PROFILE_MOUNT
          or kind == "family" and string.format(L.PROFILE_FAMILY, tostring(extra or "?"))
          or (kind == "builtin" or kind == "scaled") and L.PROFILE_BUILTIN
          or kind == "estimated" and L.PROFILE_ESTIMATED
          -- "average of your N mounts" only when N are really yours (else shipped data)
          or kind == "average" and (ownCount > 0 and string.format(L.PROFILE_AVERAGE, ownCount)
            or L.PROFILE_BUILTIN)
          or L.PROFILE_REFERENCE
        lines[#lines + 1] = "|cff8c8c8c" .. L.STATUS_PROFILE .. ":|r " .. profileText
      end
      if PC.dynamicCamLoaded then
        lines[#lines + 1] = "|cffdb6161" .. L.DYNAMICCAM .. "|r"
      end
      return table.concat(lines, "\n")
    end,
  }, card.inner), 20)
  card.Add(W.Button(card, {
    text = L.DISABLE_DYNAMICCAM,
    primary = true,
    shown = function()
      return PC.dynamicCamLoaded
    end,
    onClick = PC.ShowDynamicCamPopup,
  }, 260), 20)
  card.Add(W.Slider(card, {
    label = L.TURN_SPEED,
    desc = L.TURN_SPEED_DESC,
    min = 10,
    max = 200,
    step = 5,
    default = 100,
    format = "%.0f%%",
    leftText = L.SLOWER,
    rightText = L.FASTER,
    get = PC.GetTurnSpeed,
    set = PC.SetTurnSpeed,
    muted = function()
      return S().turnSpeedFromGame
    end,
    mutedDesc = L.TURN_SPEED_GAME,
    disabled = function()
      return not PC.IsActive()
    end,
  }, card.inner), 8)
  return card
end

local function FootCard()
  local card = W.Card(content, { number = 1, title = L.STEP1_TITLE, desc = L.STEP1_DESC }, CONTENT_W)
  card.Add(Centered(card, W.Preview(card, { point = FootPoint, caption = L.STEP1_TITLE, disabled = FramingOff })))
  card.Add(W.Slider(card, {
    label = L.FOOT_OFFSET,
    desc = L.FOOT_OFFSET_DESC,
    min = -2,
    max = 2,
    step = 0.05,
    default = PC.Recommended.footOffset,
    leftText = "< " .. L.LEFT,
    centerText = L.CENTER,
    rightText = L.RIGHT .. " >",
    get = Get("footOffset"),
    set = Set("footOffset"),
    disabled = FramingOff,
  }, card.inner))
  card.Add(W.Slider(card, {
    label = L.FOOT_PITCH,
    desc = L.FOOT_PITCH_DESC,
    min = 0.05,
    max = 0.95,
    step = 0.05,
    default = PC.Recommended.footPitch,
    leftText = L.LOWER,
    rightText = L.HIGHER,
    get = Get("footPitch"),
    set = function(v)
      if not S().dynamicPitch then
        PC.SetSetting("dynamicPitch", true) -- vertical framing needs it
      end
      PC.SetSetting("footPitch", v)
    end,
    muted = function()
      return not S().dynamicPitch
    end,
    mutedDesc = L.PITCH_OFF_DESC,
    disabled = FramingOff,
  }, card.inner))
  return card
end

local function MountedCard()
  local card = W.Card(content, { number = 2, title = L.STEP2_TITLE, desc = L.STEP2_DESC }, CONTENT_W)
  card.Add(Centered(card, W.Preview(card, { point = MountedPoint, caption = L.STEP2_TITLE, disabled = FramingOff, figure = T.rider })))
  card.Add(W.Segmented(card, {
    label = L.MOUNTED_MODE,
    options = { { "match", L.MODE_MATCH }, { "center", L.MODE_CENTER }, { "custom", L.MODE_CUSTOM } },
    recommended = "match", -- the point of SteadyCam; "center" is the game's usual mounted camera
    recommendedText = L.RECOMMENDED,
    descFor = function(mode)
      return mode == "center" and L.MODE_CENTER_DESC
        or mode == "custom" and L.MODE_CUSTOM_DESC
        or L.MODE_MATCH_DESC
    end,
    get = Get("mountedMode"),
    set = Set("mountedMode"),
    disabled = FramingOff,
  }, card.inner))
  card.Add(W.Slider(card, {
    label = L.MOUNTED_OFFSET,
    min = -8,
    max = 8,
    step = 0.1,
    default = 2.5,
    leftText = L.LEFT,
    centerText = L.CENTER,
    rightText = L.RIGHT,
    get = Get("mountedOffset"),
    set = Set("mountedOffset"),
    disabled = FramingOff,
    shown = function()
      return S().mountedMode == "custom"
    end,
  }, card.inner))
  card.Add(W.Slider(card, {
    label = L.FLYING_PITCH,
    desc = L.FLYING_PITCH_DESC,
    min = 0.05,
    max = 0.95,
    step = 0.05,
    default = PC.Recommended.flyingPitch,
    leftText = L.LOWER,
    rightText = L.HIGHER,
    get = Get("flyingPitch"),
    set = function(v)
      if not S().dynamicPitch then
        PC.SetSetting("dynamicPitch", true) -- vertical framing needs it
      end
      PC.SetSetting("flyingPitch", v)
    end,
    muted = function()
      return not S().dynamicPitch
    end,
    mutedDesc = L.PITCH_OFF_DESC,
    disabled = FramingOff,
  }, card.inner))
  return card
end

--- Calibration: optional, so it lives in Advanced (under Motion Sickness Protection) as a
--- section, not as a step of the main flow.
local function AddCalibrationSection(card)
  card.Add(W.Section(card, {
    title = L.STEP3_TITLE,
    tag = "(" .. L.OPTIONAL .. ")",
    desc = L.STEP3_DESC,
  }, card.inner), 8)
  card.Add(W.Paragraph(card, {
    color = T.text,
    textFn = function()
      local count = CalibratedCount()
      local label = PC.GetModelLabel()
      return count == 0 and string.format(L.CALIBRATED_NONE, label)
        or string.format(L.CALIBRATED_COUNT, label, count)
    end,
  }, card.inner), 8)
  -- Your mounts in their own window; the same button closes it again.
  card.Add(W.Button(card, {
    text = L.VIEW_MOUNTS,
    textFn = function()
      return PC.MountsShown and PC.MountsShown() and L.CLOSE_MOUNTS or L.VIEW_MOUNTS
    end,
    height = 24,
    onClick = function()
      if not PC.OpenMounts then
        -- Updated with the game running: new files only load on a full restart.
        PC.Print(L.RESTART_NEEDED)
      elseif PC.MountsShown() then
        PC.CloseMounts()
      else
        PC.OpenMounts(CalibratedCount() > 0 and "calibrated" or "uncalibrated")
      end
    end,
  }, 220), 12)
  card.Add(W.Toggle(card, {
    label = L.NOTIFY_TOGGLE,
    desc = L.NOTIFY_TOGGLE_DESC,
    get = Get("notifyUncalibrated"),
    set = Set("notifyUncalibrated"),
    disabled = FramingOff,
  }, card.inner), 10)
  card.Add(W.Button(card, {
    text = L.CALIBRATE_BUTTON,
    disabled = FramingOff,
    disabledTooltip = L.CHECK_active,
    onClick = function()
      if PC.OpenWizard then
        PC.OpenWizard()
      end
    end,
  }, 220), 14)
  card.Add(W.Section(card, {}, card.inner), 4) -- divider before the other advanced options
end

local advancedCard

local SAVED_GREEN = { T.toggleOn[1], T.toggleOn[2], T.toggleOn[3], 0.85 }

local function BottomRow()
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(CONTENT_W, 28)
  -- Saves a copy of the choices above; green and locked while they are what is saved,
  -- back to normal as soon as one of them changes.
  local save = W.Button(row, {
    text = L.SAVE_PREFS,
    textFn = function()
      return PC.PreferencesSaved() and L.PREFS_SAVED or L.SAVE_PREFS
    end,
    style = function()
      if PC.PreferencesSaved() then
        return { bg = SAVED_GREEN, text = T.white, locked = true }
      end
      return { bg = T.trackOff, text = T.text }
    end,
    onClick = function()
      PC.SavePreferences()
      -- A short "success" chime (the game's quest-complete ding), with fallbacks.
      local kit = _G.SOUNDKIT
      local sound = kit and (kit.IG_QUEST_LIST_COMPLETE or kit.UI_QUEST_ROLLING_FORWARD_01
        or kit.IG_MAINMENU_OPTION_CHECKBOX_ON)
      if sound and _G.PlaySound then
        _G.PlaySound(sound)
      end
    end,
  }, HALF_ROW)
  save:SetPoint("TOPLEFT")
  -- Advanced settings: understated, and opening them asks first.
  local advanced = W.Button(row, {
    text = L.ADVANCED_SHOW,
    textFn = function()
      return S().showAdvanced and L.ADVANCED_HIDE or L.ADVANCED_SHOW
    end,
    style = function()
      return { bg = { 1, 1, 1, 0.04 }, text = T.textDim }
    end,
    onClick = function()
      if S().showAdvanced then
        PC.SetSetting("showAdvanced", false)
      else
        PC.Confirm(L.ADVANCED_CONFIRM, function()
          PC.SetSetting("showAdvanced", true)
        end)
      end
    end,
  }, HALF_ROW)
  advanced:SetPoint("TOPRIGHT")
  function row.Refresh() end
  return row
end

local function AdvancedCard()
  local card = W.Card(content, { title = L.ADVANCED_TITLE }, CONTENT_W)
  card.Add(W.Toggle(card, {
    label = L.DYNAMIC_PITCH,
    desc = L.DYNAMIC_PITCH_DESC,
    get = Get("dynamicPitch"),
    set = Set("dynamicPitch"),
    disabled = FramingOff,
  }, card.inner))
  card.Add(W.Toggle(card, {
    label = L.RESPECT_MS,
    desc = L.RESPECT_MS_DESC,
    get = Get("respectMotionSickness"),
    set = Set("respectMotionSickness"),
    disabled = function()
      return not PC.IsActive()
    end,
  }, card.inner), 16)
  AddCalibrationSection(card)
  card.Add(W.Slider(card, {
    label = L.MOUNT_TIME,
    desc = L.MOUNT_TIME_DESC,
    min = 0,
    max = 2,
    step = 0.05,
    default = 0,
    format = "%.2fs",
    get = Get("mountTransitionTime"),
    set = Set("mountTransitionTime"),
    disabled = FramingOff,
  }, card.inner))
  card.Add(W.Toggle(card, { label = L.DEBUG, get = Get("debug"), set = Set("debug") }, card.inner))
  card.Add(W.Toggle(card, {
    label = L.RESEARCH_TOGGLE,
    desc = L.RESEARCH_TOGGLE_DESC,
    shown = function()
      return S().debug or S().research
    end,
    get = Get("research"),
    set = function(v)
      PC.SetSetting("research", v)
      if v then
        PC.Research.Announce()
      end
    end,
  }, card.inner))
  -- Two ways back: the game's own camera (SteadyCam off), or SteadyCam's recommended values.
  local restore = W.Button(card, {
    text = L.RESTORE_BUTTON,
    tooltip = L.RESTORE_TOOLTIP,
    onClick = function()
      PC.Confirm(L.RESTORE_CONFIRM, function()
        PC.ApplyGameCamera()
        PC.Print(L.RESTORE_DONE)
      end)
    end,
  }, HALF_CARD)
  local R = PC.Recommended
  local summary = string.format(L.RECOMMENDED_TOOLTIP, R.footOffset, R.footPitch, L.MODE_MATCH, R.flyingPitch,
    R.turnSpeed)
  local recommended = W.Button(card, {
    text = L.RECOMMENDED_BUTTON,
    tooltip = summary,
    onClick = function()
      PC.Confirm(L.RECOMMENDED_CONFIRM .. "\n\n" .. summary .. "\n\n" .. L.OVERWRITE_NOTE, function()
        PC.ApplyRecommended()
        PC.Print(L.RECOMMENDED_DONE)
      end)
    end,
  }, HALF_CARD)
  -- Your own saved framing ("Save my preferences" at the bottom of the window).
  local load = W.Button(card, {
    text = L.LOAD_PREFS,
    tooltip = L.LOAD_TOOLTIP,
    disabled = function()
      return not PC.HasSavedPreferences() or PC.PreferencesSaved()
    end,
    disabledTooltip = function()
      return PC.HasSavedPreferences() and L.LOAD_SAME or L.LOAD_NONE
    end,
    onClick = function()
      PC.Confirm(L.LOAD_CONFIRM .. "\n\n" .. L.OVERWRITE_NOTE, function()
        if PC.LoadPreferences() then
          PC.Print(L.LOAD_DONE)
        end
      end)
    end,
  }, HALF_CARD)
  card.Add(W.Row(card, { restore, recommended }, 12), 10)
  card.Add(load)
  return card
end

---------------------------------------------------------------------------------------
-- Community: Discord invite. Addons can't open a browser, so the button shows the link
-- in a game dialog, selected, ready for Ctrl+C.
---------------------------------------------------------------------------------------
local DISCORD_URL = "https://discord.gg/aa2aYfuJ9g"
local DISCORD_COLOR = { 0.345, 0.396, 0.949, 1 } -- Discord blurple
local LINK_POPUP = "STEADYCAM_DISCORD"

function PC.ShowDiscordInvite()
  local dialogs, show = _G.StaticPopupDialogs, _G.StaticPopup_Show
  if not (dialogs and show) then
    PC.Print(L.DISCORD_TEXT .. " " .. DISCORD_URL)
    return
  end
  local function EditBoxOf(popup)
    return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox or popup.EditBox
  end
  local function Select(editBox)
    editBox:SetText(DISCORD_URL)
    editBox:HighlightText()
    editBox:SetFocus()
  end
  dialogs[LINK_POPUP] = dialogs[LINK_POPUP] or {
    text = _G.IsMacClient and _G.IsMacClient() and L.COPY_LINK:gsub("Ctrl%+C", "Cmd+C"):gsub("Strg%+C", "Cmd+C")
      or L.COPY_LINK,
    button1 = _G.CLOSE or "Close",
    hasEditBox = true,
    editBoxWidth = 260,
    OnShow = function(self)
      local editBox = EditBoxOf(self)
      if editBox then
        Select(editBox)
      end
    end,
    EditBoxOnTextChanged = function(editBox)
      if editBox:GetText() ~= DISCORD_URL then
        Select(editBox) -- read-only: typing puts the link back
      end
    end,
    EditBoxOnEnterPressed = function(editBox)
      editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
      editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  show(LINK_POPUP)
end

local function CommunityCard()
  local card = W.Card(content, {}, CONTENT_W)
  card.Add(W.Paragraph(card, { color = T.text, text = L.DISCORD_TEXT }, card.inner), 10)
  card.Add(W.Button(card, {
    text = L.DISCORD_BUTTON,
    color = DISCORD_COLOR,
    onClick = PC.ShowDiscordInvite,
  }, 220))
  return card
end

---------------------------------------------------------------------------------------
-- Window chrome
---------------------------------------------------------------------------------------
local function Build()
  win = CreateFrame("Frame", "SteadyCamWindow", UIParent)
  win:SetSize(T.width, T.height)
  win:SetPoint("CENTER")
  win:SetFrameStrata("HIGH") -- the game's dialogs (DIALOG) stay in front of it
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", function(self)
    self:StartMoving()
    self:SetScript("OnUpdate", function()
      if PC.PlaceMounts then
        PC.PlaceMounts()
      end
    end)
  end)
  win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetScript("OnUpdate", nil)
    if PC.PlaceMounts then
      PC.PlaceMounts()
    end
  end)
  W.Box(win, T.windowBg, T.windowBorder, T.radiusWindow)

  -- The wordmark in its viewfinder, the version beside its letters; the cards start below.
  local wordmark, _, mid = W.WindowHeader(win, T.margin, -HEADER_TOP, HEADER_H)
  local version = W.Text(win, "GameFontDisableSmall", T.textDim)
  version:SetPoint("LEFT", wordmark, "TOPRIGHT", 10, mid)
  version:SetText("v" .. PC.version)

  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)
  -- The author's mark, in the window's own margin: visible wherever the cards scroll.
  W.Signature(win, T.margin, 5)

  scroll = CreateFrame("ScrollFrame", nil, win)
  scroll:SetPoint("TOPLEFT", T.margin, -(HEADER_TOP + HEADER_H + 18))
  scroll:SetPoint("BOTTOMRIGHT", -T.margin, 20)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_W, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  local function MaxScroll()
    return math.max(0, content:GetHeight() - scroll:GetHeight())
  end
  local bar = W.ScrollBar(win, {
    get = function()
      return scroll:GetVerticalScroll(), MaxScroll(), scroll:GetHeight(), content:GetHeight()
    end,
    set = function(value)
      scroll:SetVerticalScroll(PC.Clamp(value, 0, MaxScroll()))
      scroll.UpdateBar()
    end,
    wheel = function(delta) -- the bar sits outside the scroll frame: scroll from it too
      scroll:GetScript("OnMouseWheel")(scroll, delta)
    end,
  })
  -- Right against the cards' right edge (the cards span the scroll frame's width).
  bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 0, 0)
  bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 0, 0)
  function scroll.UpdateBar()
    if scroll:GetVerticalScroll() > MaxScroll() then
      scroll:SetVerticalScroll(MaxScroll()) -- content got shorter
    end
    bar.Update()
  end
  scroll:SetScript("OnMouseWheel", function(self, delta)
    self:SetVerticalScroll(PC.Clamp(self:GetVerticalScroll() - delta * 48, 0, MaxScroll()))
    self.UpdateBar()
  end)

  blocks = {
    StatusCard(),
    FootCard(),
    MountedCard(),
    BottomRow(),
  }
  advancedCard = AdvancedCard()
  advancedCard:SetShown(S().showAdvanced)
  blocks[#blocks + 1] = advancedCard
  blocks[#blocks + 1] = CommunityCard()

  win:SetScript("OnShow", Refresh)
  win:Hide() -- PC.OpenWindow shows it (and that Show registers it for Esc)
  W.EscClosable(win, "SteadyCamWindow")
end

--- Never taller than the screen (high UI scales): the content scrolls instead.
local function FitHeight()
  local screenH = UIParent:GetHeight() or 0
  if win and screenH > 0 then
    win:SetHeight(math.min(T.height, screenH - 32))
  end
end

function PC.OpenWindow()
  if not win then
    Build()
  end
  PC.db.settings.onboardingSeen = true
  FitHeight()
  win:Show()
  Refresh()
end

local fitter = CreateFrame("Frame")
for _, event in ipairs({ "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
  pcall(fitter.RegisterEvent, fitter, event)
end
fitter:SetScript("OnEvent", function()
  FitHeight()
  Refresh()
end)

function PC.HideWindow()
  if win then
    win:Hide()
  end
end

function PC.ToggleWindow()
  if win and win:IsShown() then
    win:Hide()
  else
    PC.OpenWindow()
  end
end

-- Advanced card visibility follows its setting; everything refreshes on state changes.
PC.On("SETTINGS_CHANGED", function()
  if advancedCard then
    advancedCard:SetShown(S().showAdvanced)
  end
  Refresh()
end)
for _, event in ipairs({ "MOUNT_SWAP", "MOUNT_IDENTIFIED", "PROFILE_READY", "CALIBRATION_UPDATED",
  "MOUNTS_WINDOW", "TURN_SPEED_GAME", "PREFS_SAVED" }) do
  PC.On(event, Refresh)
end

---------------------------------------------------------------------------------------
-- Esc → Options → AddOns → SteadyCam: a small page that opens the window.
---------------------------------------------------------------------------------------
-- Its entry in the AddOns list is the wordmark, not text: the same markup as ## Title in
-- SteadyCam.toc (the cropped art of Media/Wordmark at 15 units tall), as Combat Mode does.
local CATEGORY_NAME = "|A:::|a|TInterface\\AddOns\\SteadyCam\\Media\\Wordmark:15:86:0:0:512:128:2:510:19:108|t"

local function RegisterSettingsPage()
  local Settings = _G.Settings
  if not (Settings and Settings.RegisterCanvasLayoutCategory) then
    return
  end
  local panel = CreateFrame("Frame")
  local wordmark = W.Wordmark(panel, T.wordmark, 30)
  wordmark:SetPoint("TOPLEFT", 16, -16)
  local desc = W.Text(panel, "GameFontHighlight", T.text)
  desc:SetPoint("TOPLEFT", 16, -60)
  desc:SetWidth(520)
  desc:SetText(L.TAGLINE)
  local open = W.Button(panel, {
    text = L.OPEN_BUTTON,
    primary = true,
    onClick = function()
      if _G.SettingsPanel and _G.SettingsPanel:IsShown() then
        _G.HideUIPanel(_G.SettingsPanel)
      end
      PC.OpenWindow()
    end,
  }, 180)
  open:SetPoint("TOPLEFT", 16, -96)
  local category = Settings.RegisterCanvasLayoutCategory(panel, CATEGORY_NAME)
  Settings.RegisterAddOnCategory(category)
end

pcall(RegisterSettingsPage)

-- The AddOns button on the minimap (## AddonCompartmentFunc in the TOC).
_G.SteadyCam_OnAddonCompartmentClick = function()
  PC.ToggleWindow()
end
