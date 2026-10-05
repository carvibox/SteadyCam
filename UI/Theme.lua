---------------------------------------------------------------------------------------
--  UI/Theme.lua — the carvibox style: colors, sizes, radii (dark slate + gold accent)
--  Shared by every carvibox addon (see DESIGN.md); per addon, only the Media paths and the
--  identity block (`icon`, `wordmark`, `wordmarkSolo`, `rider` and their boxes) change.
---------------------------------------------------------------------------------------
local _, PC = ...

PC.Theme = {
  accent = { 0.941, 0.741, 0.188 }, -- #F0BD30, RGB 240 189 48: warm gold (also Core/Init.lua and the artwork)
  white = { 1, 1, 1 },
  text = { 0.86, 0.86, 0.86 },
  textDim = { 0.58, 0.58, 0.58 },
  warning = { 0.86, 0.38, 0.38 },
  good = { 0.40, 0.78, 0.47 },

  windowBg = { 0.094, 0.106, 0.125, 1 }, -- opaque: a box's border sits under its fill
  windowBorder = { 0.204, 0.204, 0.204, 1 },
  cardBg = { 0.122, 0.133, 0.153, 1 },
  cardBorder = { 0.18, 0.18, 0.19, 1 },
  previewBg = { 0.055, 0.062, 0.078, 1 },
  trackOff = { 0.24, 0.24, 0.25, 1 },
  riding = { 0.22, 0.29, 0.24, 1 }, -- row of the mount you ride now: a quiet grey-green
  selected = { 0.38, 0.33, 0.16, 1 }, -- selected row: accent at 32% over cardBg, but opaque
  toggleOn = { 0.32, 0.62, 0.38, 1 },
  hover = { 1, 1, 1, 0.06 },

  disabledAlpha = 0.45,
  width = 560,
  height = 720,
  margin = 30, -- window edge to its cards (main window)
  pad = 28, -- card edge to its controls
  gap = 16, -- between stacked controls
  titleGap = 10, -- title to its text: more than the space between lines
  lineSpacing = 3, -- extra space between wrapped lines
  fontBump = 1, -- every SteadyCam text one point larger than the game's template
  titleBump = 2, -- section titles: bold and this much larger again

  -- Rounded corners, subtle (UI units).
  radiusWindow = 8,
  radius = 6, -- cards, callouts
  radiusControl = 5, -- buttons, tabs, rows, inputs
  corner = "Interface\\AddOns\\SteadyCam\\Media\\Corner", -- 16x16 quarter disk, white
  arrow = "Interface\\AddOns\\SteadyCam\\Media\\Arrow", -- 32x32 rounded triangle pointing right, white

  -- Identity. Textures made by Tools/make_media.py from the artwork PNGs in Media/; a
  -- wordmark lies on a 512x128 canvas, x0..x1 / y0..y1 is where (as the tool prints it).
  icon = "Interface\\AddOns\\SteadyCam\\Media\\Icon",
  wordmark = { path = "Interface\\AddOns\\SteadyCam\\Media\\Wordmark", w = 512, h = 128, x0 = 2, x1 = 510, y0 = 19, y1 = 108 },
  -- letters: the middle of the letters, as a fraction of the art's height from its top.
  wordmarkSolo = { path = "Interface\\AddOns\\SteadyCam\\Media\\WordmarkSolo", w = 512, h = 128, x0 = 2, x1 = 510, y0 = 2, y1 = 126, letters = 0.43 },
  -- Your character in the framing previews (white, tinted gold), placed by its head: the
  -- little person on foot, and the icon's rider on its horse mounted (Tools/make_media.py).
  -- x0..y1 = the art on the texture, headX/headY = the head's center, head = its width.
  figure = { path = "Interface\\AddOns\\SteadyCam\\Media\\Figure", w = 32, h = 32, x0 = 0, x1 = 32, y0 = 0, y1 = 32, headX = 16, headY = 8.5, head = 13 },
  rider = { path = "Interface\\AddOns\\SteadyCam\\Media\\Rider", w = 128, h = 128, x0 = 2, x1 = 126, y0 = 18, y1 = 110, headX = 41.5, headY = 33.9, head = 30.7 },
  signature = "by carvibox",
}
