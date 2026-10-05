---------------------------------------------------------------------------------------
--  UI/Mounts.lua — your mounts: calibrated / not calibrated
---------------------------------------------------------------------------------------
--  Opened from the Calibration card. Same look as the calibration wizard:
--    hint → search → two tabs (Calibrated / Not calibrated, with counts and a line on
--    what each tab means) → a scrolling list: icon, name, and where the mount's data
--    comes from (calibrated, same model as..., SteadyCam data, size estimate).
--  Every row reacts like a button: it lights up on hover, its tooltip says it can be
--  clicked, and a left OR right click opens a small menu at the cursor:
--    Mount (Dismount when you ride it) · View mount · Calibrate / Calibrate again.
--  Ctrl-click previews the mount in the Dressing Room, as in the game's Mount Journal
--  (also on the wizard's mount list).
--  The menu is SteadyCam's own, not Blizzard's MenuUtil: summoning a mount is protected
--  (KNOWLEDGE.md §2), so "Mount" is a secure macro button (/cast <mount>, /dismount),
--  like the wizard's. Secure frames can't be shown, hidden or moved in combat: the
--  secure item lives outside the menu (parented to UIParent), is only shown out of
--  combat, and is taken down on PLAYER_REGEN_DISABLED, before the lockdown starts.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local C_CVar = _G.C_CVar
local C_MountJournal = _G.C_MountJournal
local CreateFrame = _G.CreateFrame
local GameTooltip = _G.GameTooltip
local GetCursorPosition = _G.GetCursorPosition
local InCombatLockdown = _G.InCombatLockdown
local IsControlKeyDown = _G.IsControlKeyDown
local IsFlying = _G.IsFlying
local IsMounted = _G.IsMounted
local GetUnitSpeed = _G.GetUnitSpeed
local IsFalling = _G.IsFalling
local UIParent = _G.UIParent

local T, W, L = PC.Theme, PC.Widgets, PC.L

local WIDTH = 436
local PAD = 24 -- window edge to its content
local HEADER_TOP, HEADER_H = 18, 32 -- the wordmark: its distance from the top edge, its height
local INNER = WIDTH - 2 * PAD
local VISIBLE_ROWS = 9
local ROW_H, ROW_GAP = 34, 2
local TAG_W = 110 -- right column of a row ("Riding", "not usable here")
local TABS = { "calibrated", "uncalibrated" }
local MENU_W, ITEM_H = 210, 24
local MENU_TOP = 36 -- first item, under the title and its divider

local win, search, placeholder, tabDesc, box, empty, scrollBar
local tabs, rows = {}, {}
local currentTab = "calibrated"
local query = "" -- folded search text (W.Fold)
local offset = 0
local data, dataKey -- { calibrated = {...}, uncalibrated = {...}, total = n } for one model key
local shown = {} -- the open tab's list after the search filter
local userMoved = false -- dragged by the player: stop following the SteadyCam window

---------------------------------------------------------------------------------------
-- Data. Classifying every collected mount (where its numbers come from, search key) costs
-- tens of milliseconds, so it is cached per race / sex / form and rebuilt only when that
-- changes, a calibration finishes or a mount is learned. Whether a mount can be used here
-- is read live: for the rows on screen and when the menu opens.
---------------------------------------------------------------------------------------
local function StoreEntry(mountID)
  return PC.GetModelStore().mounts[mountID]
end

local function OwnCalibration(mountID)
  local m = StoreEntry(mountID)
  return m and m.captures and #m.captures > 0
end

local function AnyOwnCalibration()
  for _, m in pairs(PC.GetModelStore().mounts) do
    if m.captures and #m.captures > 0 then
      return true
    end
  end
  return false
end

--- An own calibration that is the very measurement SteadyCam ships for this race (the
--- research runs it was built from): "factory", not "by you".
local function IsFactory(mountID)
  local m = StoreEntry(mountID)
  local known = PC.KnownCalibrations[PC.GetModelKey()]
  local k = known and known[mountID]
  return m and m.ratio and k and k.ratio and math.abs(m.ratio - k.ratio) <= 0.002 * k.ratio or false
end

--- Where a mount's numbers come from, as one short line, and its color.
local function SourceLine(mountID, kind, extra, anyOwn)
  if OwnCalibration(mountID) then
    return IsFactory(mountID) and L.SRC_FACTORY or L.SRC_OWN, T.good
  end
  if kind == "family" then
    return string.format(L.SRC_FAMILY, tostring(extra or "?")), T.good
  end
  local m = StoreEntry(mountID)
  if m and m.unmeasurable then
    return L.SRC_UNMEASURABLE, T.textDim
  elseif kind == "builtin" or kind == "scaled" then
    return L.SRC_BUILTIN, T.textDim
  elseif kind == "estimated" then
    return L.SRC_ESTIMATED, T.textDim
  elseif kind == "average" then
    -- "Average of your mounts" only when there are mounts of yours to average.
    return anyOwn and L.SRC_AVERAGE or L.SRC_BUILTIN, T.textDim
  end
  return "", T.textDim
end

local function BuildData()
  local result = { calibrated = {}, uncalibrated = {}, total = 0 }
  if not (C_MountJournal and C_MountJournal.GetMountIDs) then
    return result
  end
  local anyOwn = AnyOwnCalibration()
  for _, id in ipairs(C_MountJournal.GetMountIDs()) do
    local name, _, icon, _, _, _, _, _, _, hideOnChar, isCollected = C_MountJournal.GetMountInfoByID(id)
    if isCollected and not hideOnChar and type(name) == "string" then
      local kind, extra = PC.Profiles.Describe(id)
      local own = OwnCalibration(id)
      local stored = StoreEntry(id)
      local entry = {
        id = id,
        name = name,
        key = W.Fold(name),
        icon = icon,
        own = own,
        unmeasurable = stored and stored.unmeasurable or false,
      }
      entry.source, entry.sourceColor = SourceLine(id, kind, extra, anyOwn)
      local list = (own or kind == "family") and result.calibrated or result.uncalibrated
      list[#list + 1] = entry
      result.total = result.total + 1
    end
  end
  for _, tab in ipairs(TABS) do
    table.sort(result[tab], function(a, b)
      return a.key < b.key
    end)
  end
  return result
end

local function Data()
  local key = PC.GetModelKey()
  if not data or dataKey ~= key then
    data, dataKey = BuildData(), key -- also after a worgen / dracthyr form change
  end
  return data
end

--- Usable here and now (live: zone, indoors, swimming...).
local function Usable(mountID)
  local _, _, _, _, isUsable = C_MountJournal.GetMountInfoByID(mountID)
  return isUsable and true or false
end

local function Matches(list)
  if query == "" then
    return list
  end
  local out = {}
  for _, m in ipairs(list) do
    if m.key:find(query, 1, true) then
      out[#out + 1] = m
    end
  end
  return out
end

--- For the main window: mounts in the Calibrated tab (own + same model), all collected.
function PC.MountCounts()
  local d = Data()
  return #d.calibrated, d.total
end

---------------------------------------------------------------------------------------
-- State helpers
---------------------------------------------------------------------------------------
local function Riding(mountID)
  return PC.IsMountedOrInVehicle() and PC.GetCurrentMountID() == mountID
end

local function Calibrating()
  return PC.Calibration and PC.Calibration.IsRunning()
end

--- Why calibrating / previewing can't be done right now (nil = it can).
local function Blocked()
  if InCombatLockdown() then
    return L.REASON_COMBAT
  elseif Calibrating() then
    return L.REASON_CALIBRATING
  end
  return nil
end

local function Moving()
  return (GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0) or (IsFalling and IsFalling()) or false
end

--- The first menu item for a mount: label, macro (nil = can't), reason when it can't, and
--- whether the menu stays open after the click. On another mount, "Mount" makes the game
--- dismount you from it (a second click then mounts). Never while flying (also druid
--- Flight Form / Soar: airborne without a mount) — you would fall — and, except to get
--- off the mount you ride, never while moving or falling. The macros check [noflying]
--- again at the click itself, in case you took off since the menu last looked.
local function RideAction(entry)
  local riding = Riding(entry.id)
  local label = riding and L.MENU_DISMOUNT or L.MENU_MOUNT
  local blocked = Blocked()
  if blocked then
    return label, nil, blocked
  end
  if IsFlying and IsFlying() then
    return label, nil, L.REASON_FLYING
  end
  if riding then
    return label, "/dismount [noflying]"
  end
  if Moving() then
    return label, nil, L.REASON_MOVING
  end
  local spell = PC.Calibration.CastName(entry.id) or entry.name
  if IsMounted and IsMounted() then
    if not Usable(entry.id) then
      return label, nil, L.WIZ_NOT_USABLE -- don't drop you off your mount for nothing
    end
    return label, "/cast [noflying] " .. spell, nil, true
  end
  if PC.IsMountedOrInVehicle() or not Usable(entry.id) then
    return label, nil, L.WIZ_NOT_USABLE
  end
  return label, "/cast [nomounted,noflying] " .. spell
end

--- Show a mount in the Dressing Room, like Ctrl-click in the Mount Journal.
function PC.PreviewMount(mountID)
  if InCombatLockdown() then
    -- Opening a UI panel from addon code isn't safe in combat; say so the game's way.
    if _G.UIErrorsFrame then
      _G.UIErrorsFrame:AddMessage(_G.ERR_NOT_IN_COMBAT or L.REASON_COMBAT, 1, 0.1, 0.1)
    end
    return
  end
  if type(mountID) == "number" and _G.DressUpMount then
    _G.DressUpMount(mountID)
    local room = _G.DressUpFrame
    if room and room:IsShown() then
      if room:GetFrameStrata() ~= "HIGH" then
        room:SetFrameStrata("HIGH") -- the same layer as SteadyCam's windows...
      end
      room:Raise() -- ...and in front of them
    end
  end
end

--- Ctrl-click on a mount anywhere in SteadyCam: preview it. True when handled.
function PC.HandleMountModifiedClick(mountID)
  if IsControlKeyDown and IsControlKeyDown() then
    PC.PreviewMount(mountID)
    return true
  end
  return false
end

---------------------------------------------------------------------------------------
-- Context menu (own frame; the Mount item is a secure button)
---------------------------------------------------------------------------------------
local menu, menuTitle, secureItem, rideItem, previewItem, calibrateItem
local menuEntry

local function ItemLook(b, text)
  b:SetSize(MENU_W - 12, ITEM_H)
  b.hover = W.Rounded(b, "HIGHLIGHT", { T.accent[1], T.accent[2], T.accent[3], 0.25 }, 4)
  b.text = W.Text(b, "GameFontHighlight", T.text)
  b.text:SetPoint("LEFT", 10, 0)
  b.text:SetPoint("RIGHT", -6, 0)
  b.text:SetJustifyV("MIDDLE")
  b.text:SetWordWrap(false)
  b.text:SetText(text or "")
end

local function SetItemEnabled(b, enabled)
  local c = enabled and T.text or T.textDim
  b.text:SetTextColor(c[1], c[2], c[3])
  b.hover:SetShown(enabled)
  b.enabled = enabled
end

local function TextWidth(fs)
  local measure = fs.GetUnboundedStringWidth or fs.GetStringWidth
  return (measure and measure(fs)) or 0
end

local function HideSecureItem()
  if secureItem and not InCombatLockdown() then
    secureItem:Hide()
    secureItem:ClearAllPoints()
  end
end

local function CloseMenu()
  if menu then
    menu:Hide() -- OnHide also takes the secure item down
  end
end

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

local function Calibrate(mountID)
  CloseMenu()
  if win then
    win:Hide()
  end
  if PC.StartCalibrationFromLink then
    PC.StartCalibrationFromLink(mountID, false)
  end
end

--- The secure Mount item: created and configured only out of combat (a protected frame
--- can't be set up during the lockdown), the first time it is needed.
local function EnsureSecureItem()
  if secureItem or InCombatLockdown() then
    return secureItem
  end
  secureItem = CreateFrame("Button", "SteadyCamMountMenuRide", UIParent, "SecureActionButtonTemplate")
  secureItem:SetFrameStrata("FULLSCREEN_DIALOG")
  secureItem:RegisterForClicks("AnyUp", "AnyDown")
  secureItem:SetAttribute("type", "macro")
  secureItem:SetAttribute("macrotext", "")
  ItemLook(secureItem)
  SetItemEnabled(secureItem, true)
  secureItem:SetScript("PostClick", function(self, _, down)
    -- After "Mount" from another mount the game only dismounts you: the menu stays,
    -- updates on the dismount, and a second click mounts.
    if ExecutingEdge(down) and not self.keepOpen then
      CloseMenu()
    end
  end)
  secureItem:Hide()
  return secureItem
end

--- Fill the menu for menuEntry from the current state (also re-run when combat ends or
--- you mount / dismount while it is open).
local function Populate()
  local entry = menuEntry
  if not entry then
    return
  end
  menuTitle:SetText(entry.name)
  local rideLabel, macro, rideReason, keepOpen = RideAction(entry)
  local blocked = Blocked()
  previewItem.text:SetText(blocked and InCombatLockdown() and (L.MENU_PREVIEW .. "  (" .. L.REASON_COMBAT .. ")")
    or L.MENU_PREVIEW)
  SetItemEnabled(previewItem, not InCombatLockdown())
  local calLabel = (entry.own or entry.unmeasurable) and L.MENU_RECALIBRATE or L.MENU_CALIBRATE
  calibrateItem.text:SetText(blocked and (calLabel .. "  (" .. blocked .. ")") or calLabel)
  SetItemEnabled(calibrateItem, not blocked)

  local secure = macro and EnsureSecureItem()
  if secure then
    rideItem:Hide()
    secure.text:SetText(rideLabel)
    secure.keepOpen = keepOpen
  else
    HideSecureItem()
    rideItem:Show()
    rideItem.text:SetText(rideReason and (rideLabel .. "  (" .. rideReason .. ")") or rideLabel)
    SetItemEnabled(rideItem, false)
  end

  -- Wide enough for the longest line in any language (reasons included).
  local w = TextWidth(menuTitle) + 24
  for _, b in ipairs({ secure or rideItem, previewItem, calibrateItem }) do
    w = math.max(w, TextWidth(b.text) + 24)
  end
  w = math.min(math.max(w, MENU_W), 380)
  menu:SetWidth(w)
  rideItem:SetWidth(w - 12)
  previewItem:SetWidth(w - 12)
  calibrateItem:SetWidth(w - 12)

  if secure then -- out of combat here (EnsureSecureItem returns nil in combat)
    secure:SetAttribute("macrotext", macro)
    secure:SetWidth(w - 12)
    secure:ClearAllPoints()
    secure:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -MENU_TOP)
    secure:SetFrameLevel(menu:GetFrameLevel() + 10)
    secure:Show()
  end
end

local function BuildMenu()
  menu = CreateFrame("Frame", "SteadyCamMountMenu", UIParent)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetClampedToScreen(true)
  menu:EnableMouse(true)
  menu:SetWidth(MENU_W)
  W.Box(menu, T.windowBg, T.accent, T.radius)
  menu:Hide()

  menuTitle = W.Bold(menu, "GameFontNormal", T.accent)
  menuTitle:SetPoint("TOPLEFT", 12, -10)
  menuTitle:SetPoint("RIGHT", -10, 0)
  menuTitle:SetWordWrap(false)
  local line = W.Solid(menu, "ARTWORK", T.cardBorder)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT", 8, -30)
  line:SetPoint("TOPRIGHT", -8, -30)

  -- Slot 1, insecure: shown when the secure item can't be (combat, flying, not usable...).
  rideItem = CreateFrame("Button", nil, menu)
  ItemLook(rideItem)
  rideItem:SetPoint("TOPLEFT", 6, -MENU_TOP)

  previewItem = CreateFrame("Button", nil, menu)
  ItemLook(previewItem, L.MENU_PREVIEW)
  previewItem:SetPoint("TOPLEFT", 6, -MENU_TOP - (ITEM_H + 2))
  previewItem:SetScript("OnClick", function(self)
    if self.enabled and menuEntry then
      local id = menuEntry.id
      CloseMenu()
      PC.PreviewMount(id)
    end
  end)

  calibrateItem = CreateFrame("Button", nil, menu)
  ItemLook(calibrateItem)
  calibrateItem:SetPoint("TOPLEFT", 6, -MENU_TOP - 2 * (ITEM_H + 2))
  calibrateItem:SetScript("OnClick", function(self)
    if self.enabled and menuEntry then
      Calibrate(menuEntry.id)
    end
  end)
  menu:SetHeight(MENU_TOP + 3 * (ITEM_H + 2) + 6)

  menu:SetScript("OnHide", function()
    HideSecureItem()
    menuEntry = nil
  end)
  W.EscClosable(menu, "SteadyCamMountMenu")

  -- A click anywhere else closes the menu, like the game's own menus. Combat start takes
  -- it down (before the lockdown: the secure item must be hidden by then); combat end
  -- refreshes an open menu so its items come back.
  local watchAt, lastState = 0, nil
  menu:SetScript("OnUpdate", function(_, elapsed)
    watchAt = watchAt + elapsed
    if watchAt < 0.1 or InCombatLockdown() then
      return
    end
    watchAt = 0
    local state = tostring(IsFlying and IsFlying()) .. tostring(Moving()) .. tostring(IsMounted and IsMounted())
    if state ~= lastState then
      lastState = state
      Populate()
    end
  end)
  menu:RegisterEvent("GLOBAL_MOUSE_DOWN")
  menu:RegisterEvent("PLAYER_REGEN_DISABLED")
  menu:RegisterEvent("PLAYER_REGEN_ENABLED")
  menu:SetScript("OnEvent", function(self, event)
    if not self:IsShown() then
      return
    end
    if event == "PLAYER_REGEN_DISABLED" then
      self:Hide()
    elseif event == "PLAYER_REGEN_ENABLED" then
      Populate()
    elseif not (self:IsMouseOver() or (secureItem and secureItem:IsShown() and secureItem:IsMouseOver())) then
      self:Hide()
    end
  end)
end

local function OpenMenu(row)
  local entry = row and row.entry
  if not entry then
    return
  end
  if not menu then
    BuildMenu()
  end
  GameTooltip:Hide()
  if search then
    search:ClearFocus()
  end
  menuEntry = entry
  -- At the cursor (the menu is clamped to the screen).
  local scale = UIParent:GetEffectiveScale()
  local x, y = GetCursorPosition()
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / scale + 2, (y or 0) / scale - 2)
  menu:Show()
  menu:Raise()
  Populate()
end

---------------------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------------------
local function MaxOffset()
  return math.max(0, #shown - VISIBLE_ROWS)
end

local function ShowRowTooltip(row)
  local m = row.entry
  if not m then
    GameTooltip:Hide()
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(m.name, 1, 1, 1)
  if m.source ~= "" then
    GameTooltip:AddLine(m.source, m.sourceColor[1], m.sourceColor[2], m.sourceColor[3], true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(L.CLICK_OPTIONS, T.good[1], T.good[2], T.good[3])
  GameTooltip:AddLine(L.CTRL_PREVIEW, T.textDim[1], T.textDim[2], T.textDim[3])
  GameTooltip:Show()
end

local function TabLabel(tab)
  return tab == "calibrated" and L.TAB_CALIBRATED or L.TAB_UNCALIBRATED
end

local function Refresh()
  if not win or not win:IsShown() then
    return
  end
  local d = Data()
  local found = {}
  for _, tab in ipairs(TABS) do
    found[tab] = Matches(d[tab])
  end
  shown = found[currentTab]
  offset = math.min(offset, MaxOffset())

  -- Tab counts follow the search, so a match in the other tab is visible at a glance.
  for _, b in ipairs(tabs) do
    local selected = b.tab == currentTab
    local c = selected and { T.accent[1], T.accent[2], T.accent[3], 0.9 } or T.trackOff
    b.bg:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    local tc = selected and { 0.08, 0.08, 0.08 } or T.text
    b.text:SetTextColor(tc[1], tc[2], tc[3])
    b.text:SetText(string.format("%s (%d)", TabLabel(b.tab), #found[b.tab]))
  end
  tabDesc:SetText(currentTab == "calibrated" and string.format(L.TAB_DESC_CALIBRATED, PC.GetModelLabel())
    or L.TAB_DESC_UNCALIBRATED)
  placeholder:SetShown((search:GetText() or "") == "" and not search:HasFocus())

  for i, row in ipairs(rows) do
    local m = shown[offset + i]
    row:SetShown(m ~= nil)
    row.entry = m
    if m then
      local usable = Usable(m.id)
      row.icon:SetTexture(m.icon)
      row.icon:SetDesaturated(not usable)
      row.name:SetText(m.name)
      local nc = usable and T.text or T.textDim
      row.name:SetTextColor(nc[1], nc[2], nc[3])
      row.source:SetText(m.source)
      row.source:SetTextColor(m.sourceColor[1], m.sourceColor[2], m.sourceColor[3])
      local riding = Riding(m.id)
      row.tag:SetText(riding and L.RIDING or (not usable and L.WIZ_NOT_USABLE or ""))
      local tc = riding and T.text or T.textDim
      row.tag:SetTextColor(tc[1], tc[2], tc[3])
      local bg = riding and T.riding or T.trackOff
      row.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
      row.ridingBar:SetShown(riding)
    end
  end

  scrollBar.Update()

  if #shown == 0 then
    local text
    if d.total == 0 then
      text = L.WIZ_NO_MOUNTS_all
    elseif query ~= "" then
      text = string.format(L.NO_MATCH, search:GetText() or "")
      local other = currentTab == "calibrated" and "uncalibrated" or "calibrated"
      if #found[other] > 0 then
        text = text .. "\n\n" .. string.format(L.MATCHES_IN_TAB, #found[other], TabLabel(other))
      end
    elseif currentTab == "calibrated" then
      text = string.format(L.CALIBRATED_NONE, PC.GetModelLabel())
    else
      text = L.ALL_CALIBRATED
    end
    empty:SetText(text)
  end
  empty:SetShown(#shown == 0)
end

local function Invalidate()
  data = nil
  Refresh()
end

local function BuildRow(i)
  local row = CreateFrame("Button", nil, box)
  row:SetSize(INNER - 14, ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.bg = W.Rounded(row, "BACKGROUND", T.trackOff, T.radiusControl)
  row.ridingBar = W.Rounded(row, "BORDER", { T.riding[1] + 0.12, T.riding[2] + 0.16, T.riding[3] + 0.12, 1 },
    1.5, { left = 3, right = INNER - 14 - 6, top = 6, bottom = 6 })
  W.Rounded(row, "HIGHLIGHT", { T.accent[1], T.accent[2], T.accent[3], 0.18 }, T.radiusControl)

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(28, 28)
  row.icon:SetPoint("LEFT", 10, 0) -- clear of the riding bar (x 3..6)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the icon border

  row.tag = W.Text(row, "GameFontHighlightSmall", T.textDim, "RIGHT")
  row.tag:SetWidth(TAG_W)
  row.tag:SetPoint("RIGHT", -10, 0)
  row.tag:SetJustifyV("MIDDLE")
  row.tag:SetWordWrap(false)

  -- Name on the icon's top line, source on its bottom line: both anchored by top or
  -- bottom points only, so each box is one line tall and they can't overlap.
  local right = -(TAG_W + 16)
  row.name = W.Text(row, "GameFontHighlight", T.text)
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 0)
  row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", right, -3)
  row.name:SetWordWrap(false)

  row.source = W.Text(row, "GameFontHighlightSmall", T.textDim)
  row.source:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 0)
  row.source:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", right, 3)
  row.source:SetJustifyV("BOTTOM")
  row.source:SetWordWrap(false)

  row:SetScript("OnClick", function(self)
    if self.entry and PC.HandleMountModifiedClick(self.entry.id) then
      return
    end
    OpenMenu(self)
  end)
  row:SetScript("OnEnter", ShowRowTooltip)
  row:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  return row
end

local function Build()
  win = CreateFrame("Frame", "SteadyCamMounts", UIParent)
  win:SetFrameStrata("HIGH") -- the game's dialogs (DIALOG) stay in front of it
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    userMoved = true -- the player chose a spot: keep it until the window reopens
  end)
  W.Box(win, T.windowBg, T.windowBorder, T.radiusWindow)
  W.WindowHeader(win, PAD, -HEADER_TOP, HEADER_H, L.MOUNTS_TITLE)
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local y = HEADER_TOP + HEADER_H + 14
  local hint = W.Text(win, "GameFontHighlight", T.text)
  hint:SetWidth(INNER)
  hint:SetPoint("TOPLEFT", PAD, -y)
  hint:SetText(L.MOUNTS_HINT)
  y = y + hint:GetStringHeight() + 10

  -- Search: filters both tabs as you type (ignoring case and accents); Esc / Enter
  -- leave the box; clicking anything else in the window releases the keyboard too.
  search = CreateFrame("EditBox", nil, win)
  search:SetSize(INNER, 26)
  search:SetPoint("TOPLEFT", PAD, -y)
  search:SetAutoFocus(false)
  search:SetFontObject("GameFontHighlight")
  search:SetTextInsets(26, 8, 0, 0)
  W.Box(search, T.previewBg, T.cardBorder, T.radiusControl)
  local glass = search:CreateTexture(nil, "ARTWORK")
  glass:SetSize(14, 14)
  glass:SetPoint("LEFT", 7, 0)
  glass:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
  glass:SetVertexColor(T.textDim[1], T.textDim[2], T.textDim[3])
  placeholder = W.Text(search, "GameFontHighlight", T.textDim)
  placeholder:SetPoint("LEFT", 26, 0)
  placeholder:SetText(L.SEARCH)
  search:SetScript("OnTextChanged", function(self)
    query = W.Fold(self:GetText() or "")
    offset = 0
    Refresh()
  end)
  search:SetScript("OnEditFocusGained", Refresh)
  search:SetScript("OnEditFocusLost", Refresh)
  search:SetScript("OnEscapePressed", search.ClearFocus)
  search:SetScript("OnEnterPressed", search.ClearFocus)
  y = y + 26 + 10

  local tabW = (INNER - 6) / #TABS
  for i, tab in ipairs(TABS) do
    local b = CreateFrame("Button", nil, win)
    b:SetSize(tabW, 26)
    b:SetPoint("TOPLEFT", PAD + (i - 1) * (tabW + 6), -y)
    b.bg = W.Rounded(b, "BACKGROUND", T.trackOff, T.radiusControl)
    W.Rounded(b, "HIGHLIGHT", { 1, 1, 1, 0.08 }, T.radiusControl)
    b.text = W.Text(b, "GameFontHighlightSmall", T.text, "CENTER")
    b.text:SetPoint("CENTER")
    b.tab = tab
    b:SetScript("OnClick", function()
      search:ClearFocus()
      CloseMenu()
      currentTab = tab
      offset = 0
      Refresh()
    end)
    tabs[i] = b
  end
  y = y + 26 + 8

  tabDesc = W.Text(win, "GameFontHighlightSmall", T.textDim)
  tabDesc:SetWidth(INNER)
  tabDesc:SetPoint("TOPLEFT", PAD, -y)
  y = y + 50 -- room for up to three lines in any language (with line spacing)

  box = CreateFrame("Frame", nil, win)
  box:SetSize(INNER, VISIBLE_ROWS * (ROW_H + ROW_GAP) - ROW_GAP)
  box:SetPoint("TOPLEFT", PAD, -y)
  box:EnableMouseWheel(true)
  local function ScrollTo(value)
    local new = math.min(MaxOffset(), math.max(0, math.floor(value + 0.5)))
    if new ~= offset then
      offset = new
      CloseMenu()
      Refresh()
      -- The row under the mouse now shows another mount: refresh its tooltip.
      for _, row in ipairs(rows) do
        if row:IsShown() and row:IsMouseOver() then
          ShowRowTooltip(row)
        end
      end
    end
  end
  box:SetScript("OnMouseWheel", function(_, delta)
    ScrollTo(offset - delta * 2)
  end)
  for i = 1, VISIBLE_ROWS do
    rows[i] = BuildRow(i)
  end
  scrollBar = W.ScrollBar(box, {
    get = function()
      return offset, MaxOffset(), VISIBLE_ROWS, #shown
    end,
    set = ScrollTo,
  })
  scrollBar:SetPoint("TOPRIGHT")
  scrollBar:SetPoint("BOTTOMRIGHT")
  empty = W.Text(box, "GameFontHighlight", T.textDim, "CENTER")
  empty:SetWidth(INNER - 20)
  empty:SetPoint("TOP", 0, -40)

  win:SetSize(WIDTH, y + box:GetHeight() + PAD)
  -- New frames start shown but unanchored (drawn nowhere): start hidden, and let
  -- PC.OpenMounts place it each time it opens.
  win:SetPoint("CENTER")
  win:Hide()
  win:SetScript("OnShow", function()
    Refresh() -- the lists are cached; events keep them current
    PC.Fire("MOUNTS_WINDOW", true) -- the main window's button now reads "Close my mounts"
  end)
  win:SetScript("OnHide", function()
    search:ClearFocus()
    CloseMenu()
    GameTooltip:Hide()
    PC.Fire("MOUNTS_WINDOW", false)
  end)
  W.EscClosable(win, "SteadyCamMounts")
end

--- Next to the SteadyCam window: on its right when the mounts window fits there, else on
--- its left; if it fits on neither side, on the side with more room. Centered when the
--- SteadyCam window is closed.
local GAP = 10

local function Place(makeRoom)
  win:ClearAllPoints()
  local main = _G.SteadyCamWindow
  local left, right = main and main:IsShown() and main:GetLeft(), main and main:IsShown() and main:GetRight()
  local screen = UIParent:GetRight()
  if not (left and right and screen) then
    win:SetPoint("CENTER")
    return
  end
  local roomRight, roomLeft = screen - right, left
  local need = WIDTH + GAP
  local top = main:GetTop()
  if makeRoom and top and roomRight < need and roomLeft < need and screen >= (right - left) + need then
    -- Fits on neither side, but the pair fits on screen: slide the SteadyCam window over
    -- so the two sit side by side, centered.
    local newLeft = (screen - (right - left) - need) / 2
    main:ClearAllPoints()
    main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newLeft, top)
    roomRight, roomLeft = screen - (newLeft + (right - left)), newLeft
  end
  if roomRight >= need or (roomLeft < need and roomRight >= roomLeft) then
    win:SetPoint("TOPLEFT", main, "TOPRIGHT", GAP, 0)
  else
    win:SetPoint("TOPRIGHT", main, "TOPLEFT", -GAP, 0)
  end
end

--- Re-place while the SteadyCam window is dragged (unless the player moved this one).
function PC.PlaceMounts()
  if win and win:IsShown() and not userMoved then
    Place()
  end
end

function PC.MountsShown()
  return win ~= nil and win:IsShown()
end

function PC.CloseMounts()
  if win then
    win:Hide()
  end
end

--- Open the mounts window. tab: optional ("calibrated" / "uncalibrated").
function PC.OpenMounts(tab)
  if not win then
    Build()
  end
  if tab then
    currentTab = tab
  end
  offset = 0
  search:SetText("")
  query = ""
  if win:IsShown() then
    Refresh()
  else
    userMoved = false
    Place(true)
    win:Show() -- OnShow refreshes
  end
  win:Raise()
end

-- Screen size or UI scale changed: the sides may have swapped.
local placer = CreateFrame("Frame")
for _, event in ipairs({ "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
  pcall(placer.RegisterEvent, placer, event)
end
placer:SetScript("OnEvent", function()
  PC.PlaceMounts()
end)

-- Usability, combat, riding: refresh what is shown (cheap). Learning a mount or a new
-- calibration: rebuild the cached lists. An open menu follows mount / dismount.

local watcher = CreateFrame("Frame")
for _, event in ipairs({ "ZONE_CHANGED_INDOORS", "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA",
  "MOUNT_JOURNAL_USABILITY_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
  pcall(watcher.RegisterEvent, watcher, event)
end
watcher:SetScript("OnEvent", Refresh)
local learned = CreateFrame("Frame")
for _, event in ipairs({ "NEW_MOUNT_ADDED", "COMPANION_LEARNED" }) do
  pcall(learned.RegisterEvent, learned, event)
end
learned:SetScript("OnEvent", Invalidate)
for _, event in ipairs({ "PROFILE_READY", "CALIBRATION_UPDATED" }) do
  PC.On(event, Invalidate)
end
for _, event in ipairs({ "MOUNT_SWAP", "MOUNT_IDENTIFIED" }) do
  PC.On(event, function()
    Refresh()
    if menu and menu:IsShown() and not InCombatLockdown() then
      Populate()
    end
  end)
end
-- A calibration takes over the screen: close the list (it opens again from the window).
PC.On("CALIBRATION_STATE", function()
  if win and win:IsShown() and Calibrating() then
    win:Hide()
  end
end)

-- For the offline tests.
PC.MountsWindow = {
  OpenMenu = OpenMenu,
  Data = Data,
  Menu = function()
    return menu, secureItem, rideItem, calibrateItem, previewItem
  end,
  Search = function()
    return search
  end,
  Empty = function()
    return empty
  end,
}
