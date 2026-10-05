---------------------------------------------------------------------------------------
--  UI/Wizard.lua — calibration wizard window
---------------------------------------------------------------------------------------
--  Small window on the left, vertically centered (your character and its bubble stay
--  visible); it can be dragged, and opens there again next time:
--    intro → pick a mount, pre-flight checks, Start
--    run   → step / distance / instruction, one big SECURE button (mount / dismount)
--    done  → summary, calibrate another mount
--  The secure button runs Calibration.MacroText(). With "AnyUp"+"AnyDown" registered the
--  template executes on one edge only (down when ActionButtonUseKeyDown is on), so
--  PreClick / PostClick act on that same edge: PreClick starts the capture, PostClick
--  clears the macro until the next step (no double mounts on a double click).
--  Contains a protected button: never shown, hidden or moved in combat.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local CreateFrame = _G.CreateFrame
local InCombatLockdown = _G.InCombatLockdown
local UIParent = _G.UIParent

local T, W, L = PC.Theme, PC.Widgets, PC.L
local Cal = PC.Calibration

local WIDTH = 460
local MARGIN = 24 -- window edge to its cards
local HEADER_TOP, HEADER_H = 18, 32 -- the wordmark: its distance from the top edge, its height
local BODY_TOP = HEADER_TOP + HEADER_H + 14 -- where the cards start
local LIVE_REFRESH = 0.5 -- s between checklist refreshes while the window is open
local INNER = WIDTH - 2 * T.pad - 2 * MARGIN
local ICON_OK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t "
local ICON_NO = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t "
local ICON_INFO = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t "

local wiz, body, introCard, runCard, doneCard, secure, mountList
local selectedMount
local revealSelected = false -- scroll the picker to selectedMount once (set from outside)
local inClick = false

local function Color(c, text)
  local function q(x)
    return math.floor(x * 255 + 0.5) -- rounded, so T.accent gives exactly F0BD30
  end
  return string.format("|cff%02x%02x%02x%s|r", q(c[1]), q(c[2]), q(c[3]), text)
end

local function IsCalibrated(mountID)
  local m = PC.GetModelStore().mounts[mountID]
  return m and m.captures and #m.captures > 0
end


---------------------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------------------
local function Relayout()
  if not wiz or InCombatLockdown() then
    return
  end
  local view = Cal.View()
  local running = Cal.IsRunning()
  introCard:SetShown(not running and view.state ~= "done")
  runCard:SetShown(running)
  doneCard:SetShown(not running and view.state == "done")
  local y = 0
  for _, card in ipairs({ introCard, runCard, doneCard }) do
    if card:IsShown() then
      card.Layout()
      card:ClearAllPoints()
      card:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
      y = y + card:GetHeight()
    end
  end
  -- Never taller than the screen: give the mount picker fewer rows when needed.
  local screenH = UIParent:GetHeight() or 0
  if introCard:IsShown() and mountList and screenH > 0 then
    local fixedH = y + BODY_TOP + MARGIN - mountList.ListHeight()
    if mountList.FitHeight(screenH - 40 - fixedH) then
      Relayout() -- once more with the new list height
      return
    end
  end
  body:SetHeight(y)
  wiz:SetHeight(y + BODY_TOP + MARGIN)
end

local function UpdateSecureButton()
  if not secure or InCombatLockdown() or inClick then
    return
  end
  secure:SetAttribute("macrotext", Cal.MacroText())
  local view = Cal.View()
  local ready = view.state == "ready"
  secure.text:SetText(ready and L["WIZ_BUTTON_" .. (view.action or "mount")] or L.WIZ_BUTTON_WAIT)
  secure:SetAlpha(ready and 1 or 0.45)
end

local function Refresh()
  if not wiz or not wiz:IsShown() then
    return
  end
  W.RefreshAll()
  UpdateSecureButton()
  Relayout()
end

---------------------------------------------------------------------------------------
-- Intro
---------------------------------------------------------------------------------------
local VISIBLE_ROWS = 7 -- at most; fewer on short screens (Relayout)
local MIN_ROWS = 3
local ROW_H, ROW_GAP = 26, 2
local FILTERS = { "favorites", "usable", "all" }

--- The mount chosen elsewhere (mounts window, chat link) is always listed first, even
--- when the open tab wouldn't show it, so it is clear what Start will calibrate.
local function WithSelected(list)
  if not selectedMount then
    return list
  end
  for _, m in ipairs(list) do
    if m.id == selectedMount then
      return list
    end
  end
  local name, _, icon, _, isUsable = _G.C_MountJournal.GetMountInfoByID(selectedMount)
  if not name then
    return list
  end
  local out = { { id = selectedMount, name = name, icon = icon, usable = isUsable and true or false } }
  for _, m in ipairs(list) do
    out[#out + 1] = m
  end
  return out
end

-- Tabs (favorites / usable here / all) over a list that scrolls with the mouse wheel.
local function MountList(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(INNER)
  local offset = 0
  local visible = VISIBLE_ROWS
  local list = {}

  local tabs = {}
  local tabW = (INNER - 2 * 6) / #FILTERS
  for i, filter in ipairs(FILTERS) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(tabW, 22)
    b:SetPoint("TOPLEFT", (i - 1) * (tabW + 6), 0)
    b.bg = W.Rounded(b, "BACKGROUND", T.trackOff, T.radiusControl)
    W.Rounded(b, "HIGHLIGHT", { 1, 1, 1, 0.08 }, T.radiusControl)
    b.text = W.Text(b, "GameFontHighlightSmall", T.text, "CENTER")
    b.text:SetPoint("CENTER")
    b:SetScript("OnClick", function()
      PC.db.settings.mountFilter = filter
      offset = 0
      Cal.RefreshMountList()
      Refresh()
    end)
    b.filter = filter
    tabs[i] = b
  end

  local box = CreateFrame("Frame", nil, f)
  box:SetSize(INNER, VISIBLE_ROWS * (ROW_H + ROW_GAP) - ROW_GAP)
  box:SetPoint("TOPLEFT", 0, -28)
  box:EnableMouseWheel(true)

  local rowW = INNER - 14
  local rows = {}
  for i = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, box)
    row:SetSize(rowW, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))
    -- Fill + border: the border turns gold on the selected mount, otherwise it matches the fill.
    row.bg = W.Box(row, T.trackOff, T.trackOff, T.radiusControl)
    -- The mount you ride now: a thin grey-green bar (visible even when it is selected).
    row.ridingBar = W.Rounded(row, "BORDER", { T.riding[1] + 0.12, T.riding[2] + 0.16, T.riding[3] + 0.12, 1 },
      1.5, { left = 3, right = rowW - 6, top = 5, bottom = 5 })

    W.Rounded(row, "HIGHLIGHT", { T.accent[1], T.accent[2], T.accent[3], 0.18 }, T.radiusControl)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 10, 0) -- clear of the riding bar (x 3..6)
    row.name = W.Text(row, "GameFontHighlightSmall", T.text)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", -96, 0)
    row.name:SetJustifyH("LEFT")
    row.tag = W.Text(row, "GameFontHighlightSmall", T.good, "RIGHT")
    row.tag:SetPoint("RIGHT", -8, 0)
    row:SetScript("OnClick", function(self)
      -- Ctrl-click: preview in the Dressing Room (as in the Mount Journal), don't select.
      if PC.HandleMountModifiedClick and PC.HandleMountModifiedClick(self.mountID) then
        return
      end
      selectedMount = self.mountID
      Refresh()
    end)
    row:SetScript("OnEnter", function(self)
      if not self.mountID then
        return
      end
      _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      _G.GameTooltip:AddLine(self.name:GetText() or "", 1, 1, 1)
      _G.GameTooltip:AddLine(L.CTRL_PREVIEW, T.textDim[1], T.textDim[2], T.textDim[3])
      _G.GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
      _G.GameTooltip:Hide()
    end)
    rows[i] = row
  end


  local empty = W.Text(box, "GameFontHighlightSmall", T.textDim)
  empty:SetWidth(INNER)
  empty:SetPoint("TOPLEFT", 0, -4)

  local function MaxOffset()
    return math.max(0, #list - visible)
  end

  local function ScrollTo(value)
    local new = math.min(MaxOffset(), math.max(0, math.floor(value + 0.5)))
    if new ~= offset then
      offset = new
      f.Refresh()
    end
  end
  box:SetScript("OnMouseWheel", function(_, delta)
    ScrollTo(offset - delta)
  end)
  -- Scroll bar on the right: click the track to page, drag the thumb.
  local scrollBar = W.ScrollBar(box, {
    get = function()
      return offset, MaxOffset(), visible, #list
    end,
    set = ScrollTo,
  })
  scrollBar:SetPoint("TOPRIGHT")
  scrollBar:SetPoint("BOTTOMRIGHT")

  function f.Refresh()
    local filter = PC.db.settings.mountFilter or "favorites"
    list = WithSelected(Cal.CandidateMounts(filter))
    for _, b in ipairs(tabs) do
      local selected = b.filter == filter
      local c = selected and { T.accent[1], T.accent[2], T.accent[3], 0.9 } or T.trackOff
      b.bg:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
      local tc = selected and { 0.08, 0.08, 0.08 } or T.text
      b.text:SetTextColor(tc[1], tc[2], tc[3])
      local n = b.filter == filter and #list or #Cal.CandidateMounts(b.filter)
      b.text:SetText(string.format("%s (%d)", L["FILTER_" .. b.filter], n))
    end
    if not selectedMount then
      for _, m in ipairs(list) do
        if m.usable then
          selectedMount = m.id
          break
        end
      end
    end
    if revealSelected then
      revealSelected = false
      for i, m in ipairs(list) do
        if m.id == selectedMount then
          offset = math.max(0, math.min(i - 1, MaxOffset())) -- the chosen mount on top
          break
        end
      end
    end
    offset = math.min(offset, MaxOffset())
    for i, row in ipairs(rows) do
      local m = i <= visible and list[offset + i] or nil
      row:SetShown(m ~= nil)
      if m then
        row.mountID = m.id
        row.icon:SetTexture(m.icon)
        row.icon:SetDesaturated(not m.usable)
        row.name:SetText(m.name or "?")
        local nc = m.usable and T.text or T.textDim
        row.name:SetTextColor(nc[1], nc[2], nc[3])
        if IsCalibrated(m.id) then
          row.tag:SetText(L.WIZ_CALIBRATED)
          row.tag:SetTextColor(T.good[1], T.good[2], T.good[3])
        elseif (PC.GetModelStore().mounts[m.id] or {}).unmeasurable then
          row.tag:SetText(L.TAG_UNMEASURABLE) -- too big to measure: an estimate, not green
          row.tag:SetTextColor(T.textDim[1], T.textDim[2], T.textDim[3])
        elseif PC.Profiles.IsCalibrated(m.id) then
          local kind = PC.Profiles.Describe(m.id)
          local builtin = kind == "builtin" or kind == "scaled"
          row.tag:SetText(builtin and L.WIZ_BUILTIN or L.WIZ_SAME_MODEL)
          -- Green only for measurements of your own (as in the mounts window).
          local tc = builtin and T.textDim or T.good
          row.tag:SetTextColor(tc[1], tc[2], tc[3])
        elseif not m.usable then
          row.tag:SetText(L.WIZ_NOT_USABLE)
          row.tag:SetTextColor(T.textDim[1], T.textDim[2], T.textDim[3])
        else
          row.tag:SetText("")
        end
        local selected = m.id == selectedMount
        local riding = PC.IsMountedOrInVehicle() and PC.GetCurrentMountID() == m.id
        local c = riding and T.riding or (selected and T.selected) or T.trackOff
        row.bg:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        local edge = selected and T.accent or c
        row.bg:SetBorderColor(edge[1], edge[2], edge[3], edge[4] or 1)
        row.ridingBar:SetShown(riding)
      end
    end
    empty:SetText(L["WIZ_NO_MOUNTS_" .. filter])
    empty:SetShown(#list == 0)
    local shownRows = math.max(1, math.min(#list, visible))
    box:SetHeight(#list == 0 and 30 or (shownRows * (ROW_H + ROW_GAP) - ROW_GAP))
    scrollBar.Update()
    f:SetHeight(28 + box:GetHeight())
  end
  --- Rows on screen (clamped); true when it changed.
  function f.SetVisibleRows(n)
    n = math.max(MIN_ROWS, math.min(VISIBLE_ROWS, n))
    if n == visible then
      return false
    end
    visible = n
    f.Refresh()
    return true
  end
  function f.ListHeight()
    return box:GetHeight()
  end
  --- As many rows as fit in h (between MIN_ROWS and VISIBLE_ROWS); true when it changed.
  function f.FitHeight(h)
    return f.SetVisibleRows(math.floor((h + ROW_GAP) / (ROW_H + ROW_GAP)))
  end
  W.Register(f)
  return f
end

local function BuildIntro()
  local card = W.Card(body, { title = L.WIZ_HOW_TITLE }, WIDTH - 2 * MARGIN)
  card.Add(W.Paragraph(card, { text = L.WIZ_INTRO, color = T.text }, INNER), 8)
  card.Add(W.Paragraph(card, { text = L.WIZ_HOW }, INNER))
  card.Add(W.Paragraph(card, { text = L.WIZ_CHECKS, font = "GameFontNormal", color = T.accent }, INNER), 6)
  card.Add(W.Paragraph(card, {
    color = T.text,
    textFn = function()
      local lines = {}
      for _, check in ipairs(Cal.Checks(selectedMount)) do
        local icon = check.ok and ICON_OK or (check.required and ICON_NO or ICON_INFO)
        local text
        if check.key == "race" then
          text = string.format(L.CHECK_race, PC.GetModelLabel())
        elseif check.key == "fps" then
          text = string.format(L.CHECK_fps, math.floor((_G.GetFramerate and _G.GetFramerate()) or 0))
        else
          text = L["CHECK_" .. check.key]
        end
        lines[#lines + 1] = icon .. text
      end
      lines[#lines + 1] = ICON_INFO .. L.CHECK_BUBBLES
      return table.concat(lines, "\n")
    end,
  }, INNER))
  card.Add(W.Paragraph(card, { text = L.WIZ_PICK_MOUNT, font = "GameFontNormal", color = T.accent }, INNER), 6)
  mountList = MountList(card)
  card.Add(mountList)
  card.Add(W.Paragraph(card, {
    textFn = function()
      local repeats = Cal.Repeats()
      local steps = Cal.StepCount(repeats)
      local minutes = math.max(1, math.floor(steps * 8 / 60 + 0.5))
      return string.format(repeats > 1 and L.WIZ_PLAN_FULL or L.WIZ_PLAN_QUICK, steps, minutes)
    end,
  }, INNER))
  card.Add(W.Button(card, {
    text = L.WIZ_START,
    primary = true,
    disabled = function()
      return not Cal.CanStart(selectedMount)
    end,
    onClick = function()
      if Cal.Start(selectedMount) and PC.HideWindow then
        PC.HideWindow()
      end
    end,
  }, 180))
  return card
end

---------------------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------------------
local function ProgressBar(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(INNER, 6)
  W.Solid(f, "BACKGROUND", T.trackOff):SetAllPoints()
  local fill = W.Solid(f, "ARTWORK", { T.accent[1], T.accent[2], T.accent[3], 0.9 })
  fill:SetPoint("TOPLEFT")
  fill:SetPoint("BOTTOMLEFT")
  function f.Refresh()
    local v = Cal.View()
    local done = v.step and v.total and (v.step - 1) / v.total or 0
    fill:SetWidth(math.max(1, INNER * done))
  end
  W.Register(f)
  return f
end

local function BuildRun()
  local card = W.Card(body, {}, WIDTH - 2 * MARGIN)
  card.Add(W.Paragraph(card, {
    font = "GameFontNormal",
    color = T.accent,
    textFn = function()
      local v = Cal.View()
      local icon = v.icon and ("|T" .. v.icon .. ":18|t ") or ""
      return icon .. (v.mountName or "")
    end,
  }, INNER), 6)
  card.Add(W.Paragraph(card, {
    color = T.text,
    textFn = function()
      local v = Cal.View()
      if not v.step then
        return ""
      end
      local level = L["ZOOM_" .. (v.level or 1)]
      return string.format(L.WIZ_STEP, math.min(v.step, v.total), v.total)
        .. "    "
        .. string.format(L.WIZ_DISTANCE, level, v.zoom or 0)
    end,
  }, INNER), 6)
  card.Add(ProgressBar(card))
  card.Add(W.Paragraph(card, {
    font = "GameFontHighlight",
    color = T.white,
    textFn = function()
      local v = Cal.View()
      if v.state == "zooming" then
        return L.WIZ_ZOOMING
      elseif v.state == "ready" then
        return L["WIZ_PRESS_" .. (v.action or "mount")]
      elseif v.state == "recording" then
        if v.action == "dismount" and PC.IsMountedOrInVehicle() then
          return L.WIZ_DISMOUNT_NOW
        end
        return L.WIZ_RECORDING
      elseif v.state == "paused" then
        return L.WIZ_PAUSED
      end
      return L.WIZ_SETTLING
    end,
  }, INNER))

  secure = CreateFrame("Button", "SteadyCamActionButton", card, "SecureActionButtonTemplate")
  secure:SetSize(INNER, 46)
  secure:RegisterForClicks("AnyUp", "AnyDown")
  secure:SetAttribute("type", "macro")
  secure:SetAttribute("macrotext", "")
  W.Rounded(secure, "BACKGROUND", { T.accent[1], T.accent[2], T.accent[3], 0.95 }, T.radius)
  W.Rounded(secure, "HIGHLIGHT", { 1, 1, 1, 0.12 }, T.radius)
  secure.text = W.Text(secure, "GameFontNormalLarge", { 0.08, 0.08, 0.08 }, "CENTER")
  secure.text:SetPoint("CENTER")
  secure.text:SetText(L.WIZ_BUTTON_WAIT)

  local function ExecutingEdge(down)
    local keyDown
    if C_CVar.GetCVarBool then
      keyDown = C_CVar.GetCVarBool("ActionButtonUseKeyDown")
    else
      keyDown = C_CVar.GetCVar("ActionButtonUseKeyDown") == "1"
    end
    if down then
      return keyDown and true or false
    end
    return not keyDown
  end
  secure:SetScript("PreClick", function(_, _, down)
    if ExecutingEdge(down) then
      inClick = true
      Cal.OnClick()
      inClick = false
    end
  end)
  secure:SetScript("PostClick", function(_, _, down)
    if ExecutingEdge(down) then
      UpdateSecureButton()
    end
  end)
  card.Add(secure)

  card.Add(W.Paragraph(card, {
    textFn = function()
      local v = Cal.View()
      if not v.message then
        return ""
      end
      local color = v.messageKind == "ok" and T.good or (v.messageKind == "warn" and T.warning)
        or (v.messageKind == "info" and T.accent) or T.textDim
      local text = Color(color, L[v.message])
      if v.detail and PC.db.settings.debug then
        text = text .. "\n" .. Color(T.textDim, "(" .. v.detail .. ")")
      end
      return text
    end,
  }, INNER))
  card.Add(W.Button(card, {
    text = L.WIZ_CANCEL,
    onClick = function()
      Cal.Cancel()
    end,
    disabled = function()
      return InCombatLockdown()
    end,
  }, 140))
  return card
end

---------------------------------------------------------------------------------------
-- Done
---------------------------------------------------------------------------------------
local function BuildDone()
  local card = W.Card(body, { title = L.WIZ_DONE_TITLE }, WIDTH - 2 * MARGIN)
  card.Add(W.Paragraph(card, {
    color = T.text,
    textFn = function()
      local s = Cal.View().summary
      if not s then
        return ""
      end
      if s.unmeasurable then
        return string.format(L.WIZ_DONE_UNMEASURABLE, s.mountName or "?")
      end
      if s.obstacle then
        return string.format(L.WIZ_DONE_OBSTACLE, s.mountName or "?")
      end
      return string.format(L.WIZ_DONE, s.mountName or "?", PC.GetModelLabel())
        .. "\n\n"
        .. string.format(L.WIZ_DONE_RATIO, s.ratio or 0)
        .. "\n\n"
        .. L.WIZ_DONE_APPLIED
    end,
  }, INNER))
  card.Add(W.Button(card, {
    text = L.WIZ_ANOTHER,
    primary = true,
    onClick = function()
      selectedMount = nil
      Cal.Reset()
    end,
  }, 220))
  card.Add(W.Button(card, {
    text = L.WIZ_CLOSE,
    onClick = function()
      if InCombatLockdown() then
        return -- holds the secure button: can't be hidden in combat
      end
      Cal.Reset()
      wiz:Hide()
    end,
    disabled = function()
      return InCombatLockdown()
    end,
  }, 140))
  return card
end

---------------------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------------------
-- Each time it opens: middle of the left edge, away from your character and its bubble.
local function ShowAtDefaultSpot()
  if not wiz:IsShown() then
    wiz:ClearAllPoints()
    wiz:SetPoint("LEFT", UIParent, "LEFT", 60, 0)
  end
  wiz:Show()
  wiz:Raise() -- in front of the SteadyCam window if they overlap
end

local function Build()
  wiz = CreateFrame("Frame", "SteadyCamWizard", UIParent)
  wiz:SetSize(WIDTH, 400)
  wiz:SetPoint("LEFT", UIParent, "LEFT", 60, 0)
  wiz:SetFrameStrata("HIGH") -- the game's dialogs (DIALOG) stay in front of it
  wiz:SetClampedToScreen(true)
  wiz:SetMovable(true)
  wiz:EnableMouse(true)
  wiz:RegisterForDrag("LeftButton")
  wiz:SetScript("OnDragStart", function(self)
    if not InCombatLockdown() then
      self:StartMoving()
    end
  end)
  wiz:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- moving is for this time only; it opens on the left again
  end)
  W.Box(wiz, T.windowBg, T.windowBorder, T.radiusWindow)
  W.WindowHeader(wiz, MARGIN, -HEADER_TOP, HEADER_H, L.WIZ_TITLE)
  local close = CreateFrame("Button", nil, wiz, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function()
    if InCombatLockdown() then
      return
    end
    Cal.Reset()
    wiz:Hide()
  end)

  body = CreateFrame("Frame", nil, wiz)
  body:SetPoint("TOPLEFT", MARGIN, -BODY_TOP)
  body:SetSize(WIDTH - 2 * MARGIN, 1)

  introCard = BuildIntro()
  runCard = BuildRun()
  doneCard = BuildDone()
  wiz:SetScript("OnShow", Refresh)
  -- Live checklist: re-read the checks twice a second while the window is open (indoors
  -- / outdoors, combat, mount usable, FPS...). Cheap, and nothing runs while it's closed.
  local sinceRefresh = 0
  wiz:SetScript("OnUpdate", function(_, elapsed)
    sinceRefresh = sinceRefresh + elapsed
    if sinceRefresh >= LIVE_REFRESH then
      sinceRefresh = 0
      Refresh()
    end
  end)
  -- Things that change what can be used: refresh the mount list right away.
  local watcher = CreateFrame("Frame", nil, wiz)
  for _, event in ipairs({ "ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA",
    "MOUNT_JOURNAL_USABILITY_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
    pcall(watcher.RegisterEvent, watcher, event)
  end
  watcher:SetScript("OnEvent", function()
    Cal.RefreshMountList()
    Refresh()
  end)
end

function PC.OpenWizard()
  if InCombatLockdown() then
    return
  end
  if not wiz then
    Build()
  end
  Cal.RefreshMountList()
  if not Cal.IsRunning() and Cal.View().state == "done" then
    Cal.Reset()
  end
  ShowAtDefaultSpot()
  Refresh()
end

for _, event in ipairs({ "CALIBRATION_STATE", "MOUNT_SWAP", "MOUNT_IDENTIFIED", "SETTINGS_CHANGED" }) do
  PC.On(event, Refresh)
end

--- From the chat link: calibrate this mount right away. If something isn't ready (combat,
--- indoors...), the wizard opens on its checklist with the mount selected. When it is
--- done the summary stays up until you close it.
function PC.StartCalibrationFromLink(mountID, quick)
  if InCombatLockdown() then
    PC.Print(L.NOTIFY_COMBAT)
    return
  end
  if not wiz then
    Build()
  end
  if Cal.IsRunning() then
    ShowAtDefaultSpot()
    Refresh()
    return
  end
  Cal.RefreshMountList()
  if Cal.View().state == "done" then
    Cal.Reset()
  end
  selectedMount = mountID
  revealSelected = true
  if Cal.Start(mountID, quick) then
    if PC.HideWindow then
      PC.HideWindow()
    end
  end
  ShowAtDefaultSpot()
  Refresh()
end
