--[[
	HELHEIM — event-based player ESP

	  • Round "Config" button: tap = open / close the config menu, drag = move it
	      - Lock Config button / Lock Depressed button (stops dragging)
	      - Highlight / Names / Health / Distance / Team color switches
	      - TH / EN language
	  • Round "Depressed" button (red diamond): opens the blood contract
	      "MAKE A DEAL WITH FENRIR" (it drags on its own and can be locked in the menu)
	      - NO  = close the contract
	      - YES (ESP off) = signed in blood, the chains break, the features chosen
	                        in the menu turn on at once
	      - YES (ESP on)  = the deal is broken: ESP turns off at once
	  • There is no separate ESP on / off button: the Depressed contract does that.
	  • ESP starts OFF. While OFF everything is removed, so it costs nothing.
	  • Re-running the script replaces the old copy; Helheim.Unload() removes everything.

	Run with:  loadstring(game:HttpGet("YOUR_RAW_URL"))()
]]

local CONFIG = {
	Enabled = false, -- ESP starts OFF; use the Depressed button to start it
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

	-- If the buttons ever vanish
	UseHiddenUi = false, -- true: put the UI where game scripts cannot reach it (needs an executor with gethui / CoreGui)
	ReloadUrl = "https://raw.githubusercontent.com/film998/Helheim/main/Helheim.lua", -- if the game DELETES the UI, reload from here (max 3 times per session)

	SoundVolume = 1,
	Sounds = {
		Options = "9072301639", -- plays when the YES / NO choices appear (fades out when you pick one)
		Accept = "5665746430", -- plays when you press YES to turn ESP on
		Revoke = "5993515228", -- plays when you press YES to turn ESP off
		-- Chain sounds: paste a Roblox sound ID between the quotes (empty = no sound)
		ChainRattle = "", -- chains rattling while the demon thrashes
		ChainBreak = "", -- chains shattering when the deal is signed
		ChainSlam = "", -- chains slamming back when the deal is broken
		-- More optional sounds for the contract (empty = no sound)
		Open = "", -- the contract appears (a deep boom or a wolf growl fits)
		Heartbeat = "", -- every heartbeat while the contract is open
		Whisper = "", -- when a whispered word flashes (LET ME OUT, BURN...)
		Eyes = "", -- when the glowing eyes open
		Slash = "", -- claw marks slashing
		Stamp = "", -- the bloody thumb slamming down on the contract
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
local ContentProvider = game:GetService("ContentProvider")

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
		lock = "ล็อกปุ่ม Config",
		lockDep = "ล็อกปุ่ม Depressed",
		highlight = "ไฮไลต์ผู้เล่น",
		names = "แสดงชื่อ",
		health = "แสดงเลือด",
		distance = "แสดงระยะ",
		team = "ใช้สีทีม",
		lang = "ภาษา",
	},
	EN = {
		lock = "Lock Config button",
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
-- UI: config button, Depressed button, config menu
----------------------------------------------------------------------
local BUTTON = 44
local MENU_W, MENU_H = 200, 298

local gui = new("ScreenGui", {
	Name = "HelheimGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 2147483647,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

----------------------------------------------------------------------
-- Sounds: created up front and preloaded, so they start with no delay
----------------------------------------------------------------------
local sfx = {} -- [name] = Sound
local lastPlayed = {}
local fadeTweens = {}
local fadeTokens = {}

for name, id in pairs(CONFIG.Sounds) do
	if id and id ~= "" then
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = "rbxassetid://" .. id
		sound.Volume = CONFIG.SoundVolume
		sound.Parent = gui
		sfx[name] = sound
	end
end

local function preloadSounds()
	local list = {}
	for _, sound in pairs(sfx) do
		list[#list + 1] = sound
	end
	if #list > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(list)
			end)
		end)
	end
end

-- Plays a preloaded sound at once. minGap stops fast repeats (chain rattles).
local function playSfx(name, volume, minGap)
	local sound = sfx[name]
	if not sound then
		return nil
	end
	local now = os.clock()
	if minGap and lastPlayed[name] and now - lastPlayed[name] < minGap then
		return nil
	end
	lastPlayed[name] = now

	fadeTokens[name] = (fadeTokens[name] or 0) + 1 -- cancels any fade that is still running
	if fadeTweens[name] then
		fadeTweens[name]:Cancel()
		fadeTweens[name] = nil
	end
	sound.Volume = (volume or 1) * CONFIG.SoundVolume
	sound.TimePosition = 0
	sound:Play()
	return sound
end

-- Fades a sound away slowly instead of cutting it off
local function fadeOutSfx(name, seconds)
	local sound = sfx[name]
	if not sound or not sound.IsPlaying then
		return
	end
	fadeTokens[name] = (fadeTokens[name] or 0) + 1
	local token = fadeTokens[name]
	local fade = tween(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In), { Volume = 0 })
	fadeTweens[name] = fade
	fade.Completed:Once(function()
		if fadeTokens[name] == token then
			sound:Stop()
			fadeTweens[name] = nil
		end
	end)
end

----------------------------------------------------------------------
-- Config button (round) + config menu
----------------------------------------------------------------------
-- Zero-size anchor: dragging moves this, and the button and its menu follow
local anchor = new("Frame", {
	Name = "Anchor",
	Size = UDim2.fromOffset(0, 0),
	Position = UDim2.fromOffset(CONFIG.ButtonStart.X, CONFIG.ButtonStart.Y),
	BackgroundTransparency = 1,
	Parent = gui,
})

local btnScale = new("UIScale", { Scale = 0.6 }) -- pops in on start
local buttonStroke = stroke(THEME.White, 1.5, 0.15)

local function iconBar(y)
	return new("Frame", {
		Position = UDim2.fromOffset(14, y),
		Size = UDim2.fromOffset(16, 2),
		BackgroundColor3 = THEME.White,
		BorderSizePixel = 0,
	}, { round() })
end

local button = new("TextButton", {
	Name = "Config",
	Size = UDim2.fromOffset(BUTTON, BUTTON),
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = THEME.Black,
	BorderSizePixel = 0,
	Parent = anchor,
}, {
	round(),
	buttonStroke,
	btnScale,
	iconBar(9),
	iconBar(14),
	iconBar(19),
	new("TextLabel", {
		Position = UDim2.fromOffset(3, 24),
		Size = UDim2.new(1, -6, 0, 14),
		BackgroundTransparency = 1,
		Text = "Config",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = THEME.Gray,
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
-- "Depressed" button: its own round button (drag + lock), opens the contract
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- The contract ("MAKE A DEAL WITH FENRIR"): blood-stained pact, chains, glitch text
----------------------------------------------------------------------
local GLYPHS = { "#", "%", "&", "@", "$", "?", "!", "/", "\\", "|", "X", "0", "*", "+", "=" }
local WHISPERS = { "LET ME OUT", "MINE", "SUFFER", "BURN", "RUN", "FREE" }

local function randomGlyph()
	return GLYPHS[math.random(#GLYPHS)]
end

local BOX_W, BOX_H = 468, 328
local CARD_W, CARD_H = 460, 320
local TITLE_Y = 22
local BTN_Y = 262
local SIG_Y = 226

-- Dark overlay that also blocks taps behind the contract
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

-- Red flash used when a decision is made
local redFlash = new("Frame", {
	Name = "PactFlash",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BLOOD.Red,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
	Parent = gui,
})

-- CanvasGroup lets the whole contract fade in and out as one piece
local boxScale = new("UIScale", { Scale = 0.85 })
local box = new("CanvasGroup", {
	Name = "PactBox",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(BOX_W, BOX_H),
	BackgroundTransparency = 1,
	GroupTransparency = 1,
	BorderSizePixel = 0,
	Active = true,
	Parent = overlay,
}, { boxScale })

-- The contract scales to fit any screen (bigger on big screens, smaller on small phones)
local function fitScale()
	local screen = gui.AbsoluteSize
	return math.clamp(math.min((screen.X - 24) / BOX_W, (screen.Y - 24) / BOX_H), 0.4, 1.35)
end

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
	new("UIGradient", {
		Color = colorSeq(Color3.fromRGB(52, 22, 15), Color3.fromRGB(24, 9, 6), Color3.fromRGB(14, 4, 3)),
		Rotation = 90,
	}),
})

-- Burnt edges (dark fade around the paper)
local function vignette(position, size, rotation)
	return new("Frame", {
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Parent = card,
	}, {
		new("UIGradient", {
			Rotation = rotation,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
end
vignette(UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 38), 90)
vignette(UDim2.new(0, 0, 1, -38), UDim2.new(1, 0, 0, 38), 270)
vignette(UDim2.fromOffset(0, 0), UDim2.new(0, 38, 1, 0), 0)
vignette(UDim2.new(1, -38, 0, 0), UDim2.new(0, 38, 1, 0), 180)

-- Old blood stains on the paper
for _ = 1, 9 do
	local size = math.random(6, 26)
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(math.random(20, CARD_W - 20), math.random(14, CARD_H - 14)),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = BLOOD.Crimson,
		BackgroundTransparency = 0.5 + math.random() * 0.35,
		BorderSizePixel = 0,
		Parent = card,
	}, { round() })
end

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
	Position = UDim2.fromOffset(0, TITLE_Y),
	Size = UDim2.new(1, 0, 0, 64),
	BackgroundTransparency = 1,
	Parent = card,
})

local function titleLayer(color, transparency)
	return new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.Creepster,
		TextScaled = true, -- long lines shrink to fit
		TextColor3 = color,
		TextTransparency = transparency,
		Text = "",
		Parent = titleHolder,
	}, { new("UITextSizeConstraint", { MaxTextSize = 46, MinTextSize = 18 }) })
end
local ghostB = titleLayer(BLOOD.Crimson, 0.2)
local ghostA = titleLayer(BLOOD.Bone, 0.55)
local titleMain = titleLayer(Color3.fromRGB(225, 22, 34), 1)

local function setTitle(text)
	titleMain.Text = text
	ghostA.Text = text
	ghostB.Text = text
end

-- Whispered subtitle under the title
local subText = ""
local subLabel = new("TextLabel", {
	Position = UDim2.fromOffset(0, 88),
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Font = Enum.Font.Creepster,
	TextSize = 20,
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
		tween(subLabel, TweenInfo.new(0.6, Enum.EasingStyle.Sine), { TextTransparency = 0.15 })
	end
end

-- Thin ornamental rule between the header and the clauses
new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 116),
	Size = UDim2.fromOffset(320, 1),
	BackgroundColor3 = THEME.White,
	BorderSizePixel = 0,
	Parent = card,
}, {
	new("UIGradient", {
		Color = colorSeq(BLOOD.Crimson, BLOOD.Bright, BLOOD.Crimson),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}),
})

-- The clauses write themselves, letter by letter
local clauseLabels = {}
for i = 1, 3 do
	clauseLabels[i] = new("TextLabel", {
		Position = UDim2.fromOffset(34, 122 + (i - 1) * 22),
		Size = UDim2.fromOffset(CARD_W - 68, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Antique,
		TextScaled = true,
		TextColor3 = BLOOD.Bone,
		TextTransparency = 0.1,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxVisibleGraphemes = 0,
		Text = "",
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 15, MinTextSize = 8 }) })
end

local CLAUSES = {
	deal = {
		"I.  I LEND MY EYES TO THE WOLF. ALL PREY SHALL BE SEEN.",
		"II.  MY BODY IS THE PRICE. HIS HUNGER IS NOT MINE.",
		"III.  A BROKEN OATH IS PAID IN BLOOD.",
	},
	breaking = {
		"I.  THIS DEAL WAS SEALED IN BLOOD AND CANNOT BE UNDONE.",
		"II.  TO BREAK IT IS TO BREAK YOURSELF.",
		"III.  THE WOLF REMEMBERS EVERY OATH. HE ALWAYS COLLECTS.",
	},
}

-- Signature line, wax seal and bloody fingerprint
new("TextLabel", {
	Position = UDim2.fromOffset(88, SIG_Y - 16),
	Size = UDim2.fromOffset(22, 28),
	BackgroundTransparency = 1,
	Text = "X",
	Font = Enum.Font.Creepster,
	TextSize = 26,
	TextColor3 = BLOOD.Red,
	Parent = card,
})
new("Frame", {
	Position = UDim2.fromOffset(112, SIG_Y + 10),
	Size = UDim2.fromOffset(206, 1),
	BackgroundColor3 = BLOOD.Bone,
	BackgroundTransparency = 0.55,
	BorderSizePixel = 0,
	Parent = card,
})
new("TextLabel", {
	Position = UDim2.fromOffset(112, SIG_Y + 13),
	Size = UDim2.fromOffset(206, 14),
	BackgroundTransparency = 1,
	Text = "SIGN IN BLOOD",
	Font = Enum.Font.Antique,
	TextSize = 11,
	TextColor3 = BLOOD.Bone,
	TextTransparency = 0.5,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = card,
})
local sigInk = new("Frame", { -- the signature is written in blood
	Position = UDim2.fromOffset(112, SIG_Y + 8),
	Size = UDim2.fromOffset(0, 3),
	BackgroundColor3 = BLOOD.Bright,
	BorderSizePixel = 0,
	Parent = card,
}, { round() })

local sealScale = new("UIScale", { Scale = 1 })
new("Frame", { -- wax seal
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(58, SIG_Y),
	Size = UDim2.fromOffset(36, 36),
	BackgroundColor3 = BLOOD.Crimson,
	BorderSizePixel = 0,
	Parent = card,
}, {
	round(),
	stroke(Color3.fromRGB(60, 0, 5), 2, 0),
	sealScale,
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(24, 24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, { round(), stroke(Color3.fromRGB(150, 20, 28), 1.5, 0.3) }),
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(9, 9),
		Rotation = 45,
		BackgroundColor3 = Color3.fromRGB(150, 20, 28),
		BorderSizePixel = 0,
	}),
})
local sealCrack = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(58, SIG_Y),
	Size = UDim2.fromOffset(0, 2),
	Rotation = -50,
	BackgroundColor3 = Color3.new(0, 0, 0),
	BorderSizePixel = 0,
	Parent = card,
})

local FP_X, FP_Y = 376, SIG_Y - 2
local fpScale = new("UIScale", { Scale = 1 })
local fpBlob = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(FP_X, FP_Y),
	Size = UDim2.fromOffset(54, 54),
	BackgroundColor3 = BLOOD.Red,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = card,
}, { round() })
local fingerprint = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(FP_X, FP_Y),
	Size = UDim2.fromOffset(46, 46),
	BackgroundTransparency = 1,
	Parent = card,
}, { fpScale })
local fpStrokes = {}
for i = 0, 4 do
	local d = 44 - i * 8
	local ringStroke = stroke(BLOOD.Bright, 1.5, 1)
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, (i % 2 == 0) and 1 or -1, 0.5, 0),
		Size = UDim2.fromOffset(d, d + (i % 2) * 4),
		BackgroundTransparency = 1,
		Parent = fingerprint,
	}, { round(), ringStroke })
	fpStrokes[#fpStrokes + 1] = ringStroke
end

-- The contract is struck through when the deal is broken
local voidBars = {}
for i = 1, 2 do
	voidBars[i] = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(0, 7),
		Rotation = i == 1 and 11 or -11,
		BackgroundColor3 = BLOOD.Bright,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = card,
	}, { round() })
end

-- Small helpers for the signing moments
local function thud(power)
	box.Position = UDim2.new(0.5, math.random(-power, power), 0.5, math.random(-power, power))
	tween(box, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.5) })
end

local function setSigned(signed)
	sigInk.Size = UDim2.fromOffset(signed and 200 or 0, 3)
	for _, st in ipairs(fpStrokes) do
		st.Transparency = signed and 0.05 or 1
	end
	fpScale.Scale = 1
	fpBlob.BackgroundTransparency = signed and 0.55 or 1
	sealCrack.Size = UDim2.fromOffset(0, 2)
	for _, bar in ipairs(voidBars) do
		bar.BackgroundTransparency = 1
		bar.Size = UDim2.fromOffset(0, 7)
	end
end

-- Signing: the signature is written, then the bloody thumb slams down
local function signContract()
	tween(sigInk, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(200, 3) })
	task.delay(0.3, function()
		fpScale.Scale = 1.8
		for _, st in ipairs(fpStrokes) do
			st.Transparency = 1
		end
		local info = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(fpScale, info, { Scale = 1 })
		for _, st in ipairs(fpStrokes) do
			tween(st, info, { Transparency = 0.05 })
		end
		tween(fpBlob, TweenInfo.new(0.25), { BackgroundTransparency = 0.55 })
		playSfx("Stamp")
		sealScale.Scale = 1.4
		tween(sealScale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		thud(6)
	end)
end

-- Breaking the deal: two blood-red strikes cut across the contract and the seal cracks
local function voidContract()
	for i, bar in ipairs(voidBars) do
		task.delay((i - 1) * 0.12, function()
			bar.BackgroundTransparency = 0.05
			bar.Size = UDim2.fromOffset(0, 7)
			tween(bar, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(440, 7) })
			thud(6)
		end)
	end
	tween(sealCrack, TweenInfo.new(0.2), { Size = UDim2.fromOffset(44, 2) })
end

-- The demon's cage: chains hang down both sides of the contract
local STEEL = Color3.fromRGB(128, 126, 132)
local RUST = Color3.fromRGB(122, 52, 40)

local buttonsShown = false
local rage = 0 -- while > 0 the demon thrashes violently

local chainLinks = {}
local chainRows = math.floor((CARD_H - 28) / 16)
for side = 1, 2 do
	local x = side == 1 and 14 or CARD_W - 14
	for i = 0, chainRows - 1 do
		local y = 16 + i * 16
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

-- Claw marks that slash across the top-right corner
local slashFrames = {}
for i = 1, 3 do
	slashFrames[i] = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(CARD_W - 120 + i * 16, 12),
		Size = UDim2.fromOffset(0, 2),
		Rotation = 58,
		BackgroundColor3 = BLOOD.Bright,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = card,
	})
end

local function slash()
	playSfx("Slash", 0.7, 0.3)
	for i, f in ipairs(slashFrames) do
		task.delay(i * 0.05, function()
			if not f.Parent then
				return
			end
			f.BackgroundTransparency = 0.15
			f.Size = UDim2.fromOffset(0, 2)
			tween(f, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(64, 2) })
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
local EYE_SPOTS = { Vector2.new(70, 14), Vector2.new(CARD_W - 70, 14), Vector2.new(70, CARD_H - 12), Vector2.new(CARD_W - 70, CARD_H - 12) }

local function eyes()
	if eyesBusy then
		return
	end
	eyesBusy = true
	playSfx("Eyes", 0.5, 1)
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

-- NO / YES buttons
local pactButtons = {}
local function makePactButton(text, xScale, fill, hoverFill, strokeColor, textColor)
	local btnStroke = stroke(strokeColor, 1.5, 1)
	local pressScale = new("UIScale", { Scale = 1 })
	local btn = new("TextButton", {
		Name = text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(xScale, 0, 0, BTN_Y),
		Size = UDim2.fromOffset(140, 42),
		AutoButtonColor = false,
		Text = text,
		Font = Enum.Font.Creepster,
		TextSize = 30,
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
	playSfx("Options") -- preloaded, so it starts the instant the choices appear
	buttonsShown = true
	for _, item in ipairs(pactButtons) do
		item.button.Visible = true
		item.button.BackgroundTransparency = 1
		item.button.TextTransparency = 1
		item.stroke.Transparency = 1
		local info = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
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
	for i = 1, 10 do
		local w = math.random(3, 7)
		local drip = new("Frame", {
			Position = UDim2.new(math.random(5, 95) / 100, 0, 0, 0),
			Size = UDim2.fromOffset(w, 0),
			BackgroundColor3 = BLOOD.Red,
			BorderSizePixel = 0,
			Parent = card,
		}, { round() })
		drips[i] = drip
		task.delay(math.random() * 0.8, function()
			if drip.Parent then
				tween(drip, TweenInfo.new(1 + math.random() * 1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.fromOffset(w, math.random(16, 56) + (extra or 0)),
				})
			end
		end)
	end
end

----------------------------------------------------------------------
-- Contract logic: state, decode effect, glitch loop, open / accept / close
----------------------------------------------------------------------
local pactOpen = false
local pactToken = 0 -- bumping this stops every running contract animation
local accepted = false
local pactDisabling = false -- true when ESP is already on: this contract breaks the deal
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
	tween(titleMain, TweenInfo.new(0.4, Enum.EasingStyle.Sine), { TextTransparency = 0 })

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

-- The clauses write themselves onto the contract
local function writeClauses(token, lines)
	for i, label in ipairs(clauseLabels) do
		label.MaxVisibleGraphemes = 0
		label.Text = lines[i] or ""
	end
	for _, label in ipairs(clauseLabels) do
		local n = #label.Text
		local shown = 0
		while shown < n do
			if token ~= pactToken then
				return
			end
			shown = math.min(n, shown + 3)
			label.MaxVisibleGraphemes = shown
			task.wait(0.025)
		end
		label.MaxVisibleGraphemes = -1
	end
end

local function calmGlitch()
	ghostA.Position = UDim2.fromOffset(0, 0)
	ghostB.Position = UDim2.fromOffset(0, 0)
	titleHolder.Position = UDim2.fromOffset(0, TITLE_Y)
	titleMain.Rotation = 0
	box.Position = UDim2.fromScale(0.5, 0.5)
	resetChains()
	if subText ~= "" then
		subLabel.Text = subText
	end
	for _, label in ipairs(clauseLabels) do
		label.TextTransparency = 0.1
	end
	local yes = pactButtons[2]
	if yes then
		yes.button.Position = UDim2.new(yes.x, 0, 0, BTN_Y)
	end
end

-- Runs only while the contract is open. Nothing is on a fixed rhythm: it trembles, then
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
				playSfx("ChainRattle", 0.7, 0.45)
				boxStroke.Transparency = math.random() < 0.4 and 0.7 or 0
				clauseLabels[math.random(#clauseLabels)].TextTransparency = 0.65

				if not decoding and currentTitle ~= "" then
					if math.random() < 0.18 then
						playSfx("Whisper", 0.5, 1.5)
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
				titleHolder.Position = UDim2.fromOffset(math.random(-1, 1), TITLE_Y + math.random(-1, 1))
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
						yes.button.Position = UDim2.new(yes.x, math.random(-3, 3), 0, BTN_Y + math.random(-2, 2))
					else
						yes.button.Position = UDim2.new(yes.x, 0, 0, BTN_Y)
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

-- Heartbeat: the whole screen pulses blood red (lub-dub), at an uneven pace
local function startHeartbeat(token)
	task.spawn(function()
		while pactOpen and token == pactToken do
			for _ = 1, 2 do
				playSfx("Heartbeat", 0.6, 0.05)
				tween(overlay, TweenInfo.new(0.07), { BackgroundColor3 = Color3.fromRGB(70, 0, 6) })
				task.wait(0.09)
				tween(overlay, TweenInfo.new(0.16), { BackgroundColor3 = Color3.new(0, 0, 0) })
				task.wait(0.14)
			end
			task.wait(0.5 + math.random() * 0.6)
		end
		overlay.BackgroundColor3 = Color3.new(0, 0, 0)
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
	fadeOutSfx("Options", 0.9)
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local fade = tween(overlay, info, { BackgroundTransparency = 1 })
	tween(box, info, { GroupTransparency = 1 })
	tween(boxScale, info, { Scale = fitScale() * 0.93 })
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
	pactDisabling = CONFIG.Enabled -- ESP already on: this contract breaks the deal instead
	decoding = false
	currentTitle = ""
	glitchIntensity = 1
	buttonsShown = false
	rage = 0
	pactToken += 1
	local token = pactToken
	local fit = fitScale()
	local breaking = pactDisabling

	setTitle("")
	setSub("")
	for _, label in ipairs(clauseLabels) do
		label.Text = ""
		label.MaxVisibleGraphemes = 0
	end
	titleMain.TextTransparency = 1
	titleMain.TextColor3 = Color3.fromRGB(225, 22, 34)
	boxStroke.Color = BLOOD.Red
	boxStroke.Transparency = 0
	for _, item in ipairs(pactButtons) do
		item.button.Visible = false
	end
	setChainsVisible(not breaking) -- demon still chained (first time) or already free (ESP on)
	setSigned(breaking) -- already signed in blood when the deal exists
	buildDrips(0)
	calmGlitch()

	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.Visible = true
	box.GroupTransparency = 1
	boxScale.Scale = fit * 0.85
	tween(overlay, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.38 })
	tween(box, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { GroupTransparency = 0 })
	tween(boxScale, TI_POP, { Scale = fit })

	-- The border slowly pulses, like something breathing
	if pulseTween then
		pulseTween:Cancel()
	end
	boxStroke.Thickness = 2
	pulseTween = tween(boxStroke, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Thickness = 3.5,
	})

	playSfx("Open")
	playSfx("ChainRattle", 0.8)
	startGlitchLoop(token)
	startHeartbeat(token)

	task.spawn(function()
		task.wait(0.1)
		if token ~= pactToken then
			return
		end
		local lines = breaking and CLAUSES.breaking or CLAUSES.deal
		task.spawn(function()
			task.wait(0.25)
			writeClauses(token, lines)
		end)
		if not decodeTitle(breaking and "BREAK THE DEAL WITH FENRIR" or "MAKE A DEAL WITH FENRIR", token, 0.04) then
			return
		end
		setSub(breaking and "A BROKEN DEAL IS PAID IN BLOOD" or "SEALED FOR A THOUSAND YEARS")
		task.wait(0.12)
		if token ~= pactToken then
			return
		end
		eyes()
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

	fadeOutSfx("Options", 0.9) -- the options sound fades away
	hideButtons()
	subText = ""
	tween(subLabel, TweenInfo.new(0.3), { TextTransparency = 1 })

	if breaking then
		-- Second time around: the deal is torn up, the chains slam back, ESP turns off at once
		playSfx("Revoke")
		playSfx("ChainSlam")
		setEnabled(false)
		restoreChains()
		voidContract()
		glitchIntensity = 4
	else
		-- First time: signed in blood, the chains shatter, the chosen functions turn on immediately
		playSfx("Accept")
		setEnabled(true)
		signContract()
		task.delay(0.3, function()
			playSfx("ChainBreak")
			breakChains()
		end)
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
		-- Disabled: the demon rages at the broken deal.
		local lines = breaking and { "YOU BROKE THE DEAL", "YOU BETRAYED ME", "YOU WILL PAY" }
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

-- Tap anywhere to skip the speech after accepting
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
-- The Depressed button glows brighter while the deal is active
function updateButtonVisual()
	local on = CONFIG.Enabled
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
	tween(buttonStroke, TI_FAST, {
		Thickness = open and 2.2 or 1.5,
		Transparency = open and 0 or 0.15,
	})
end

----------------------------------------------------------------------
-- UI: dragging (mouse + touch). Tap vs drag is told apart by a small threshold.
----------------------------------------------------------------------
local function clampToScreen(pos)
	local screen = gui.AbsoluteSize
	return Vector2.new(
		math.clamp(pos.X, 0, math.max(0, screen.X - (BUTTON + 4))),
		math.clamp(pos.Y, 54, math.max(54, screen.Y - BUTTON))
	)
end

local dragging, dragInput, dragStart, dragOrigin = false, nil, nil, nil
local dragMoved = false
local moveConn, endConn = nil, nil

-- Each draggable button has its own anchor and its own lock setting
local mainTarget = {
	anchor = anchor,
	desired = Vector2.new(CONFIG.ButtonStart.X, CONFIG.ButtonStart.Y),
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
	desired = Vector2.new(CONFIG.DepressedStart.X, CONFIG.DepressedStart.Y),
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
			target.desired = pos
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

-- Config button: tap = open / close the config menu right away
button.InputBegan:Connect(function(input)
	if isPress(input) then
		tween(btnScale, TI_FAST, { Scale = 0.92 })
	end
	beginDrag(input, mainTarget, function()
		setMenuOpen(not menuOpen)
	end)
end)
button.InputEnded:Connect(function(input)
	if isPress(input) then
		tween(btnScale, TI_FAST, { Scale = 1 })
	end
end)

-- Depressed button: tap = open the contract
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

-- Keep both buttons on screen (and the contract the right size) if the screen changes
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	for _, target in ipairs({ mainTarget, depTarget }) do
		local a = target.anchor
		local current = Vector2.new(a.Position.X.Offset, a.Position.Y.Offset)
		if gui.AbsoluteSize.X < 80 or gui.AbsoluteSize.Y < 80 then
			break -- ignore a bogus tiny screen size (it would shove the buttons into a corner)
		end
		local pos = clampToScreen(target.desired)
		if pos ~= current then
			tween(a, TI_MED, { Position = UDim2.fromOffset(pos.X, pos.Y) })
		end
	end
	if menuOpen then
		placeMenu()
	end
	if pactOpen then
		boxScale.Scale = fitScale()
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
local guiParent = playerGui
if CONFIG.UseHiddenUi then
	guiParent = pickParent()
end
gui.Parent = guiParent
preloadSounds()
tween(btnScale, TI_POP, { Scale = 1 })
tween(depScale, TI_POP, { Scale = 1 })
-- Watchdog: if the game hides, moves or changes the UI, put it back
gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if running and not gui.Enabled then
		gui.Enabled = true
	end
end)

task.spawn(function()
	while running do
		task.wait(1)
		if gui.Parent ~= guiParent then
			pcall(function()
				gui.Parent = guiParent
			end)
		end
		if not gui.Enabled then
			gui.Enabled = true
		end
		if gui.ResetOnSpawn then
			gui.ResetOnSpawn = false
		end
		if gui.DisplayOrder ~= 2147483647 then
			gui.DisplayOrder = 2147483647
		end
	end
end)

-- Rescue: if the game DELETES the UI, load a fresh copy (at most 3 times per session)
local reloads = env.__HelheimReloads or 0
gui.Destroying:Connect(function()
	if not running then
		return -- we are unloading on purpose
	end
	if CONFIG.ReloadUrl ~= "" and reloads < 3 then
		env.__HelheimReloads = reloads + 1
		task.defer(function()
			pcall(unload)
			local ok, err = pcall(function()
				loadstring(game:HttpGet(CONFIG.ReloadUrl))()
			end)
			if not ok then
				warn("[Helheim] reload failed:", err)
			end
		end)
	else
		warn("[Helheim] The UI was removed by the game")
	end
end)

print("[Helheim] Loaded")
