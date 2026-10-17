--[[
	HELHEIM — event-based player ESP

	  • Small round button: tap = ESP ON / OFF, drag = move it
	  • Badge at the top-right (≡): opens the config menu
	      - Lock button position
	      - Highlight / Names / Health / Distance / Team color switches
	      - TH / EN language
	  • Second round button "Depressed" (red diamond): "MAKE A DEAL WITH FENRIR" pact box
	      (it drags on its own, and its position can be locked in the menu)
	      - NO  = close the box
	      - YES (ESP off) = the demon takes your body, the features chosen in the menu turn on at once
	      - YES (ESP on)  = the pact is broken: ESP turns off at once
	  • ESP starts OFF. While OFF everything is removed, so it costs nothing.
	  • Re-running the script replaces the old copy; Helheim.Unload() removes everything.

	Run with:  loadstring(game:HttpGet("YOUR_RAW_URL"))()
]]

local CONFIG = {
	Enabled = false, -- ESP starts OFF; use the pact badge (or the round button) to start it
	ShowHighlight = true,
	ShowNames = true,
	ShowHealth = true,
	ShowDistance = true,
	UseTeamColor = true, -- true: team colors. false: friend / enemy colors below
	FriendColor = Color3.fromRGB(0, 120, 255),
	EnemyColor = Color3.fromRGB(255, 60, 60),
	FillTransparency = 0.6,
	OutlineTransparency = 0,
	DistanceRefresh = 0.25, -- seconds between distance updates

	LockButton = false, -- true: the round button cannot be dragged
	Language = "TH", -- "TH" or "EN" (menu language)
	LockDepressed = false, -- true: the Depressed button cannot be dragged
	ButtonStart = Vector2.new(24, 140),
	DepressedStart = Vector2.new(78, 140),

	SoundVolume = 1,
	Sounds = {
		Options = "9072301639", -- plays when the YES / NO choices appear (fades out when you pick one)
		Accept = "5665746430", -- plays when you press YES to turn ESP on
		Revoke = "5993515228", -- plays when you press YES to turn ESP off
	},
}

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local env = (getgenv and getgenv()) or _G
if env.Helheim then
	pcall(env.Helheim.Unload)
end

local function pickParent()
	if gethui then
		local ok, ui = pcall(gethui)
		if ok and ui then
			return ui
		end
	end
	local ok = pcall(function()
		local probe = Instance.new("Folder")
		probe.Parent = CoreGui
		probe:Destroy()
	end)
	if ok then
		return CoreGui
	end
	return playerGui
end

local holder = Instance.new("Folder")
holder.Name = "Helheim"
holder.Parent = pickParent()

local running = true
local globalConns = {}
local playerConns = {} -- [player] = { connections that live as long as the player }
local entries = {} -- [player] = { folder, highlight, tag, label, humanoid, root, conns }

----------------------------------------------------------------------
-- ESP core
----------------------------------------------------------------------
local updateButtonVisual -- defined in the UI section

local function colorFor(player)
	if CONFIG.UseTeamColor then
		return player.TeamColor.Color
	end
	local sameTeam = player.Team ~= nil and player.Team == localPlayer.Team
	return sameTeam and CONFIG.FriendColor or CONFIG.EnemyColor
end

local function buildText(entry, player)
	local lines = {}
	if CONFIG.ShowNames then
		lines[#lines + 1] = player.DisplayName
	end

	local info = {}
	if CONFIG.ShowHealth and entry.humanoid then
		info[#info + 1] = string.format("%d HP", math.floor(entry.humanoid.Health + 0.5))
	end
	if CONFIG.ShowDistance and entry.root then
		local myChar = localPlayer.Character
		local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
		if myRoot then
			info[#info + 1] = string.format("%dm", math.floor((entry.root.Position - myRoot.Position).Magnitude + 0.5))
		end
	end
	if #info > 0 then
		lines[#lines + 1] = table.concat(info, " • ")
	end
	return table.concat(lines, "\n")
end

local function refreshText(player)
	local entry = entries[player]
	if entry and entry.label then
		local text = buildText(entry, player)
		if entry.label.Text ~= text then
			entry.label.Text = text
		end
		entry.tag.Enabled = text ~= ""
	end
end

local function recolor(player)
	local entry = entries[player]
	if not entry then
		return
	end
	local color = colorFor(player)
	entry.highlight.FillColor = color
	entry.highlight.OutlineColor = color
	if entry.label then
		entry.label.TextColor3 = color
	end
end

local function clearCharacter(player)
	local entry = entries[player]
	if not entry then
		return
	end
	entries[player] = nil
	for _, conn in ipairs(entry.conns) do
		conn:Disconnect()
	end
	entry.folder:Destroy()
end

local function buildCharacter(player, char)
	clearCharacter(player)
	if not running or not CONFIG.Enabled then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = player.Name
	folder.Parent = holder

	local highlight = Instance.new("Highlight")
	highlight.Name = "Highlight"
	highlight.Adornee = char
	highlight.Enabled = CONFIG.ShowHighlight
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = CONFIG.FillTransparency
	highlight.OutlineTransparency = CONFIG.OutlineTransparency
	highlight.Parent = folder

	local entry = { folder = folder, highlight = highlight, conns = {} }
	entries[player] = entry

	-- These can take a moment to load in (this runs in its own thread)
	local humanoid = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	local head = char:FindFirstChild("Head") or char:WaitForChild("Head", 5)
	local root = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 5)

	-- The character may have been removed, replaced or ESP switched off while we waited
	if entries[player] ~= entry or not running then
		return
	end

	entry.humanoid = humanoid
	entry.root = root

	if head then
		local tag = Instance.new("BillboardGui")
		tag.Name = "Tag"
		tag.Adornee = head
		tag.AlwaysOnTop = true
		tag.Enabled = false
		tag.Size = UDim2.fromOffset(160, 40)
		tag.StudsOffset = Vector3.new(0, 2.6, 0)
		tag.Parent = folder

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextStrokeTransparency = 0.4
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Parent = tag
		entry.tag = tag
		entry.label = label
	end

	if humanoid then
		-- Hide the default overhead name so it doesn't overlap ours
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		entry.conns[#entry.conns + 1] = humanoid.HealthChanged:Connect(function()
			refreshText(player)
		end)
	end

	recolor(player)
	refreshText(player)
end

-- Re-apply every setting to everyone already on screen
local function applyFeatures()
	for player, entry in pairs(entries) do
		entry.highlight.Enabled = CONFIG.ShowHighlight
		recolor(player)
		refreshText(player)
	end
end

-- Master ON / OFF. OFF removes every ESP object, so it costs nothing.
local function setEnabled(state)
	CONFIG.Enabled = state
	if state then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= localPlayer and player.Character then
				task.spawn(buildCharacter, player, player.Character)
			end
		end
	else
		for player in pairs(entries) do
			clearCharacter(player)
		end
	end
	if updateButtonVisual then
		updateButtonVisual()
	end
end

-- Player lifecycle
local function addPlayer(player)
	if player == localPlayer or playerConns[player] then
		return
	end

	local conns = {}
	playerConns[player] = conns

	conns[#conns + 1] = player.CharacterAdded:Connect(function(char)
		task.spawn(buildCharacter, player, char)
	end)
	conns[#conns + 1] = player.CharacterRemoving:Connect(function()
		clearCharacter(player)
	end)
	conns[#conns + 1] = player:GetPropertyChangedSignal("Team"):Connect(function()
		recolor(player)
	end)

	if player.Character then
		task.spawn(buildCharacter, player, player.Character)
	end
end

local function removePlayer(player)
	clearCharacter(player)
	local conns = playerConns[player]
	if conns then
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		playerConns[player] = nil
	end
end

globalConns[#globalConns + 1] = Players.PlayerAdded:Connect(addPlayer)
globalConns[#globalConns + 1] = Players.PlayerRemoving:Connect(removePlayer)
-- If YOUR team changes, friend / enemy colors need to be recalculated
globalConns[#globalConns + 1] = localPlayer:GetPropertyChangedSignal("Team"):Connect(function()
	for player in pairs(entries) do
		recolor(player)
	end
end)

for _, player in ipairs(Players:GetPlayers()) do
	addPlayer(player)
end

-- ONE light timer: only refreshes distance text, and only while ESP is on
task.spawn(function()
	while running do
		task.wait(CONFIG.DistanceRefresh)
		if CONFIG.Enabled and CONFIG.ShowDistance then
			for player in pairs(entries) do
				refreshText(player)
			end
		end
	end
end)

----------------------------------------------------------------------
-- UI: theme, helpers, text
----------------------------------------------------------------------
local THEME = { -- black & white
	Black = Color3.fromRGB(8, 8, 10),
	Panel = Color3.fromRGB(22, 22, 26),
	PanelOn = Color3.fromRGB(18, 18, 22),
	White = Color3.fromRGB(240, 240, 242),
	Gray = Color3.fromRGB(150, 150, 158),
	Dim = Color3.fromRGB(80, 80, 88),
	SwitchOff = Color3.fromRGB(48, 48, 54),
}

local BLOOD = { -- only used by the pact box
	Dark = Color3.fromRGB(12, 1, 2),
	Deep = Color3.fromRGB(42, 3, 6),
	Crimson = Color3.fromRGB(110, 4, 10),
	Red = Color3.fromRGB(190, 14, 26),
	Bright = Color3.fromRGB(235, 28, 40),
	Bone = Color3.fromRGB(236, 224, 220),
}

local STRINGS = {
	TH = {
		lock = "ล็อกปุ่ม ESP",
		lockDep = "ล็อกปุ่ม Depressed",
		highlight = "ไฮไลต์ผู้เล่น",
		names = "แสดงชื่อ",
		health = "แสดงเลือด",
		distance = "แสดงระยะ",
		team = "ใช้สีทีม",
		lang = "ภาษา",
	},
	EN = {
		lock = "Lock ESP button",
		lockDep = "Lock Depressed button",
		highlight = "Highlight players",
		names = "Show names",
		health = "Show health",
		distance = "Show distance",
		team = "Use team color",
		lang = "Language",
	},
}

local TI_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_MED = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TI_POP = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local currentLang = CONFIG.Language == "EN" and "EN" or "TH"
local localized = {} -- { {inst, key} }

local function tween(inst, info, props)
	local tw = TweenService:Create(inst, info, props)
	tw:Play()
	return tw
end

-- Tiny instance factory (Parent is assigned last for performance)
local function new(className, props, children)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function round()
	return new("UICorner", { CornerRadius = UDim.new(1, 0) })
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function colorSeq(...)
	local colors = { ... }
	local points = {}
	for i, c in ipairs(colors) do
		points[i] = ColorSequenceKeypoint.new((i - 1) / (#colors - 1), c)
	end
	return ColorSequence.new(points)
end

local function bindText(inst, key)
	table.insert(localized, { inst = inst, key = key })
	inst.Text = STRINGS[currentLang][key]
end

----------------------------------------------------------------------
-- UI: round button, badges, config menu
----------------------------------------------------------------------
local BUTTON = 44
local MENU_W, MENU_H = 200, 298

local gui = new("ScreenGui", {
	Name = "HelheimGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

-- Zero-size anchor: dragging moves this, and the button, badges and menu follow
local anchor = new("Frame", {
	Name = "Anchor",
	Size = UDim2.fromOffset(0, 0),
	Position = UDim2.fromOffset(CONFIG.ButtonStart.X, CONFIG.ButtonStart.Y),
	BackgroundTransparency = 1,
	Parent = gui,
})

local btnScale = new("UIScale", { Scale = 0.6 }) -- pops in on start
local buttonStroke = stroke(THEME.White, 1.5, 0.1)

local nameLabel = new("TextLabel", {
	Position = UDim2.fromOffset(0, 8),
	Size = UDim2.new(1, 0, 0, 12),
	BackgroundTransparency = 1,
	Text = "ESP",
	Font = Enum.Font.GothamBold,
	TextSize = 9,
	TextColor3 = THEME.Gray,
})

local stateLabel = new("TextLabel", {
	Position = UDim2.fromOffset(0, 20),
	Size = UDim2.new(1, 0, 0, 16),
	BackgroundTransparency = 1,
	Text = "OFF",
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextColor3 = THEME.Gray,
})

local button = new("TextButton", {
	Name = "Toggle",
	Size = UDim2.fromOffset(BUTTON, BUTTON),
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = THEME.Black,
	BorderSizePixel = 0,
	Parent = anchor,
}, { round(), buttonStroke, btnScale, nameLabel, stateLabel })

-- Config badge (three lines), top-right of the button
local function badgeLine(y)
	return new("Frame", {
		Position = UDim2.fromOffset(5, y),
		Size = UDim2.fromOffset(8, 2),
		BackgroundColor3 = THEME.White,
		BorderSizePixel = 0,
	}, { round() })
end

local gear = new("TextButton", {
	Name = "ConfigBadge",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(37, 7),
	Size = UDim2.fromOffset(18, 18),
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
	Parent = anchor,
}, { round(), stroke(THEME.White, 1, 0.45), badgeLine(4), badgeLine(8), badgeLine(12) })

-- "Depressed" button: its own round button (drag + lock), opens the pact box
local depAnchor = new("Frame", {
	Name = "DepressedAnchor",
	Size = UDim2.fromOffset(0, 0),
	Position = UDim2.fromOffset(CONFIG.DepressedStart.X, CONFIG.DepressedStart.Y),
	BackgroundTransparency = 1,
	Parent = gui,
})

local depScale = new("UIScale", { Scale = 0.6 }) -- pops in on start
local depStroke = stroke(BLOOD.Crimson, 1.5, 0.2)

local depButton = new("TextButton", {
	Name = "Depressed",
	Size = UDim2.fromOffset(BUTTON, BUTTON),
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = THEME.Black,
	BorderSizePixel = 0,
	Parent = depAnchor,
}, {
	round(),
	depStroke,
	depScale,
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 13),
		Size = UDim2.fromOffset(8, 8),
		Rotation = 45,
		BackgroundColor3 = BLOOD.Bright,
		BorderSizePixel = 0,
	}),
	new("TextLabel", {
		Position = UDim2.fromOffset(3, 23),
		Size = UDim2.new(1, -6, 0, 14),
		BackgroundTransparency = 1,
		Text = "Depressed",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = BLOOD.Bone,
	}, { new("UITextSizeConstraint", { MaxTextSize = 9, MinTextSize = 5 }) }),
})

-- Config menu panel
local menuScale = new("UIScale", { Scale = 1 })
local menu = new("Frame", {
	Name = "Menu",
	Size = UDim2.fromOffset(MENU_W, MENU_H),
	Position = UDim2.fromOffset(0, BUTTON + 8),
	BackgroundColor3 = THEME.White, -- tinted by the gradient below
	BackgroundTransparency = 0.04,
	BorderSizePixel = 0,
	Visible = false,
	Active = true,
	Parent = anchor,
}, {
	corner(12),
	menuScale,
	new("UIGradient", {
		Color = colorSeq(Color3.fromRGB(28, 28, 32), THEME.Black),
		Rotation = 110,
	}),
	new("UIStroke", {
		Color = THEME.White,
		Thickness = 1.2,
		Transparency = 0.15,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, {
		new("UIGradient", { Color = colorSeq(THEME.White, Color3.fromRGB(90, 90, 98), THEME.White), Rotation = 45 }),
	}),
	new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}),
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

new("TextLabel", {
	LayoutOrder = 0,
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Text = "HELHEIM",
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = THEME.White,
	Parent = menu,
})

local function makeRow(order)
	return new("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 28),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = THEME.Panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Parent = menu,
	}, { corner(8), stroke(THEME.White, 1, 0.82) })
end

local function rowLabel(row, key)
	local label = new("TextLabel", {
		Position = UDim2.fromOffset(9, 0),
		Size = UDim2.new(1, -56, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
		TextColor3 = THEME.White,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	bindText(label, key)
end

-- Little on / off switch; returns a function that updates its look
local function addSwitch(row, initial)
	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(34, 17),
		BackgroundColor3 = initial and THEME.White or THEME.SwitchOff,
		BorderSizePixel = 0,
		Parent = row,
	}, { round() })

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, initial and 19 or 2, 0.5, 0),
		Size = UDim2.fromOffset(13, 13),
		BackgroundColor3 = initial and THEME.Black or THEME.Gray,
		BorderSizePixel = 0,
		Parent = track,
	}, { round() })

	return function(state)
		tween(track, TI_FAST, { BackgroundColor3 = state and THEME.White or THEME.SwitchOff })
		tween(knob, TI_FAST, {
			Position = UDim2.new(0, state and 19 or 2, 0.5, 0),
			BackgroundColor3 = state and THEME.Black or THEME.Gray,
		})
	end
end

local function addToggleRow(order, key, get, set)
	local row = makeRow(order)
	rowLabel(row, key)
	local setVisual = addSwitch(row, get())
	row.Activated:Connect(function()
		local value = not get()
		set(value)
		setVisual(value)
	end)
end

addToggleRow(1, "lock", function()
	return CONFIG.LockButton
end, function(v)
	CONFIG.LockButton = v
end)

addToggleRow(2, "lockDep", function()
	return CONFIG.LockDepressed
end, function(v)
	CONFIG.LockDepressed = v
end)

addToggleRow(3, "highlight", function()
	return CONFIG.ShowHighlight
end, function(v)
	CONFIG.ShowHighlight = v
	applyFeatures()
end)

addToggleRow(4, "names", function()
	return CONFIG.ShowNames
end, function(v)
	CONFIG.ShowNames = v
	applyFeatures()
end)

addToggleRow(5, "health", function()
	return CONFIG.ShowHealth
end, function(v)
	CONFIG.ShowHealth = v
	applyFeatures()
end)

addToggleRow(6, "distance", function()
	return CONFIG.ShowDistance
end, function(v)
	CONFIG.ShowDistance = v
	applyFeatures()
end)

addToggleRow(7, "team", function()
	return CONFIG.UseTeamColor
end, function(v)
	CONFIG.UseTeamColor = v
	applyFeatures()
end)

-- Language row (TH / EN pill)
local langRow = makeRow(8)
rowLabel(langRow, "lang")
local langPill = new("TextLabel", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -8, 0.5, 0),
	Size = UDim2.fromOffset(34, 17),
	BackgroundColor3 = THEME.White,
	BorderSizePixel = 0,
	Text = currentLang,
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextColor3 = THEME.Black,
	Parent = langRow,
}, { round() })

langRow.Activated:Connect(function()
	currentLang = currentLang == "EN" and "TH" or "EN"
	for _, entry in ipairs(localized) do
		entry.inst.Text = STRINGS[currentLang][entry.key]
	end
	langPill.Text = currentLang
end)

----------------------------------------------------------------------
-- UI: pact box ("MAKE A DEAL WITH FENRIR") — blood theme, glitch text
----------------------------------------------------------------------
local GLYPHS = { "#", "%", "&", "@", "$", "?", "!", "/", "\\", "|", "X", "0", "*", "+", "=" }

local function randomGlyph()
	return GLYPHS[math.random(#GLYPHS)]
end

-- Sounds
local optionsSound = nil

local function playSound(id)
	if not id or id == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. id
	sound.Volume = CONFIG.SoundVolume
	sound.Parent = gui
	Debris:AddItem(sound, 120) -- safety net so a sound can never stay behind
	local ok = pcall(function()
		sound:Play()
	end)
	if not ok then
		sound:Destroy()
		return nil
	end
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	return sound
end

-- The "options" sound fades away slowly instead of cutting off
local function fadeOutOptionsSound(seconds)
	local sound = optionsSound
	optionsSound = nil
	if not sound or not sound.Parent then
		return
	end
	local fade = tween(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { Volume = 0 })
	fade.Completed:Once(function()
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end)
end

local function playOptionsSound()
	fadeOutOptionsSound(0.1)
	optionsSound = playSound(CONFIG.Sounds.Options)
end

-- Dark overlay that also blocks taps behind the box
local overlay = new("Frame", {
	Name = "PactOverlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
	Active = true,
	Parent = gui,
})

-- Red flash used when the pact is accepted
local redFlash = new("Frame", {
	Name = "PactFlash",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BLOOD.Red,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
	Parent = gui,
})

-- CanvasGroup lets the whole box fade in and out as one piece
local boxScale = new("UIScale", { Scale = 0.85 })
local box = new("CanvasGroup", {
	Name = "PactBox",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(328, 168),
	BackgroundTransparency = 1,
	GroupTransparency = 1,
	BorderSizePixel = 0,
	Active = true,
	Parent = overlay,
}, { boxScale })

local boxStroke = stroke(BLOOD.Red, 2, 0)
local card = new("Frame", {
	Name = "Card",
	Position = UDim2.fromOffset(4, 4),
	Size = UDim2.new(1, -8, 1, -8),
	BackgroundColor3 = THEME.White, -- tinted by the gradient below
	BorderSizePixel = 0,
	Parent = box,
}, {
	corner(4),
	boxStroke,
	new("UIGradient", { Color = colorSeq(BLOOD.Deep, BLOOD.Dark, Color3.fromRGB(22, 0, 2)), Rotation = 90 }),
})

new("Frame", {
	Name = "InnerBorder",
	Position = UDim2.fromOffset(6, 6),
	Size = UDim2.new(1, -12, 1, -12),
	BackgroundTransparency = 1,
	Parent = card,
}, { corner(2), stroke(BLOOD.Crimson, 1, 0.25) })

-- Title: two ghost layers + main layer give the glitch (chromatic split) look
local titleHolder = new("Frame", {
	Name = "TitleHolder",
	Position = UDim2.fromOffset(0, 28),
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundTransparency = 1,
	Parent = card,
})

local function titleLayer(color, transparency)
	return new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.Creepster,
		TextScaled = true, -- long lines shrink to fit the box
		TextColor3 = color,
		TextTransparency = transparency,
		Text = "",
		Parent = titleHolder,
	}, { new("UITextSizeConstraint", { MaxTextSize = 38, MinTextSize = 16 }) })
end
local ghostB = titleLayer(BLOOD.Crimson, 0.2)
local ghostA = titleLayer(BLOOD.Bone, 0.55)
local titleMain = titleLayer(Color3.fromRGB(225, 22, 34), 1)

local function setTitle(text)
	titleMain.Text = text
	ghostA.Text = text
	ghostB.Text = text
end

-- The demon's cage: chains, claw marks, glowing eyes and a whispered subtitle
local CARD_W = 320
local STEEL = Color3.fromRGB(128, 126, 132)
local RUST = Color3.fromRGB(122, 52, 40)

local buttonsShown = false
local rage = 0 -- while > 0 the demon thrashes violently
local subText = ""

local chainLinks = {}
for side = 1, 2 do
	local x = side == 1 and 14 or CARD_W - 14
	for i = 0, 8 do
		local y = 14 + i * 16
		local color = (math.random() < 0.3) and RUST or STEEL
		if i % 2 == 0 then
			-- face-on link: hollow oval
			local linkStroke = stroke(color, 2, 0)
			local link = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(9, 15),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Parent = card,
			}, { round(), linkStroke })
			chainLinks[#chainLinks + 1] = { frame = link, stroke = linkStroke, x = x, y = y }
		else
			-- edge-on link: thin bar
			local link = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(3, 11),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Parent = card,
			}, { round() })
			chainLinks[#chainLinks + 1] = { frame = link, bar = true, x = x, y = y }
		end
	end
end

local function setChainsVisible(visible)
	for _, l in ipairs(chainLinks) do
		l.frame.Position = UDim2.fromOffset(l.x, l.y)
		l.frame.Rotation = 0
		if l.stroke then
			l.stroke.Transparency = visible and 0 or 1
		end
		if l.bar then
			l.frame.BackgroundTransparency = visible and 0 or 1
		end
	end
end

local function rattleChains(strength)
	for _, l in ipairs(chainLinks) do
		l.frame.Position = UDim2.fromOffset(l.x + math.random(-strength, strength), l.y + math.random(-strength, strength))
	end
end

local function resetChains()
	for _, l in ipairs(chainLinks) do
		l.frame.Position = UDim2.fromOffset(l.x, l.y)
	end
end

-- The chains shatter and fall away
local function breakChains()
	for _, l in ipairs(chainLinks) do
		local dir = l.x < CARD_W / 2 and -1 or 1
		local info = TweenInfo.new(0.5 + math.random() * 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local props = {
			Position = UDim2.fromOffset(l.x + dir * math.random(10, 40), l.y + math.random(30, 90)),
			Rotation = math.random(-160, 160),
		}
		if l.bar then
			props.BackgroundTransparency = 1
		end
		tween(l.frame, info, props)
		if l.stroke then
			tween(l.stroke, info, { Transparency = 1 })
		end
	end
end

-- The chains slam back down
local function restoreChains()
	for i, l in ipairs(chainLinks) do
		l.frame.Position = UDim2.fromOffset(l.x, l.y - 70)
		l.frame.Rotation = math.random(-40, 40)
		task.delay((i % 9) * 0.03, function()
			if not l.frame.Parent then
				return
			end
			local info = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local props = { Position = UDim2.fromOffset(l.x, l.y), Rotation = 0 }
			if l.bar then
				props.BackgroundTransparency = 0
			end
			tween(l.frame, info, props)
			if l.stroke then
				tween(l.stroke, info, { Transparency = 0 })
			end
		end)
	end
end

-- Claw marks that slash across the corner
local slashFrames = {}
for i = 1, 3 do
	slashFrames[i] = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(214 + i * 16, 10),
		Size = UDim2.fromOffset(0, 2),
		Rotation = 58,
		BackgroundColor3 = BLOOD.Bright,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = card,
	})
end

local function slash()
	for i, f in ipairs(slashFrames) do
		task.delay(i * 0.05, function()
			if not f.Parent then
				return
			end
			f.BackgroundTransparency = 0.15
			f.Size = UDim2.fromOffset(0, 2)
			tween(f, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(54, 2) })
			task.delay(0.45, function()
				if f.Parent then
					tween(f, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
				end
			end)
		end)
	end
end

-- A pair of glowing eyes opens in the dark, watches, blinks and vanishes
local eyesBusy = false
local EYE_SPOTS = { Vector2.new(46, 14), Vector2.new(268, 14), Vector2.new(46, 152), Vector2.new(268, 152) }

local function eyes()
	if eyesBusy then
		return
	end
	eyesBusy = true
	local spot = EYE_SPOTS[math.random(#EYE_SPOTS)]
	local pair = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(spot.X, spot.Y),
		Size = UDim2.fromOffset(34, 8),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local function eye(x, tilt)
		return new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Size = UDim2.fromOffset(12, 5),
			Rotation = tilt,
			BackgroundColor3 = BLOOD.Bright,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = pair,
		}, { round() })
	end
	local pairOfEyes = { eye(5, 16), eye(29, -16) }

	task.spawn(function()
		for _, e in ipairs(pairOfEyes) do
			tween(e, TweenInfo.new(0.15), { BackgroundTransparency = 0 })
		end
		task.wait(0.5 + math.random() * 0.5)
		for _, e in ipairs(pairOfEyes) do
			tween(e, TweenInfo.new(0.07), { Size = UDim2.fromOffset(12, 0) })
		end
		task.wait(0.12)
		for _, e in ipairs(pairOfEyes) do
			tween(e, TweenInfo.new(0.07), { Size = UDim2.fromOffset(12, 5) })
		end
		task.wait(0.35)
		for _, e in ipairs(pairOfEyes) do
			tween(e, TweenInfo.new(0.2), { BackgroundTransparency = 1 })
		end
		task.wait(0.3)
		pair:Destroy()
		eyesBusy = false
	end)
end

-- Whispered line under the title
local subLabel = new("TextLabel", {
	Position = UDim2.fromOffset(0, 80),
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.Creepster,
	TextSize = 17,
	TextColor3 = Color3.fromRGB(150, 24, 32),
	TextTransparency = 1,
	Text = "",
	Parent = card,
})

local function setSub(text)
	subText = text
	subLabel.Text = text
	subLabel.TextTransparency = 1
	if text ~= "" then
		tween(subLabel, TweenInfo.new(0.7, Enum.EasingStyle.Sine), { TextTransparency = 0.15 })
	end
end

-- NO / YES buttons
local pactButtons = {}
local function makePactButton(text, xScale, fill, hoverFill, strokeColor, textColor)
	local btnStroke = stroke(strokeColor, 1.5, 1)
	local pressScale = new("UIScale", { Scale = 1 })
	local btn = new("TextButton", {
		Name = text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(xScale, 0, 0, 106),
		Size = UDim2.fromOffset(112, 40),
		AutoButtonColor = false,
		Text = text,
		Font = Enum.Font.Creepster,
		TextSize = 26,
		TextColor3 = textColor,
		TextTransparency = 1,
		BackgroundColor3 = fill,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		Parent = card,
	}, { corner(3), btnStroke, pressScale })

	btn.MouseEnter:Connect(function()
		tween(btn, TI_FAST, { BackgroundColor3 = hoverFill })
	end)
	btn.MouseLeave:Connect(function()
		tween(btn, TI_FAST, { BackgroundColor3 = fill })
	end)
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			tween(pressScale, TI_FAST, { Scale = 0.94 })
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			tween(pressScale, TI_FAST, { Scale = 1 })
		end
	end)

	pactButtons[#pactButtons + 1] = { button = btn, stroke = btnStroke, x = xScale }
	return btn
end

local noBtn = makePactButton("NO", 0.3, Color3.fromRGB(22, 22, 24), Color3.fromRGB(46, 46, 50), Color3.fromRGB(130, 130, 136), BLOOD.Bone)
local yesBtn = makePactButton("YES", 0.7, Color3.fromRGB(118, 6, 12), Color3.fromRGB(160, 10, 18), BLOOD.Bright, THEME.White)

local function showButtons()
	playOptionsSound()
	buttonsShown = true
	for _, item in ipairs(pactButtons) do
		item.button.Visible = true
		item.button.BackgroundTransparency = 1
		item.button.TextTransparency = 1
		item.stroke.Transparency = 1
		local info = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
		tween(item.button, info, { BackgroundTransparency = 0, TextTransparency = 0 })
		tween(item.stroke, info, { Transparency = 0.1 })
	end
end

local function hideButtons()
	buttonsShown = false
	for _, item in ipairs(pactButtons) do
		local info = TweenInfo.new(0.25, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
		local tw = tween(item.button, info, { BackgroundTransparency = 1, TextTransparency = 1 })
		tween(item.stroke, info, { Transparency = 1 })
		tw.Completed:Once(function()
			item.button.Visible = false
		end)
	end
end

-- Blood drips hanging from the top edge
local drips = {}
local function buildDrips(extra)
	for _, d in ipairs(drips) do
		d:Destroy()
	end
	drips = {}
	for i = 1, 7 do
		local w = math.random(3, 6)
		local drip = new("Frame", {
			Position = UDim2.new(math.random(6, 94) / 100, 0, 0, 0),
			Size = UDim2.fromOffset(w, 0),
			BackgroundColor3 = BLOOD.Red,
			BorderSizePixel = 0,
			Parent = card,
		}, { round() })
		drips[i] = drip
		task.delay(math.random() * 0.9, function()
			if drip.Parent then
				tween(drip, TweenInfo.new(1 + math.random() * 1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(w, math.random(14, 40) + (extra or 0)),
				})
			end
		end)
	end
end

-- Pact state
local pactOpen = false
local pactToken = 0 -- bumping this stops every running pact animation
local accepted = false
local pactDisabling = false
local decoding = false
local currentTitle = ""
local glitchIntensity = 1
local pulseTween = nil

local function corrupt(text, count)
	local chars = {}
	for i = 1, #text do
		chars[i] = text:sub(i, i)
	end
	for _ = 1, count do
		local i = math.random(#chars)
		if chars[i] ~= " " then
			chars[i] = randomGlyph()
		end
	end
	return table.concat(chars)
end

-- Letters start as noise and lock into the real text one by one
local function decodeTitle(text, token, perLetter)
	decoding = true
	currentTitle = text
	titleMain.TextTransparency = 0.7
	tween(titleMain, TweenInfo.new(0.5, Enum.EasingStyle.Sine), { TextTransparency = 0 })

	local n = #text
	local startTime = os.clock()
	local locked = 0
	while locked < n do
		if token ~= pactToken then
			decoding = false
			return false
		end
		locked = math.min(n, math.floor((os.clock() - startTime) / perLetter))
		local chars = {}
		for i = 1, n do
			local c = text:sub(i, i)
			chars[i] = (i <= locked or c == " ") and c or randomGlyph()
		end
		setTitle(table.concat(chars))
		task.wait(0.04)
	end
	setTitle(text)
	decoding = false
	return true
end

local WHISPERS = { "LET ME OUT", "MINE", "SUFFER", "BURN", "RUN", "FREE" }

local function calmGlitch()
	ghostA.Position = UDim2.fromOffset(0, 0)
	ghostB.Position = UDim2.fromOffset(0, 0)
	titleHolder.Position = UDim2.fromOffset(0, 28)
	titleMain.Rotation = 0
	box.Position = UDim2.fromScale(0.5, 0.5)
	resetChains()
	if subText ~= "" then
		subLabel.Text = subText
	end
	local yes = pactButtons[2]
	if yes then
		yes.button.Position = UDim2.new(yes.x, 0, 0, 106)
	end
end

-- Runs only while the box is open. Nothing is on a fixed rhythm: it trembles, then
-- suddenly thrashes, flashes whispers, opens its eyes, and plays tricks on the buttons.
local function startGlitchLoop(token)
	task.spawn(function()
		local burst = 0
		while pactOpen and token == pactToken do
			task.wait(0.04 + math.random() * 0.03)

			-- random fits of rage
			if rage == 0 and math.random() < 0.012 * glitchIntensity then
				rage = math.random(10, 22)
				slash()
			end
			local raging = rage > 0
			if raging then
				rage -= 1
				burst = math.max(burst, 2)
			end

			if burst > 0 then
				burst -= 1
				local power = glitchIntensity + (raging and 3 or 0)
				local s = 3 + power * 2
				ghostA.Position = UDim2.fromOffset(math.random(-s, s), math.random(-2, 2))
				ghostB.Position = UDim2.fromOffset(math.random(-s, s), math.random(-2, 2))
				titleMain.Rotation = (math.random() - 0.5) * 2 * power
				box.Position = UDim2.new(0.5, math.random(-power, power) * 2, 0.5, math.random(-power, power))
				rattleChains(math.min(power, 5))
				boxStroke.Transparency = math.random() < 0.4 and 0.7 or 0

				if not decoding and currentTitle ~= "" then
					if math.random() < 0.18 then
						setTitle(WHISPERS[math.random(#WHISPERS)]) -- a word it should not be saying
					else
						setTitle(corrupt(currentTitle, math.random(1, 2 + power)))
					end
				end
				if subText ~= "" then
					subLabel.Text = corrupt(subText, math.random(1, 4))
				end
				if raging and math.random() < 0.25 then
					slash()
				end

				if burst == 0 then
					calmGlitch()
					boxStroke.Transparency = 0
					if not decoding and currentTitle ~= "" then
						setTitle(currentTitle)
					end
				end
			else
				-- restrained fury: a constant tiny tremble
				titleHolder.Position = UDim2.fromOffset(math.random(-1, 1), 28 + math.random(-1, 1))
				if math.random() < 0.03 * glitchIntensity then
					burst = math.random(2, 4)
				end
				if math.random() < 0.012 then
					eyes()
				end

				-- cunning: the YES button twitches like bait, the NO button tries to hide
				if buttonsShown then
					local no, yes = pactButtons[1], pactButtons[2]
					if math.random() < 0.08 then
						yes.button.Position = UDim2.new(yes.x, math.random(-3, 3), 0, 106 + math.random(-2, 2))
					else
						yes.button.Position = UDim2.new(yes.x, 0, 0, 106)
					end
					if math.random() < 0.025 then
						tween(no.button, TweenInfo.new(0.12), { TextTransparency = 0.8 })
						task.delay(0.4, function()
							if no.button.Parent and buttonsShown then
								tween(no.button, TweenInfo.new(0.2), { TextTransparency = 0 })
							end
						end)
					end
				end
			end
		end
		calmGlitch()
	end)
end

local function closePact()
	if not pactOpen then
		return
	end
	pactOpen = false
	pactToken += 1
	buttonsShown = false
	rage = 0
	fadeOutOptionsSound(0.9)
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local fade = tween(overlay, info, { BackgroundTransparency = 1 })
	tween(box, info, { GroupTransparency = 1 })
	tween(boxScale, info, { Scale = 0.93 })
	fade.Completed:Once(function()
		if not pactOpen then
			overlay.Visible = false
			for _, item in ipairs(pactButtons) do
				item.button.Visible = false
			end
		end
	end)
end

local function openPact()
	if pactOpen then
		return
	end
	pactOpen = true
	accepted = false
	pactDisabling = CONFIG.Enabled -- ESP already on: this pact will break it instead
	decoding = false
	currentTitle = ""
	glitchIntensity = 1
	buttonsShown = false
	rage = 0
	pactToken += 1
	local token = pactToken

	setTitle("")
	setSub("")
	titleMain.TextTransparency = 1
	titleMain.TextColor3 = Color3.fromRGB(225, 22, 34)
	boxStroke.Color = BLOOD.Red
	boxStroke.Transparency = 0
	for _, item in ipairs(pactButtons) do
		item.button.Visible = false
	end
	-- Demon still chained (first time) or already free (ESP is on)
	setChainsVisible(not pactDisabling)
	buildDrips(0)
	calmGlitch()

	overlay.BackgroundTransparency = 1
	overlay.Visible = true
	box.GroupTransparency = 1
	boxScale.Scale = 0.85
	tween(overlay, TweenInfo.new(0.4, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.38 })
	tween(box, TweenInfo.new(0.4, Enum.EasingStyle.Sine), { GroupTransparency = 0 })
	tween(boxScale, TI_POP, { Scale = 1 })

	-- The border slowly pulses, like something breathing
	if pulseTween then
		pulseTween:Cancel()
	end
	boxStroke.Thickness = 2
	pulseTween = tween(boxStroke, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Thickness = 3.5,
	})

	startGlitchLoop(token)

	task.spawn(function()
		task.wait(0.3)
		if token ~= pactToken then
			return
		end
		if not decodeTitle("MAKE A DEAL WITH FENRIR", token, 0.055) then
			return
		end
		setSub(pactDisabling and "YOU WOULD CHAIN ME AGAIN?" or "SEALED FOR A THOUSAND YEARS")
		task.wait(0.4)
		if token ~= pactToken then
			return
		end
		eyes()
		task.wait(0.5)
		if token ~= pactToken then
			return
		end
		showButtons() -- also starts the "options" sound
	end)
end

local function acceptPact()
	if not pactOpen or accepted then
		return
	end
	accepted = true
	local token = pactToken
	local breaking = pactDisabling

	fadeOutOptionsSound(0.9) -- the options sound fades away
	hideButtons()
	subText = ""
	tween(subLabel, TweenInfo.new(0.3), { TextTransparency = 1 })

	if breaking then
		-- Second time around: the demon is chained again and ESP turns off at once
		playSound(CONFIG.Sounds.Revoke)
		setEnabled(false)
		restoreChains()
		glitchIntensity = 4
	else
		-- First time: the chains shatter and the chosen functions turn on immediately
		playSound(CONFIG.Sounds.Accept)
		setEnabled(true)
		breakChains()
		glitchIntensity = 3
	end

	rage = breaking and 26 or 22
	slash()

	redFlash.BackgroundTransparency = breaking and 0.3 or 0.5
	redFlash.Visible = true
	local flash = tween(redFlash, TweenInfo.new(breaking and 1.5 or 1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	flash.Completed:Once(function()
		redFlash.Visible = false
	end)

	tween(boxStroke, TweenInfo.new(0.4), { Color = BLOOD.Bright })
	tween(titleMain, TweenInfo.new(0.4), { TextColor3 = Color3.fromRGB(255, 40, 48) })
	buildDrips(breaking and 40 or 24)

	task.spawn(function()
		-- Enabled: the demon seizes the body and ignores the player completely.
		-- Disabled: the demon rages at being betrayed.
		local lines = breaking and { "YOU BETRAYED ME", "YOU WILL PAY" }
			or { "THIS BODY IS MINE", "THEY CHAINED ME", "THEY WILL ALL BURN", "YOU MEAN NOTHING TO ME" }

		for i, line in ipairs(lines) do
			if not decodeTitle(line, token, 0.05) then
				return
			end
			task.wait(i < #lines and 0.75 or 2)
			if token ~= pactToken then
				return
			end
			if i < #lines then
				rage = 8 -- it thrashes between sentences
			end
		end
		closePact()
	end)
end

noBtn.Activated:Connect(closePact)
yesBtn.Activated:Connect(acceptPact)

local function skipPact(input)
	if accepted and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		closePact()
	end
end
overlay.InputBegan:Connect(skipPact)
box.InputBegan:Connect(skipPact)

----------------------------------------------------------------------
-- UI: button look, menu open / close
----------------------------------------------------------------------
function updateButtonVisual()
	local on = CONFIG.Enabled
	stateLabel.Text = on and "ON" or "OFF"
	tween(stateLabel, TI_FAST, { TextColor3 = on and THEME.White or THEME.Gray })
	tween(buttonStroke, TI_FAST, {
		Color = on and THEME.White or THEME.Dim,
		Transparency = on and 0.05 or 0.3,
	})
	tween(button, TI_FAST, { BackgroundColor3 = on and THEME.PanelOn or THEME.Black })
	-- The Depressed button glows brighter while the pact is active
	tween(depStroke, TI_FAST, {
		Color = on and BLOOD.Bright or BLOOD.Crimson,
		Transparency = on and 0 or 0.2,
	})
end

local menuOpen = false

-- Open the menu below the button, or above / to the left if it would leave the screen
local function placeMenu()
	local screen = gui.AbsoluteSize
	local ax, ay = anchor.Position.X.Offset, anchor.Position.Y.Offset
	local x = 0
	if ax + MENU_W > screen.X then
		x = BUTTON - MENU_W
	end
	local y = BUTTON + 8
	if ay + y + MENU_H > screen.Y then
		y = -(MENU_H + 8)
	end
	menu.Position = UDim2.fromOffset(x, y)
end

local function setMenuOpen(open)
	menuOpen = open
	if open then
		placeMenu()
		menuScale.Scale = 0.85
		menu.Visible = true
		tween(menuScale, TI_POP, { Scale = 1 })
	else
		local closing = tween(menuScale, TI_FAST, { Scale = 0.85 })
		closing.Completed:Once(function()
			if not menuOpen then
				menu.Visible = false
			end
		end)
	end
	tween(gear, TI_FAST, { BackgroundColor3 = open and THEME.Dim or THEME.Panel })
end

----------------------------------------------------------------------
-- UI: dragging (mouse + touch). Tap vs drag is told apart by a small threshold.
----------------------------------------------------------------------
local function clampToScreen(pos)
	local screen = gui.AbsoluteSize
	return Vector2.new(
		math.clamp(pos.X, 0, math.max(0, screen.X - (BUTTON + 4))),
		math.clamp(pos.Y, 6, math.max(6, screen.Y - BUTTON))
	)
end

local dragging, dragInput, dragStart, dragOrigin = false, nil, nil, nil
local dragMoved = false
local moveConn, endConn = nil, nil

-- Each draggable button has its own anchor and its own lock setting
local mainTarget = {
	anchor = anchor,
	locked = function()
		return CONFIG.LockButton
	end,
	onMove = function()
		if menuOpen then
			placeMenu()
		end
	end,
}
local depTarget = {
	anchor = depAnchor,
	locked = function()
		return CONFIG.LockDepressed
	end,
}

local function stopDrag()
	dragging = false
	dragInput = nil
	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end
	if endConn then
		endConn:Disconnect()
		endConn = nil
	end
end

local function beginDrag(input, target, onTap)
	local kind = input.UserInputType
	if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
		return
	end
	if dragging then
		return
	end

	dragging = true
	dragInput = input
	dragStart = input.Position
	dragOrigin = Vector2.new(target.anchor.Position.X.Offset, target.anchor.Position.Y.Offset)
	dragMoved = false

	endConn = input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End then
			if not dragMoved and onTap then
				task.defer(onTap)
			end
			stopDrag()
		end
	end)

	-- Only connected while a drag is active, so zero idle cost
	moveConn = UserInputService.InputChanged:Connect(function(changed)
		if changed.UserInputType == Enum.UserInputType.MouseMovement or changed == dragInput then
			local delta = changed.Position - dragStart
			if not dragMoved and delta.Magnitude > 6 then
				dragMoved = true -- it's a drag now, not a tap
			end
			if not dragMoved or target.locked() then
				return -- locked: the button stays where it is
			end
			local pos = clampToScreen(dragOrigin + Vector2.new(delta.X, delta.Y))
			target.anchor.Position = UDim2.fromOffset(pos.X, pos.Y)
			if target.onMove then
				target.onMove()
			end
		end
	end)
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- Round ESP button: tap = ON / OFF
button.InputBegan:Connect(function(input)
	if isPress(input) then
		tween(btnScale, TI_FAST, { Scale = 0.92 })
	end
	beginDrag(input, mainTarget, function()
		setEnabled(not CONFIG.Enabled)
	end)
end)
button.InputEnded:Connect(function(input)
	if isPress(input) then
		tween(btnScale, TI_FAST, { Scale = 1 })
	end
end)

-- Depressed button: tap = open the "MAKE A DEAL WITH FENRIR" box
depButton.InputBegan:Connect(function(input)
	if isPress(input) then
		tween(depScale, TI_FAST, { Scale = 0.92 })
	end
	beginDrag(input, depTarget, openPact)
end)
depButton.InputEnded:Connect(function(input)
	if isPress(input) then
		tween(depScale, TI_FAST, { Scale = 1 })
	end
end)

gear.Activated:Connect(function()
	setMenuOpen(not menuOpen)
end)

-- Keep the Depressed button on screen if the screen size changes
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local current = Vector2.new(depAnchor.Position.X.Offset, depAnchor.Position.Y.Offset)
	local target = clampToScreen(current)
	if target ~= current then
		tween(depAnchor, TI_MED, { Position = UDim2.fromOffset(target.X, target.Y) })
	end
end)

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local current = Vector2.new(anchor.Position.X.Offset, anchor.Position.Y.Offset)
	local target = clampToScreen(current)
	if target ~= current then
		tween(anchor, TI_MED, { Position = UDim2.fromOffset(target.X, target.Y) })
	end
	if menuOpen then
		placeMenu()
	end
end)

----------------------------------------------------------------------
-- Unload + start
----------------------------------------------------------------------
local function unload()
	running = false
	pactOpen = false
	pactToken += 1
	for _, conn in ipairs(globalConns) do
		conn:Disconnect()
	end
	stopDrag()
	for player in pairs(playerConns) do
		removePlayer(player)
	end
	if pulseTween then
		pulseTween:Cancel()
	end
	holder:Destroy()
	gui:Destroy()
	if env.Helheim and env.Helheim.Unload == unload then
		env.Helheim = nil
	end
end

env.Helheim = { Unload = unload, Config = CONFIG }

updateButtonVisual()
gui.Parent = playerGui
tween(btnScale, TI_POP, { Scale = 1 })
tween(depScale, TI_POP, { Scale = 1 })
print("[Helheim] Loaded")
