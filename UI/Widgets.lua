---------------------------------------------------------------------------------------
--  UI/Widgets.lua — small control kit for the SteadyCam window
---------------------------------------------------------------------------------------
--  Every control is a Frame with :Refresh() (re-reads get(), disabled()) and a height
--  that cards use to stack it. W.RefreshAll() refreshes all of them. Options:
--    label, desc, get(), set(v), disabled() — plus control-specific fields below.
---------------------------------------------------------------------------------------
local _, PC = ...
local _G = _G

local CreateFrame = _G.CreateFrame
local GameTooltip = _G.GameTooltip

local T = PC.Theme
local W = {}
PC.Widgets = W

local registry = {}

function W.RefreshAll()
  for i = 1, #registry do
    registry[i]:Refresh()
  end
end

local function Register(f)
  registry[#registry + 1] = f
  return f
end
W.Register = Register

local function IsDisabled(o)
  if type(o.disabled) == "function" then
    return o.disabled() and true or false
  end
  return o.disabled == true
end

local function Solid(parent, layer, c)
  local tex = parent:CreateTexture(nil, layer)
  tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return tex
end
W.Solid = Solid

function W.Border(frame, c, size)
  size = size or 1
  local top = Solid(frame, "BORDER", c)
  top:SetPoint("TOPLEFT")
  top:SetPoint("TOPRIGHT")
  top:SetHeight(size)
  local bottom = Solid(frame, "BORDER", c)
  bottom:SetPoint("BOTTOMLEFT")
  bottom:SetPoint("BOTTOMRIGHT")
  bottom:SetHeight(size)
  local left = Solid(frame, "BORDER", c)
  left:SetPoint("TOPLEFT")
  left:SetPoint("BOTTOMLEFT")
  left:SetWidth(size)
  local right = Solid(frame, "BORDER", c)
  right:SetPoint("TOPRIGHT")
  right:SetPoint("BOTTOMRIGHT")
  right:SetWidth(size)
  return { top, bottom, left, right }
end

---------------------------------------------------------------------------------------
-- Text helpers for every client language. string.upper / lower only know A-Z, so
-- "Calibración":upper() gave "CALIBRACIóN". W.Upper also maps accented Latin and
-- Cyrillic letters; W.Fold makes a search key that ignores case and accents.
---------------------------------------------------------------------------------------
-- (No %z: names never hold NUL bytes, and Lua 5.2+ dropped that class.)
local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"
local UPPER, LOWER, PLAIN = {}, {}, {}

local function Chars(s)
  local t = {}
  for c in s:gmatch(UTF8_CHAR) do
    t[#t + 1] = c
  end
  return t
end

local function CasePairs(lower, upper)
  local l, u = Chars(lower), Chars(upper)
  for i = 1, #l do
    UPPER[l[i]], LOWER[u[i]] = u[i], l[i]
  end
end
CasePairs("àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿœ", "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞŸŒ")
CasePairs("абвгдеёжзийклмнопрстуфхцчшщъыьэюя", "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
for base, accented in pairs({ a = "àáâãäå", c = "ç", e = "èéêë", i = "ìíîï", n = "ñ", o = "òóôõöø",
  u = "ùúûü", y = "ýÿ", ["е"] = "ё" }) do
  for _, c in ipairs(Chars(accented)) do
    PLAIN[c] = base
  end
end

function W.Upper(s)
  return (s:upper():gsub(UTF8_CHAR, function(c)
    return UPPER[c]
  end))
end

--- Search key: lower case, no accents ("Águila" and "aguila" match).
function W.Fold(s)
  return (s:lower():gsub(UTF8_CHAR, function(c)
    c = LOWER[c] or c
    return PLAIN[c] or c
  end))
end

---------------------------------------------------------------------------------------
-- Esc closes only the topmost SteadyCam window. Blizzard's CloseSpecialWindows() hides
-- every shown frame listed in UISpecialFrames at once, so only the window opened last
-- is listed; when it closes, the one under it is listed again. (Deferred a frame:
-- UISpecialFrames may be mid-iteration when a window hides.)
---------------------------------------------------------------------------------------
local escNames, escStack = {}, {}

local function SyncEsc()
  local list = _G.UISpecialFrames
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if escNames[list[i]] then
      table.remove(list, i)
    end
  end
  if escStack[#escStack] then
    list[#list + 1] = escStack[#escStack]
  end
end

local function Unstack(name)
  for i = #escStack, 1, -1 do
    if escStack[i] == name then
      table.remove(escStack, i)
    end
  end
end

local function Later(fn)
  if _G.C_Timer then
    _G.C_Timer.After(0, fn)
  else
    fn()
  end
end

function W.EscClosable(frame, name)
  escNames[name] = true
  frame:HookScript("OnShow", function()
    Unstack(name)
    escStack[#escStack + 1] = name
    Later(SyncEsc)
  end)
  frame:HookScript("OnHide", function()
    Unstack(name)
    Later(SyncEsc)
  end)
end

function W.Text(parent, font, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  if color then
    fs:SetTextColor(color[1], color[2], color[3])
  end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetJustifyV("TOP")
  local path, size, flags = fs:GetFont()
  if path and size and (T.fontBump or 0) ~= 0 then
    fs:SetFont(path, size + T.fontBump, flags or "")
  end
  if fs.SetSpacing then
    fs:SetSpacing(T.lineSpacing or 0)
  end
  return fs
end

--- Wrapped description under a control; returns the fontstring and its height.
local function Desc(parent, text, width, anchorY)
  if not text or text == "" then
    return nil, 0
  end
  local fs = W.Text(parent, "GameFontHighlightSmall", T.textDim)
  fs:SetWidth(width)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -anchorY)
  fs:SetText(text)
  return fs, fs:GetStringHeight()
end

---------------------------------------------------------------------------------------
-- The carvibox style kit (DESIGN.md): rounded shapes, bold titles, window header, signature.
---------------------------------------------------------------------------------------
--- A rounded rectangle: 4 corner textures (T.corner, tinted) + 3 bands, no overlaps.
--- Textures belong to `frame` (its draw layers); geometry follows o.anchor (default
--- `frame`) minus insets o.left/right/top/bottom (o.x / o.y for both sides; negative
--- = outside). o.sublevel orders it inside its layer. The returned object answers
--- SetColorTexture / SetShown / Show / Hide / IsShown / SetAlpha like a texture.
function W.Rounded(frame, layer, color, radius, o)
  o = o or {}
  local anchor = o.anchor or frame
  local r = radius or T.radius
  local l, rt = o.left or o.x or 0, o.right or o.x or 0
  local tp, bt = o.top or o.y or 0, o.bottom or o.y or 0
  local corners, bands, all = {}, {}, {}
  local function New()
    local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, o.sublevel or 0)
    all[#all + 1] = t
    return t
  end
  for _, c in ipairs({
    { "TOPLEFT", 0, 1, 0, 1, l, -tp },
    { "TOPRIGHT", 1, 0, 0, 1, -rt, -tp },
    { "BOTTOMLEFT", 0, 1, 1, 0, l, bt },
    { "BOTTOMRIGHT", 1, 0, 1, 0, -rt, bt },
  }) do
    local t = New()
    t:SetTexture(T.corner)
    t:SetTexCoord(c[2], c[3], c[4], c[5])
    t:SetSize(r, r)
    t:SetPoint(c[1], anchor, c[1], c[6], c[7])
    corners[#corners + 1] = t
  end
  local top = New()
  top:SetPoint("TOPLEFT", anchor, "TOPLEFT", l + r, -tp)
  top:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", -(rt + r), -(tp + r))
  local bottom = New()
  bottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", l + r, bt)
  bottom:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", -(rt + r), bt + r)
  local middle = New()
  middle:SetPoint("TOPLEFT", anchor, "TOPLEFT", l, -(tp + r))
  middle:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -rt, bt + r)
  bands = { top, bottom, middle }

  local shape = {}
  function shape:SetColorTexture(cr, cg, cb, ca)
    for _, t in ipairs(corners) do
      t:SetVertexColor(cr, cg, cb, ca or 1)
    end
    for _, t in ipairs(bands) do
      t:SetColorTexture(cr, cg, cb, ca or 1)
    end
  end
  function shape:SetShown(v)
    for _, t in ipairs(all) do
      t:SetShown(v)
    end
  end
  function shape:Show()
    shape:SetShown(true)
  end
  function shape:Hide()
    shape:SetShown(false)
  end
  function shape:IsShown()
    return all[1]:IsShown()
  end
  function shape:SetAlpha(a)
    for _, t in ipairs(all) do
      t:SetAlpha(a)
    end
  end
  function shape:SetAllPoints() end -- it always fills its anchor
  shape:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
  return shape
end

--- A rounded box: fill + optional border of `size` (default 1) around it. box:SetColorTexture
--- recolors the fill, box:SetBorderColor the border (same color as the fill = no border).
--- The border is a whole shape under the fill, so a box with a border needs an opaque fill.
function W.Box(frame, bg, border, radius, size, layer)
  local r, sz = radius or T.radius, size or 1
  local box = {}
  if border then
    box.border = W.Rounded(frame, layer, border, r, { sublevel = 1 })
  end
  local inset = border and sz or 0
  box.bg = W.Rounded(frame, layer, bg, math.max(1, r - inset), { x = inset, y = inset, sublevel = 2 })
  function box:SetColorTexture(...)
    box.bg:SetColorTexture(...)
  end
  function box:SetBorderColor(...)
    if box.border then
      box.border:SetColorTexture(...)
    end
  end
  function box:SetShown(v)
    box.bg:SetShown(v)
    if box.border then
      box.border:SetShown(v)
    end
  end
  function box:SetAllPoints() end
  return box
end

--- Bold text: the game has no bold UI font, so a twin is drawn about one pixel to the right.
--- Left-justified, for titles; `extra` points larger.
function W.Bold(parent, font, color, extra)
  local fs = W.Text(parent, font, color)
  local twin = W.Text(parent, font, color)
  local path, size, flags = fs:GetFont()
  if path and size and extra then
    fs:SetFont(path, size + extra, flags or "")
    twin:SetFont(path, size + extra, flags or "")
  end
  if twin.SetShadowColor then
    twin:SetShadowColor(0, 0, 0, 0) -- one shadow is enough
  end
  -- Same box as the title, shifted by whole screen pixels (at least one): a fraction of a
  -- pixel can round to nothing and the title would not look bold.
  local function Place()
    local dx = 0.6
    local PU = _G.PixelUtil
    if PU and PU.GetNearestPixelSize and fs.GetEffectiveScale then
      dx = PU.GetNearestPixelSize(0.6, fs:GetEffectiveScale(), 1)
    end
    twin:ClearAllPoints()
    twin:SetPoint("TOPLEFT", fs, "TOPLEFT", dx, 0)
    twin:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", dx, 0)
  end
  Place()
  for _, method in ipairs({ "SetText", "SetTextColor", "SetWidth", "SetShown", "Show", "Hide", "SetAlpha",
    "SetWordWrap", "SetJustifyH", "SetJustifyV" }) do
    local original = fs[method]
    fs[method] = function(self, ...)
      original(self, ...)
      twin[method](twin, ...)
      if method == "SetText" then
        Place() -- follows a UI scale change
      end
    end
  end
  return fs
end

--- A wordmark (T.wordmark / T.wordmarkSolo), `height` units tall, cropped to its art.
function W.Wordmark(frame, art, height, layer)
  local tex = frame:CreateTexture(nil, layer or "ARTWORK")
  tex:SetTexture(art.path)
  tex:SetTexCoord(art.x0 / art.w, art.x1 / art.w, art.y0 / art.h, art.y1 / art.h)
  tex:SetSize(height * (art.x1 - art.x0) / (art.y1 - art.y0), height)
  return tex
end

--- Window header: the framed wordmark, `height` tall, its top-left at (x, y). A secondary
--- window adds what it is for beside it, after a thin divider. Anything placed beside the
--- wordmark lines up with the middle of its letters: the third return value, `mid`, is that
--- y offset (negative) from the wordmark's top, for SetPoint(..., mark, "TOPRIGHT", dx, mid).
function W.WindowHeader(frame, x, y, height, purpose)
  local mark = W.Wordmark(frame, T.wordmarkSolo, height)
  mark:SetPoint("TOPLEFT", x, y)
  local mid = -height * T.wordmarkSolo.letters
  local title
  if purpose then
    local bar = Solid(frame, "ARTWORK", { 1, 1, 1, 0.15 })
    bar:SetSize(1, height * 0.45)
    bar:SetPoint("CENTER", mark, "TOPRIGHT", 10, mid)
    title = W.Bold(frame, "GameFontNormalLarge", T.text)
    title:SetPoint("LEFT", mark, "TOPRIGHT", 20, mid)
    title:SetText(purpose)
  end
  return mark, title, mid
end

--- The author's mark: small, gold, quiet, bottom-right of an addon's main window.
function W.Signature(frame, right, bottom)
  local fs = W.Text(frame, "GameFontNormalSmall", T.accent, "RIGHT")
  local path, size, flags = fs:GetFont()
  if path and size then
    fs:SetFont(path, size - 1.5, flags or "") -- a touch under the smallest text around it
  end
  fs:SetPoint("BOTTOMRIGHT", -(right or 12), bottom or 6)
  fs:SetText(T.signature)
  fs:SetAlpha(0.5)
  return fs
end

local function CircleTexture(parent, layer, size, c)
  local tex = parent:CreateTexture(nil, layer)
  tex:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
  tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
  tex:SetSize(size, size)
  return tex
end

---------------------------------------------------------------------------------------
-- Slider: label + value, an arrow on each side of the track, end captions, description.
--   min, max, step, format ("%.2f"), default (right-click resets),
--   leftText / centerText / rightText (captions under the track),
--   arrowStep (optional: what one arrow click adds; default from the range, see NudgeStep)
---------------------------------------------------------------------------------------
local BALL, BALL_HOVER, BALL_DRAG = 14, 17, 11 -- the slider's ball: still, under the cursor, dragged
local ARROW_W, ARROW_GAP = 18, 4 -- arrow button width, and its gap to the track
local ARROW, ARROW_PRESSED = 16, 13 -- arrow glyph size (texture box), still and pressed

--- What one arrow click adds: about 1/40 of the range, as a round number (1, 2 or 5 × 10^n)
--- and a whole number of slider steps. -1..1 gives 0.05, -8..8 gives 0.5, 10..200 gives 5.
local function NudgeStep(o)
  if o.arrowStep then
    return o.arrowStep
  end
  local raw = (o.max - o.min) / 40
  local mag = 10 ^ math.floor(math.log(raw) / math.log(10))
  local nice = mag
  for _, m in ipairs({ 2, 5, 10 }) do
    if math.abs(math.log(m * mag / raw)) < math.abs(math.log(nice / raw)) then
      nice = m * mag
    end
  end
  return math.max(1, math.floor(nice / o.step + 0.5)) * o.step
end
W.NudgeStep = NudgeStep

function W.Slider(parent, o, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(width)

  local label = W.Text(f, "GameFontHighlight", T.text)
  label:SetPoint("TOPLEFT")
  label:SetText(o.label)
  local value = W.Text(f, "GameFontNormal", T.accent, "RIGHT")
  value:SetPoint("TOPRIGHT")

  -- The track is a plain frame, not the game's Slider: on a click the game's slider puts the
  -- ball's center under the cursor and snaps down a step, so pressing the ball left of its
  -- center moved the value back. Here a pressed ball is grabbed where it was pressed.
  local inset = ARROW_W + ARROW_GAP
  local slider = CreateFrame("Frame", nil, f)
  slider:SetHeight(18)
  slider:SetPoint("TOPLEFT", inset, -20)
  slider:SetPoint("TOPRIGHT", -inset, -20)
  slider:SetHitRectInsets(0, 0, -4, -4)
  slider:EnableMouse(true)

  local track = Solid(slider, "BACKGROUND", T.trackOff)
  track:SetHeight(4)
  track:SetPoint("LEFT")
  track:SetPoint("RIGHT")
  local fill = Solid(slider, "ARTWORK", { T.accent[1], T.accent[2], T.accent[3], 0.9 })
  fill:SetHeight(4)
  fill:SetPoint("LEFT")
  local zero
  if o.min < 0 and o.max > 0 then
    zero = Solid(slider, "ARTWORK", T.textDim)
    zero:SetSize(1, 10)
  end
  local ball = CircleTexture(slider, "OVERLAY", BALL, { 0.92, 0.92, 0.92, 1 })
  ball:SetPoint("CENTER", slider, "LEFT", BALL / 2, 0)
  f.slider, f.ball = slider, ball

  -- current: the value in range (ball, fill, arrows). stored: the value as saved, which can be
  -- out of range when it was set elsewhere (e.g. a turn speed from the game).
  local current, stored = o.min, o.min
  local function Round(v)
    return math.floor(v / o.step + 0.5) * o.step
  end
  local function IsMuted()
    return o.muted and o.muted() or false
  end

  -- The ball stays inside the track: its center travels from BALL/2 to w - BALL/2.
  local function At(v)
    local w = slider:GetWidth() or 0
    return BALL / 2 + math.max(0, w - BALL) * (v - o.min) / (o.max - o.min)
  end
  local function ValueAt(x)
    local w = slider:GetWidth() or 0
    if w <= BALL then
      return current
    end
    return o.min + (x - BALL / 2) / (w - BALL) * (o.max - o.min)
  end
  -- The cursor relative to the track: x from its left edge, y from its middle.
  local function Cursor()
    local left, top, h = slider:GetLeft(), slider:GetTop(), slider:GetHeight()
    if not (left and top and h) then
      return nil
    end
    local x, y = _G.GetCursorPosition()
    local s = slider:GetEffectiveScale()
    return x / s - left, y / s - (top - h / 2)
  end

  local arrows = {}
  local function Paint(v)
    stored = v
    current = math.max(o.min, math.min(o.max, v))
    for _, b in ipairs(arrows) do
      b.Paint()
    end
    value:SetText(string.format(o.format or "%.2f", v)) -- as stored, even out of range
    local w = slider:GetWidth()
    if w and w > 0 then
      ball:ClearAllPoints()
      ball:SetPoint("CENTER", slider, "LEFT", At(current), 0)
      fill:SetWidth(math.max(1, At(current))) -- ends under the ball's center, whatever its size
      if zero then
        zero:SetPoint("CENTER", slider, "LEFT", At(0), 0)
      end
    end
  end
  -- A value from the user: on the step grid, in range, saved only when it changes.
  local function Commit(v)
    v = Round(math.max(o.min, math.min(o.max, v)))
    if math.abs(v - stored) < o.step / 2 then
      return false
    end
    Paint(v)
    o.set(v)
    return true
  end

  -- Arrows: one click moves the value by NudgeStep. Hover lights up that arrow only, a press
  -- sinks it; at the end of the range it fades and does nothing.
  local nudge = NudgeStep(o)
  local light = {}
  for i = 1, 3 do
    light[i] = T.accent[i] + (1 - T.accent[i]) * 0.4
  end
  local function Arrow(dir)
    local b = CreateFrame("Button", nil, f)
    b:SetSize(ARROW_W, 18)
    b:SetPoint(dir < 0 and "TOPLEFT" or "TOPRIGHT", 0, -20)
    local glyph = b:CreateTexture(nil, "ARTWORK")
    glyph:SetTexture(T.arrow)
    if dir < 0 then
      glyph:SetTexCoord(1, 0, 0, 1) -- the texture points right
    end
    glyph:SetPoint("CENTER")
    b.glyph = glyph
    local function AtLimit()
      return dir < 0 and current <= o.min + o.step / 2 or dir > 0 and current >= o.max - o.step / 2
    end
    function b.Paint()
      local limit = AtLimit()
      local live = not IsDisabled(o) and not limit
      local c = (live and b.over) and light or T.accent
      glyph:SetVertexColor(c[1], c[2], c[3], 1)
      glyph:SetAlpha(limit and 0.3 or 1)
      local size = (live and b.down) and ARROW_PRESSED or ARROW
      glyph:SetSize(size, size)
    end
    b:SetScript("OnEnter", function()
      b.over = true
      b.Paint()
    end)
    b:SetScript("OnLeave", function()
      b.over, b.down = false, false
      b.Paint()
    end)
    b:SetScript("OnMouseDown", function(_, button)
      b.down = button == "LeftButton"
      b.Paint()
    end)
    b:SetScript("OnMouseUp", function()
      b.down = false
      b.Paint()
    end)
    b:SetScript("OnClick", function()
      if IsDisabled(o) then
        return
      end
      if not AtLimit() then
        Commit(current + dir * nudge)
      elseif IsMuted() then
        o.set(current) -- touching a muted slider takes the value back
      end
    end)
    glyph:SetSize(ARROW, ARROW) -- Refresh paints the rest
    glyph:SetVertexColor(T.accent[1], T.accent[2], T.accent[3], 1)
    arrows[#arrows + 1] = b
    return b
  end
  f.lower, f.higher = Arrow(-1), Arrow(1)

  -- The ball: a little bigger under the cursor, a little smaller while dragged. Pressed
  -- anywhere on it, it stays put and follows the cursor from there; pressed elsewhere on the
  -- track, it jumps to the cursor and follows it.
  local REACH = BALL_HOVER / 2 + 1 -- how far from the ball's center counts as "on the ball"
  local hovering, dragging, grab, ballSize = false, false, 0, BALL
  local function OverBall()
    local x, y = Cursor()
    return x ~= nil and (x - At(current)) ^ 2 + y ^ 2 <= REACH * REACH
  end
  local function Animate(_, elapsed)
    if dragging and _G.IsMouseButtonDown and not _G.IsMouseButtonDown("LeftButton") then
      dragging = false -- released where the track did not hear it
    end
    if dragging and IsDisabled(o) then
      dragging = false
    end
    if dragging then
      local x = Cursor()
      if x then
        Commit(ValueAt(x - grab))
      end
    end
    local target = BALL
    if not IsDisabled(o) then
      if dragging then
        target = BALL_DRAG
      elseif hovering and OverBall() then
        target = BALL_HOVER
      end
    end
    ballSize = ballSize + (target - ballSize) * math.min(1, (elapsed or 1) * 18)
    if math.abs(target - ballSize) < 0.05 then
      ballSize = target
    end
    ball:SetSize(ballSize, ballSize)
    if not hovering and not dragging and ballSize == BALL then
      slider:SetScript("OnUpdate", nil)
    end
  end
  local function Wake()
    slider:SetScript("OnUpdate", Animate)
  end
  slider:SetScript("OnEnter", function()
    hovering = true
    Wake()
  end)
  slider:SetScript("OnLeave", function()
    hovering = false
    Wake()
  end)
  slider:SetScript("OnMouseDown", function(_, button)
    if IsDisabled(o) then
      return
    end
    -- Touching a muted slider takes the value back, even without moving it.
    if IsMuted() then
      o.set(current)
    end
    local x = button == "LeftButton" and Cursor()
    if not x then
      return
    end
    local ballX = At(current)
    if math.abs(x - ballX) <= REACH then
      grab = x - ballX -- on the ball: nothing moves until the cursor does
    else
      grab = 0
      Commit(ValueAt(x))
    end
    dragging = true
    Wake()
  end)
  slider:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      dragging = false
      Wake()
    end
    if button == "RightButton" and o.default ~= nil and not IsDisabled(o) then
      Commit(o.default)
    end
  end)
  slider:SetScript("OnSizeChanged", function()
    Paint(stored)
  end)
  slider:SetScript("OnHide", function()
    dragging, hovering = false, false -- the window closed mid-drag: no press is carried over
  end)

  local dimmable = { label, value, slider, f.lower, f.higher }
  local y = 42
  local captions = o.leftText or o.rightText or o.centerText
  if captions then
    -- Under the ends of the track, not under the arrows.
    local left = W.Text(f, "GameFontDisableSmall", T.textDim)
    left:SetPoint("TOPLEFT", inset, -40)
    left:SetText(o.leftText or "")
    local right = W.Text(f, "GameFontDisableSmall", T.textDim, "RIGHT")
    right:SetPoint("TOPRIGHT", -inset, -40)
    right:SetText(o.rightText or "")
    dimmable[#dimmable + 1] = left
    dimmable[#dimmable + 1] = right
    if o.centerText then
      local center = W.Text(f, "GameFontDisableSmall", T.textDim, "CENTER")
      center:SetPoint("TOP", 0, -40)
      center:SetText(o.centerText)
      dimmable[#dimmable + 1] = center
    end
    y = y + 14
  end
  local descFs, descH = Desc(f, o.desc, width, y + 6)
  if descFs and o.mutedDesc then
    descFs:SetText(o.mutedDesc)
    descH = math.max(descH, descFs:GetStringHeight())
    descFs:SetText(o.desc)
  end
  f:SetHeight(y + (descH > 0 and descH + 10 or 0))

  function f.Refresh()
    Paint(Round(o.get()))
    local disabled = IsDisabled(o)
    local muted = IsMuted() and not disabled
    for _, b in ipairs(arrows) do
      b:SetEnabled(not disabled)
      b.Paint()
    end
    -- Disabled: everything dims. Muted (set elsewhere, still usable): the control dims,
    -- the hint saying how to take it back stays fully readable.
    f:SetAlpha(disabled and T.disabledAlpha or 1)
    for _, region in ipairs(dimmable) do
      region:SetAlpha(muted and T.disabledAlpha or 1)
    end
    if descFs and o.mutedDesc then
      descFs:SetText(muted and o.mutedDesc or o.desc)
      local c = muted and T.text or T.textDim
      descFs:SetTextColor(c[1], c[2], c[3])
    end
    if o.shown then
      f:SetShown(o.shown())
    end
  end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Toggle: switch + label + description. Click anywhere on the row.
---------------------------------------------------------------------------------------
function W.Toggle(parent, o, width)
  local f = CreateFrame("Button", nil, parent)
  f:SetWidth(width)

  local trackArea = CreateFrame("Frame", nil, f) -- geometry only; the pill draws on f
  trackArea:SetSize(34, 16)
  trackArea:SetPoint("TOPLEFT", 0, -1)
  local track = W.Rounded(f, "ARTWORK", T.trackOff, 8, { anchor = trackArea })
  local knob = CircleTexture(f, "OVERLAY", 12, { 0.95, 0.95, 0.95, 1 })

  local label = W.Text(f, "GameFontHighlight", T.text)
  label:SetPoint("TOPLEFT", 44, 0)
  label:SetText(o.label)
  local descFs = W.Text(f, "GameFontHighlightSmall", T.textDim)
  descFs:SetWidth(width - 44)
  descFs:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
  descFs:SetText(o.desc or "")
  local descH = o.desc and (6 + descFs:GetStringHeight() + 4) or 0
  f:SetHeight(math.max(18, label:GetStringHeight() + descH))

  local hover = W.Rounded(f, "BACKGROUND", T.hover, T.radiusControl, { x = -6, y = -3 })
  hover:Hide()
  f:SetScript("OnEnter", function()
    if not IsDisabled(o) then
      hover:Show()
    end
  end)
  f:SetScript("OnLeave", function()
    hover:Hide()
  end)
  f:SetScript("OnClick", function()
    if not IsDisabled(o) then
      o.set(not o.get())
    end
  end)

  function f.Refresh()
    local on = o.get() and true or false
    local c = on and T.toggleOn or T.trackOff
    track:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    knob:ClearAllPoints()
    knob:SetPoint("CENTER", trackArea, on and "RIGHT" or "LEFT", on and -8 or 8, 0)
    local disabled = IsDisabled(o)
    f:SetAlpha(disabled and T.disabledAlpha or 1)
    if o.shown then
      f:SetShown(o.shown())
    end
  end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Segmented choice: one button per option; the selected one is gold.
--   options = { {value, text}, ... }, descFor(value) → text under the buttons
---------------------------------------------------------------------------------------
function W.Segmented(parent, o, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(width)
  local label = W.Text(f, "GameFontHighlight", T.text)
  label:SetPoint("TOPLEFT")
  label:SetText(o.label)

  local n = #o.options
  local gap = 6
  local bw = (width - gap * (n - 1)) / n
  -- o.recommended = an option value: thick gold border + a small "recommended" line.
  local bh = o.recommended and 36 or 26
  local dark = { 0.08, 0.08, 0.08 }
  local buttons = {}
  for i, opt in ipairs(o.options) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(bw, bh)
    b:SetPoint("TOPLEFT", (i - 1) * (bw + gap), -20)
    local recommended = opt[1] == o.recommended
    b.bg = W.Box(b, T.trackOff, recommended and T.accent or nil, T.radiusControl, 2)
    b.hover = W.Rounded(b, "HIGHLIGHT", { 1, 1, 1, 0.08 }, T.radiusControl)
    b.text = W.Text(b, "GameFontHighlightSmall", T.text, "CENTER")
    b.text:SetPoint("CENTER")
    b.text:SetText(opt[2])
    if recommended then
      b.text:ClearAllPoints()
      b.text:SetPoint("CENTER", 0, 6)
      b.badge = W.Text(b, "GameFontHighlightSmall", T.accent, "CENTER")
      local path, _, flags = b.badge:GetFont()
      if path then
        b.badge:SetFont(path, 9, flags or "")
      end
      b.badge:SetPoint("CENTER", 0, -8)
      b.badge:SetText(o.recommendedText or "")
    end
    b:SetScript("OnClick", function()
      if not IsDisabled(o) then
        o.set(opt[1])
      end
    end)
    buttons[i] = b
  end

  local descTop = 20 + bh + 6
  local descFs = W.Text(f, "GameFontHighlightSmall", T.textDim)
  descFs:SetWidth(width)
  descFs:SetPoint("TOPLEFT", 0, -descTop)
  -- Reserve two lines so the layout does not jump between options.
  f:SetHeight(descTop + 30)

  function f.Refresh()
    local current = o.get()
    for i, opt in ipairs(o.options) do
      local b = buttons[i]
      local selected = opt[1] == current
      local c = selected and T.accent or T.trackOff
      b.bg:SetColorTexture(c[1], c[2], c[3], 1)
      local tc = selected and dark or T.text
      b.text:SetTextColor(tc[1], tc[2], tc[3])
      if b.badge then
        local bc = selected and dark or T.accent
        b.badge:SetTextColor(bc[1], bc[2], bc[3])
      end
    end
    descFs:SetText(o.descFor and o.descFor(current) or "")
    local disabled = IsDisabled(o)
    f:SetAlpha(disabled and T.disabledAlpha or 1)
    for _, b in ipairs(buttons) do
      b.hover:SetShown(not disabled)
    end
  end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Button: primary (gold) or secondary; optional tooltip.
---------------------------------------------------------------------------------------
function W.Button(parent, o, width)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, o.height or 28)
  -- o.color: a custom fill with white text (e.g. Discord's blurple).
  local c = o.color or (o.primary and { T.accent[1], T.accent[2], T.accent[3], 0.9 }) or T.trackOff
  b.bg = W.Rounded(b, "BACKGROUND", c, T.radiusControl)
  local hover = W.Rounded(b, "HIGHLIGHT", { 1, 1, 1, 0.08 }, T.radiusControl)
  local textColor = o.color and T.white or (o.primary and { 0.08, 0.08, 0.08 }) or T.text
  b.text = W.Text(b, "GameFontNormal", textColor, "CENTER")
  b.text:SetPoint("CENTER")
  -- Long labels (some languages) shrink a little to stay inside the button.
  local fontPath, fontSize, fontFlags = b.text:GetFont()
  local function SetLabel(text)
    b.text:SetText(text or "")
    if not (fontPath and fontSize) then
      return
    end
    local size = fontSize
    b.text:SetFont(fontPath, size, fontFlags or "")
    while size > fontSize - 3 and (b.text:GetStringWidth() or 0) > width - 14 do
      size = size - 1
      b.text:SetFont(fontPath, size, fontFlags or "")
    end
  end
  SetLabel(o.text)
  b:SetScript("OnClick", function()
    local style = o.style and o.style()
    if not IsDisabled(o) and not (style and style.locked) and o.onClick then
      o.onClick()
    end
  end)
  -- o.disabledTooltip (string or function): why the button can't be used right now.
  b:SetScript("OnEnter", function(self)
    local text = o.tooltip
    if IsDisabled(o) and o.disabledTooltip then
      text = type(o.disabledTooltip) == "function" and o.disabledTooltip() or o.disabledTooltip
    end
    if text then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(text, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  function b.Refresh()
    if o.shown then
      b:SetShown(o.shown())
    end
    local disabled = IsDisabled(o)
    local style = o.style and o.style()
    if style then
      local bg, tc = style.bg or c, style.text or textColor
      b.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
      b.text:SetTextColor(tc[1], tc[2], tc[3])
    end
    local locked = style and style.locked
    b:SetAlpha(disabled and T.disabledAlpha or 1)
    hover:SetShown(not disabled and not locked) -- only clickable buttons light up
    if o.textFn then
      SetLabel(o.textFn())
    end
  end
  return Register(b)
end

---------------------------------------------------------------------------------------
-- Paragraph: static or dynamic (textFn) wrapped text.
---------------------------------------------------------------------------------------
function W.Paragraph(parent, o, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(width)
  local fs = W.Text(f, o.font or "GameFontHighlightSmall", o.color or T.textDim)
  fs:SetWidth(width)
  fs:SetPoint("TOPLEFT")
  local function Update()
    if o.shown then
      f:SetShown(o.shown())
    end
    fs:SetText(o.textFn and o.textFn() or o.text or "")
    f:SetHeight(math.max(12, fs:GetStringHeight()))
  end
  Update()
  function f.Refresh()
    Update()
  end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- ScrollBar: a thin track you can click (pages toward the click) with a thumb you can
-- drag. o.get() → value, maxValue, view, total (any unit: rows or pixels);
-- o.set(value) receives a raw value (the owner clamps / rounds and refreshes);
-- o.wheel(delta), optional: the mouse wheel over the bar itself. Call bar.Update()
-- after the owner's content or position changes.
---------------------------------------------------------------------------------------
function W.ScrollBar(parent, o)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(10)
  f:EnableMouse(true)
  local track = W.Rounded(f, "BACKGROUND", T.trackOff, 2, { x = 3 })

  local thumb = CreateFrame("Button", nil, f)
  thumb:SetWidth(10)
  W.Rounded(thumb, "ARTWORK", T.accent, 2, { x = 3 })
  W.Rounded(thumb, "HIGHLIGHT", { 1, 1, 1, 0.35 }, 3, { x = 2 })

  local function Geometry()
    local value, maxValue, view, total = o.get()
    local h = f:GetHeight() or 0
    local thumbH = math.min(h, math.max(18, h * (view or 1) / math.max(total or 1, 1)))
    return value or 0, maxValue or 0, h, thumbH, view or 1
  end

  local function CursorY()
    local _, y = _G.GetCursorPosition()
    return (y or 0) / f:GetEffectiveScale()
  end

  function f.Update()
    local value, maxValue, h, thumbH = Geometry()
    local scrollable = maxValue > 0 and h > 0
    track:SetShown(scrollable)
    thumb:SetShown(scrollable)
    if scrollable then
      thumb:SetHeight(thumbH)
      thumb:ClearAllPoints()
      thumb:SetPoint("TOP", f, "TOP", 0, -(h - thumbH) * math.min(1, value / maxValue))
    end
  end

  -- Drag the thumb: the content follows the cursor until the button is released.
  local function StopDrag()
    thumb:SetScript("OnUpdate", nil)
  end
  thumb:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then
      return
    end
    local value, maxValue, h, thumbH = Geometry()
    local startY, startValue, span = CursorY(), value, h - thumbH
    thumb:SetScript("OnUpdate", function()
      if _G.IsMouseButtonDown and not _G.IsMouseButtonDown("LeftButton") then
        StopDrag() -- the release went elsewhere (e.g. Alt-Tab): don't keep following
        return
      end
      if span > 0 then
        o.set(startValue + (startY - CursorY()) / span * maxValue)
      end
    end)
  end)
  thumb:SetScript("OnMouseUp", StopDrag)
  thumb:SetScript("OnHide", StopDrag)
  f.thumb = thumb
  if o.wheel then
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
      o.wheel(delta)
    end)
  end

  -- Click the track above / below the thumb: one page up / down.
  f:SetScript("OnMouseDown", function(_, button)
    local top = f:GetTop()
    if button ~= "LeftButton" or not top then
      return
    end
    local value, maxValue, h, thumbH, view = Geometry()
    if maxValue <= 0 then
      return
    end
    local y = top - CursorY()
    local thumbTop = (h - thumbH) * math.min(1, value / maxValue)
    if y < thumbTop then
      o.set(value - view)
    elseif y > thumbTop + thumbH then
      o.set(value + view)
    end
  end)
  return f
end

---------------------------------------------------------------------------------------
-- Section: a divider line, then an optional title (+ dim tag) and description, to group
-- controls inside a card. o.title, o.tag, o.desc (all optional: none = divider only).
---------------------------------------------------------------------------------------
function W.Section(parent, o, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(width)
  local line = Solid(f, "ARTWORK", T.cardBorder)
  line:SetHeight(1)
  line:SetPoint("TOPLEFT")
  line:SetPoint("TOPRIGHT")
  local y = 18 -- below the divider
  if o.title then
    local title = W.Bold(f, "GameFontNormal", T.accent, T.titleBump)
    title:SetPoint("TOPLEFT", 0, -y)
    title:SetText(W.Upper(o.title))
    if o.tag then
      local tag = W.Text(f, "GameFontHighlightSmall", T.textDim)
      tag:SetPoint("LEFT", title, "RIGHT", 8, 0)
      tag:SetText(o.tag)
    end
    y = y + title:GetStringHeight() + T.titleGap
  end
  if o.desc then
    local desc = W.Text(f, "GameFontHighlightSmall", T.textDim)
    desc:SetWidth(width)
    desc:SetPoint("TOPLEFT", 0, -y)
    desc:SetText(o.desc)
    y = y + desc:GetStringHeight() + 4
  end
  f:SetHeight(y)
  function f.Refresh() end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Callout: a highlighted box (tinted, gold bar on the left) with a title, numbered steps
-- in a larger font and an optional dim note. o.title, o.steps = { text, ... }, o.note.
---------------------------------------------------------------------------------------
function W.Callout(parent, o, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(width)
  W.Rounded(f, "BACKGROUND", { T.accent[1], T.accent[2], T.accent[3], 0.08 }, T.radius)
  W.Rounded(f, "BORDER", T.accent, 1.5, { left = 0, right = width - 3, top = 8, bottom = 8 })

  local pad, numW = 20, 22
  local title = W.Bold(f, "GameFontNormal", T.accent, T.titleBump)
  title:SetText(W.Upper(o.title))
  local rows = {}
  for i, text in ipairs(o.steps) do
    local num = W.Text(f, "GameFontNormal", T.accent)
    num:SetText(i .. ".")
    local fs = W.Text(f, "GameFontHighlight", T.white)
    fs:SetWidth(width - pad * 2 - numW)
    fs:SetText(text)
    rows[i] = { num = num, fs = fs }
  end
  -- o.footer: a closing line in the steps' font, without a number ("Done. ...").
  local footer
  if o.footer then
    footer = W.Text(f, "GameFontHighlight", T.accent)
    footer:SetWidth(width - pad * 2)
    footer:SetText(o.footer)
  end
  local note
  if o.note then
    note = W.Text(f, "GameFontHighlightSmall", T.textDim)
    note:SetWidth(width - pad * 2)
    note:SetText(o.note)
  end

  local function Layout()
    local y = 16
    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", pad, -y)
    y = y + title:GetStringHeight() + T.titleGap + 4
    for _, r in ipairs(rows) do
      r.num:ClearAllPoints()
      r.num:SetPoint("TOPLEFT", pad, -y)
      r.fs:ClearAllPoints()
      r.fs:SetPoint("TOPLEFT", pad + numW, -y)
      y = y + r.fs:GetStringHeight() + 10
    end
    if footer then
      footer:ClearAllPoints()
      footer:SetPoint("TOPLEFT", pad, -(y + 2))
      y = y + 2 + footer:GetStringHeight() + 8
    end
    if note then
      note:ClearAllPoints()
      note:SetPoint("TOPLEFT", pad, -(y + 2))
      y = y + 2 + note:GetStringHeight() + 8
    end
    f:SetHeight(y + 4)
  end
  Layout()
  function f.Refresh()
    Layout()
  end
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Preview: a miniature screen with your character where it sits.
--   point() → where the character's head shows, -1..1 from the screen's center to its
--   edges (right / up positive), caption, figure (T.figure on foot by default, T.rider)
---------------------------------------------------------------------------------------
local PREVIEW_W, PREVIEW_H = 150, 84
local PREVIEW_HEAD = 8.9 -- the character's head, in units, whichever figure
function W.Preview(parent, o)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(PREVIEW_W, PREVIEW_H + 20)
  local box = CreateFrame("Frame", nil, f)
  box:SetSize(PREVIEW_W, PREVIEW_H)
  box:SetPoint("TOP")
  W.Box(box, T.previewBg, T.cardBorder, T.radiusControl)
  local h = Solid(box, "ARTWORK", { 1, 1, 1, 0.08 })
  h:SetHeight(1)
  h:SetPoint("LEFT")
  h:SetPoint("RIGHT")
  local v = Solid(box, "ARTWORK", { 1, 1, 1, 0.08 })
  v:SetWidth(1)
  v:SetPoint("TOP")
  v:SetPoint("BOTTOM")
  -- Your character, in gold: its head sits where the character is framed. Every figure is
  -- drawn with the same head size, so the rider is as big as the person on foot.
  local art = o.figure or T.figure
  local s = PREVIEW_HEAD / art.head -- units per texel
  local figure = box:CreateTexture(nil, "OVERLAY")
  figure:SetTexture(art.path)
  figure:SetTexCoord(art.x0 / art.w, art.x1 / art.w, art.y0 / art.h, art.y1 / art.h)
  figure:SetSize((art.x1 - art.x0) * s, (art.y1 - art.y0) * s)
  figure:SetVertexColor(T.accent[1], T.accent[2], T.accent[3], 1)
  local caption = W.Text(f, "GameFontDisableSmall", T.textDim, "CENTER")
  caption:SetPoint("BOTTOM")
  caption:SetText(o.caption or "")

  -- The box is the screen: the head goes where it shows (kept inside the frame), and what
  -- reaches past the frame is cut off, as the screen cuts off your character or mount.
  local inX, inY = PREVIEW_W / 2 - 2, PREVIEW_H / 2 - 2 -- inside the 1-unit border
  local r = PREVIEW_HEAD / 2
  function f.Refresh()
    local x, y = o.point()
    x = math.max(-(inX - r), math.min(inX - r, x * PREVIEW_W / 2))
    y = math.max(-(inY - r), math.min(inY - r, y * PREVIEW_H / 2))
    -- The art's edges, from the box's center, and the texels that fall outside it.
    local left, right = x - (art.headX - art.x0) * s, x + (art.x1 - art.headX) * s
    local top, bottom = y + (art.headY - art.y0) * s, y - (art.y1 - art.headY) * s
    local cutL, cutR = math.max(0, -inX - left) / s, math.max(0, right - inX) / s
    local cutT, cutB = math.max(0, top - inY) / s, math.max(0, -inY - bottom) / s
    local x0, x1, y0, y1 = art.x0 + cutL, art.x1 - cutR, art.y0 + cutT, art.y1 - cutB
    figure:SetTexCoord(x0 / art.w, x1 / art.w, y0 / art.h, y1 / art.h)
    figure:SetSize(math.max(0.01, (x1 - x0) * s), math.max(0.01, (y1 - y0) * s))
    figure:ClearAllPoints()
    figure:SetPoint("TOPLEFT", box, "CENTER", left + cutL * s, top - cutT * s)
    f:SetAlpha(o.disabled and o.disabled() and T.disabledAlpha or 1)
  end
  f.figure = figure
  return Register(f)
end

---------------------------------------------------------------------------------------
-- Card: titled panel that stacks controls vertically.
---------------------------------------------------------------------------------------
function W.Card(parent, o, width)
  local card = CreateFrame("Frame", nil, parent)
  card:SetWidth(width)
  W.Box(card, T.cardBg, T.cardBorder, T.radius)

  local pad = T.pad
  card.inner = width - pad * 2
  local y = pad
  if o.title then
    local title = W.Bold(card, "GameFontNormal", T.accent, T.titleBump)
    title:SetPoint("TOPLEFT", pad, -y)
    title:SetText((o.number and (o.number .. "  ·  ") or "") .. W.Upper(o.title))
    if o.tag then
      -- e.g. "(Optional)": dim, right after the title
      local tag = W.Text(card, "GameFontHighlightSmall", T.textDim)
      tag:SetPoint("LEFT", title, "RIGHT", 8, 0)
      tag:SetText(o.tag)
    end
    y = y + title:GetStringHeight() + T.titleGap
  end
  if o.desc then
    local desc = W.Text(card, "GameFontHighlightSmall", T.textDim)
    desc:SetWidth(card.inner)
    desc:SetPoint("TOPLEFT", pad, -y)
    desc:SetText(o.desc)
    y = y + desc:GetStringHeight() + T.gap
  end
  card.headerHeight = y
  card.rows = {}

  --- Stack a control (or a { frames } row laid out side by side).
  function card.Add(ctrl, gap)
    card.rows[#card.rows + 1] = { ctrl = ctrl, gap = gap or T.gap }
    return ctrl
  end

  function card.Layout()
    local cy, lastGap = card.headerHeight, 0
    for _, row in ipairs(card.rows) do
      local ctrl = row.ctrl
      if ctrl:IsShown() then
        ctrl:ClearAllPoints()
        ctrl:SetPoint("TOPLEFT", card, "TOPLEFT", pad + (ctrl.indent or 0), -cy)
        cy = cy + ctrl:GetHeight() + row.gap
        lastGap = row.gap
      end
    end
    card:SetHeight(cy - lastGap + pad) -- the same padding at the bottom as at the top
  end
  return card
end

--- Horizontal group of fixed-size frames (e.g. two previews) as one stackable row.
function W.Row(parent, frames, spacing)
  local f = CreateFrame("Frame", nil, parent)
  local x, h = 0, 0
  for _, child in ipairs(frames) do
    child:SetParent(f)
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", x, 0)
    x = x + child:GetWidth() + (spacing or 12)
    h = math.max(h, child:GetHeight())
  end
  f:SetSize(x, h)
  return f
end
