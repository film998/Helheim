--[[
	HELHEIM — event-based player ESP

	  • One button: the "Revenge" tome (a forbidden book). Tap it = the contract opens,
	    drag it = move it.
	  • The contract "MAKE A DEAL WITH FENRIR" IS the settings window. You choose what
	    Fenrir grants you by ticking the boons:
	        sight through walls / true names / life force / distance to prey /
	        allegiance (team colors) / endless leaps (infinite jump) / Fenrir's speed (slide the bar or type 1-1000) /
	        ghosting (noclip, with its own quick on/off button) / bind this tome in place (lock the button)
	  • Sign on the line by typing YES or NO (any capitalization):
	        YES (ESP off) = signed in blood, the chains break, the ticked boons turn on at once
	        YES (ESP on)  = the deal is broken: ESP turns off at once
	        NO            = the contract rolls itself up like a scroll
	    Tapping the dark area outside the contract also rolls it up.
	  • ESP starts OFF. While OFF everything is removed, so it costs nothing.
	  • Re-running the script replaces the old copy; Helheim.Unload() removes everything.

	Run with:  loadstring(game:HttpGet("YOUR_RAW_URL"))()
]]

local CONFIG = {
	Enabled = false, -- ESP starts OFF; open the Revenge tome and sign YES to start it
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

	-- Powers (they work only while the deal is active, and switch off at once when it is broken)
	InfiniteJump = true, -- jump again and again in mid-air
	Swiftness = true, -- run faster
	SpeedValue = 50, -- walk speed, 1 to 1000 (slide the bar or type it on the contract). Normal speed returns when this is off
	Noclip = true, -- ghosting: walk through walls (a quick on/off button appears while it is switched on)

	LockButton = false, -- true: the Revenge tome cannot be dragged (also a boon on the contract)
	ButtonStart = Vector2.new(24, 140),
	GhostButtonStart = Vector2.new(24, 196), -- the quick Ghosting button
	-- Optional: your own picture for the Revenge tome (paste an Image ID; empty = the drawn book)
	BookImage = "",
	BookImageActive = "", -- optional picture used while ESP is on (empty = same picture + a red glow)

	-- If the game hides or removes the tome (cutscenes, loading screens...)
	UseHiddenUi = true, -- true: the UI lives OUTSIDE the game (gethui / CoreGui), so game scripts and cutscenes cannot touch it. false: it sits in PlayerGui
	ReloadUrl = "", -- optional: if the game ever DELETES the UI, reload the script from this raw link (max 3 times). Empty = off
	SoundVolume = 1,
	Sounds = {
		Options = "9072301639", -- plays when the signature line appears (fades out once you sign)
		Accept = "5665746430", -- plays when you sign YES to turn ESP on
		Revoke = "5993515228", -- plays when you sign YES to break the deal (ESP off)
		Heartbeat = "130313000679525", -- every heartbeat while the contract is open
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
local RunService = game:GetService("RunService")
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

----------------------------------------------------------------------
-- Powers: infinite jump, speed, noclip (on only while the deal is active)
----------------------------------------------------------------------
local powers = { noclipParts = {}, noclipOriginal = {} }
local ghostOn = true -- the quick Ghosting button flips this
local updateGhostButton -- defined in the UI section

local function getHumanoid()
	local char = localPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- Infinite jump: every jump request starts a new jump, even in mid-air
local function setInfiniteJump(on)
	if on and not powers.jumpConn then
		powers.jumpConn = UserInputService.JumpRequest:Connect(function()
			local hum = getHumanoid()
			if hum then
				hum:ChangeState(Enum.HumanoidStateType.Jumping)
			end
		end)
	elseif not on and powers.jumpConn then
		powers.jumpConn:Disconnect()
		powers.jumpConn = nil
	end
end

-- Speed: set the walk speed, keep it there, and give the normal speed back when switched off
local function stopSpeed()
	if powers.speedConn then
		powers.speedConn:Disconnect()
		powers.speedConn = nil
	end
	local hum = powers.speedHumanoid
	if hum and hum.Parent and powers.savedSpeed then
		hum.WalkSpeed = powers.savedSpeed
	end
	powers.savedSpeed = nil
	powers.speedHumanoid = nil
end

local function startSpeed()
	local hum = getHumanoid()
	if not hum then
		return
	end
	if powers.speedHumanoid ~= hum then
		stopSpeed()
		powers.speedHumanoid = hum
		powers.savedSpeed = hum.WalkSpeed -- remember the normal speed
	end
	hum.WalkSpeed = CONFIG.SpeedValue
	if not powers.speedConn then
		powers.speedConn = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if hum.WalkSpeed ~= CONFIG.SpeedValue then
				hum.WalkSpeed = CONFIG.SpeedValue -- the game tried to change it back
			end
		end)
	end
end

-- Noclip: switch collisions off every physics step, and put every part back as it was when switched off
local function noclipStep()
	for part in pairs(powers.noclipParts) do
		if part.Parent then
			if part.CanCollide then
				part.CanCollide = false
			end
		else
			powers.noclipParts[part] = nil
		end
	end
end

local function trackPart(part)
	if part:IsA("BasePart") then
		powers.noclipParts[part] = true
		if powers.noclipOriginal[part] == nil then
			powers.noclipOriginal[part] = part.CanCollide
		end
	end
end

local function stopNoclip()
	if powers.noclipConn then
		powers.noclipConn:Disconnect()
		powers.noclipConn = nil
	end
	if powers.noclipAdded then
		powers.noclipAdded:Disconnect()
		powers.noclipAdded = nil
	end
	for part, original in pairs(powers.noclipOriginal) do
		if part.Parent then
			part.CanCollide = original
		end
	end
	powers.noclipParts = {}
	powers.noclipOriginal = {}
	powers.noclipChar = nil
end

local function startNoclip()
	local char = localPlayer.Character
	if not char then
		return
	end
	if powers.noclipChar ~= char then
		stopNoclip() -- a new character: forget the old one
		powers.noclipChar = char
		for _, d in ipairs(char:GetDescendants()) do
			trackPart(d)
		end
		powers.noclipAdded = char.DescendantAdded:Connect(trackPart)
	end
	if not powers.noclipConn then
		powers.noclipConn = RunService.Stepped:Connect(noclipStep)
	end
end

-- Apply the right powers for the current state (called whenever the deal or a boon changes)
local function applyPowers()
	local on = CONFIG.Enabled
	setInfiniteJump(on and CONFIG.InfiniteJump)
	if on and CONFIG.Swiftness then
		startSpeed()
	else
		stopSpeed()
	end
	local ghostAvailable = on and CONFIG.Noclip
	if ghostAvailable and not powers.ghostAvailable then
		ghostOn = true -- every time Ghosting is switched on it starts active
	end
	powers.ghostAvailable = ghostAvailable
	if ghostAvailable and ghostOn then
		startNoclip()
	else
		stopNoclip()
	end
	if updateGhostButton then
		updateGhostButton()
	end
end

-- Re-apply only the speed (used while the slider is being dragged)
local function refreshSpeed()
	if CONFIG.Enabled and CONFIG.Swiftness then
		startSpeed()
	end
end

-- After a respawn the powers have to be applied to the new character
globalConns[#globalConns + 1] = localPlayer.CharacterAdded:Connect(function(char)
	task.spawn(function()
		char:WaitForChild("Humanoid", 5)
		task.wait(0.1)
		if running and CONFIG.Enabled then
			applyPowers()
		end
	end)
end)

-- Master ON / OFF. OFF removes every ESP object, so it costs nothing.
local function setEnabled(state)
	CONFIG.Enabled = state
	applyPowers()
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

local TI_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_MED = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TI_POP = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)


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


----------------------------------------------------------------------
-- UI: the Revenge tome (a forbidden book) + sounds
----------------------------------------------------------------------
local BUTTON = 44

local gui = new("ScreenGui", {
	Name = "HelheimGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 2147483647,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

----------------------------------------------------------------------
-- Sounds: the three voices (options, accept, revoke) + the heartbeat
----------------------------------------------------------------------
local optionsSound = nil

local function playSound(id, volume)
	if not id or id == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. id
	sound.Volume = (volume or 1) * CONFIG.SoundVolume
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

----------------------------------------------------------------------
-- The Revenge button: a forbidden tome, bound in chains (same 44x44 size as before)
----------------------------------------------------------------------
-- Zero-size anchor: dragging moves this, and the book follows
local anchor = new("Frame", {
	Name = "Anchor",
	Size = UDim2.fromOffset(0, 0),
	Position = UDim2.fromOffset(CONFIG.ButtonStart.X, CONFIG.ButtonStart.Y),
	BackgroundTransparency = 1,
	Parent = gui,
})

local btnScale = new("UIScale", { Scale = 0.6 }) -- pops in on start
local coverStroke = stroke(BLOOD.Crimson, 1.5, 0.15)

-- Pages poking out on the right and bottom
local pages = new("Frame", {
	Position = UDim2.fromOffset(9, 6),
	Size = UDim2.fromOffset(31, 37),
	BackgroundColor3 = Color3.fromRGB(206, 190, 162),
	BorderSizePixel = 0,
}, { corner(3) })

local function chainBar(rotation)
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(16, 19),
		Size = UDim2.fromOffset(46, 2),
		Rotation = rotation,
		BackgroundColor3 = Color3.fromRGB(104, 104, 112),
		BorderSizePixel = 0,
	})
end

local function spineBand(y)
	return new("Frame", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.fromOffset(7, 2),
		BackgroundColor3 = Color3.fromRGB(150, 110, 60),
		BorderSizePixel = 0,
	})
end

-- The glowing mark in the middle of the cover
local emblem = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(17, 14),
	Size = UDim2.fromOffset(9, 9),
	Rotation = 45,
	BackgroundColor3 = BLOOD.Crimson,
	BorderSizePixel = 0,
})

local cover = new("Frame", {
	Position = UDim2.fromOffset(5, 3),
	Size = UDim2.fromOffset(32, 38),
	BackgroundColor3 = THEME.White, -- tinted by the gradient below
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, {
	corner(3),
	coverStroke,
	new("UIGradient", { Color = colorSeq(Color3.fromRGB(62, 15, 18), Color3.fromRGB(24, 4, 6)), Rotation = 90 }),
	chainBar(40),
	chainBar(-40),
	new("Frame", { -- leather spine
		Size = UDim2.fromOffset(7, 38),
		BackgroundColor3 = Color3.fromRGB(16, 3, 5),
		BorderSizePixel = 0,
	}, { spineBand(8), spineBand(18), spineBand(28) }),
	new("Frame", { -- ring around the emblem
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(17, 14),
		Size = UDim2.fromOffset(17, 17),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, { round(), stroke(BLOOD.Crimson, 1, 0.2) }),
	emblem,
	new("TextLabel", {
		Position = UDim2.fromOffset(10, 28),
		Size = UDim2.fromOffset(21, 8),
		BackgroundTransparency = 1,
		Text = "REVENGE",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = BLOOD.Bone,
	}, { new("UITextSizeConstraint", { MaxTextSize = 7, MinTextSize = 4 }) }),
})

local button = new("TextButton", {
	Name = "Revenge",
	Size = UDim2.fromOffset(BUTTON, BUTTON),
	AutoButtonColor = false,
	Text = "",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = anchor,
}, { btnScale, pages, cover })

local bookImage = nil
local bookGlow = nil
local glowPulse = nil
if CONFIG.BookImage ~= "" then
	pages.Visible = false
	cover.Visible = false
	bookGlow = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(52, 52),
		BackgroundColor3 = BLOOD.Red,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = button,
	}, { round() })
	bookImage = new("ImageLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = "rbxassetid://" .. CONFIG.BookImage,
		ScaleType = Enum.ScaleType.Fit,
		Parent = button,
	})

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ bookImage })
		end)
		task.wait(0.5)
		if bookImage and not bookImage.IsLoaded then
			warn("[Helheim] The tome picture could not load (the image is probably private). Using the drawn book instead.")
			bookImage.Visible = false
			bookGlow.Visible = false
			pages.Visible = true
			cover.Visible = true
			bookImage = nil
		end
	end)
end

----------------------------------------------------------------------
-- Quick Ghosting button: appears while the Ghosting boon is on. Tap = noclip on / off.
----------------------------------------------------------------------
local GHOST = Color3.fromRGB(226, 232, 240)
local ghostAnchor = new("Frame", {
	Name = "GhostAnchor",
	Size = UDim2.fromOffset(0, 0),
	Position = UDim2.fromOffset(CONFIG.GhostButtonStart.X, CONFIG.GhostButtonStart.Y),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = gui,
})
local ghostScale = new("UIScale", { Scale = 0.6 })
local ghostStroke = stroke(GHOST, 1.5, 0.05)
local ghostParts = {} -- the pale pieces of the ghost (they fade when Ghosting is off)

local function ghostPiece(props)
	props.BackgroundColor3 = GHOST
	props.BorderSizePixel = 0
	local piece = new("Frame", props, { round() })
	ghostParts[#ghostParts + 1] = { frame = piece, on = 0, off = 0.65 }
	return piece
end

local function darkPiece(props, rounded)
	props.BackgroundColor3 = Color3.fromRGB(8, 8, 10) -- same colour as the button, so it looks cut out
	props.BorderSizePixel = 0
	return new("Frame", props, rounded and { round() } or nil)
end

-- a little ghost drawn with frames: round head, wavy bottom, two eyes and a mouth
local ghostBody = ghostPiece({ Position = UDim2.fromOffset(10, 6), Size = UDim2.fromOffset(20, 22) })
local ghostCut = darkPiece({ Position = UDim2.fromOffset(8, 22), Size = UDim2.fromOffset(24, 12) }, false)
local ghostLobe1 = ghostPiece({ Position = UDim2.fromOffset(10, 21), Size = UDim2.fromOffset(7, 9) })
local ghostLobe2 = ghostPiece({ Position = UDim2.fromOffset(16.5, 21), Size = UDim2.fromOffset(7, 9) })
local ghostLobe3 = ghostPiece({ Position = UDim2.fromOffset(23, 21), Size = UDim2.fromOffset(7, 9) })

local ghostButton = new("TextButton", {
	Name = "Ghosting",
	Size = UDim2.fromOffset(40, 40),
	AutoButtonColor = false,
	Text = "",
	BackgroundColor3 = Color3.fromRGB(8, 8, 10),
	BorderSizePixel = 0,
	Parent = ghostAnchor,
}, {
	round(),
	ghostStroke,
	ghostScale,
	ghostBody,
	ghostCut,
	ghostLobe1,
	ghostLobe2,
	ghostLobe3,
	darkPiece({ Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(4, 6) }, true),
	darkPiece({ Position = UDim2.fromOffset(22, 12), Size = UDim2.fromOffset(4, 6) }, true),
	darkPiece({ Position = UDim2.fromOffset(18.5, 20), Size = UDim2.fromOffset(3, 3) }, true),
})

-- The button appears while Ghosting is on, and fades the ghost when noclip is paused
function updateGhostButton()
	local available = CONFIG.Enabled and CONFIG.Noclip
	if available and not ghostAnchor.Visible then
		ghostAnchor.Visible = true
		ghostScale.Scale = 0.6
		tween(ghostScale, TI_POP, { Scale = 1 })
	elseif not available and ghostAnchor.Visible then
		local closing = tween(ghostScale, TI_FAST, { Scale = 0.1 })
		closing.Completed:Once(function()
			if not (CONFIG.Enabled and CONFIG.Noclip) then
				ghostAnchor.Visible = false
			end
		end)
	end
	local active = available and ghostOn
	for _, part in ipairs(ghostParts) do
		tween(part.frame, TI_FAST, { BackgroundTransparency = active and part.on or part.off })
	end
	tween(ghostStroke, TI_FAST, { Color = active and GHOST or THEME.Dim, Transparency = active and 0.05 or 0.4 })
end

-- The emblem breathes slowly, like the book is alive
local emblemPulse = tween(emblem, TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
	BackgroundTransparency = 0.55,
})

----------------------------------------------------------------------
-- The contract ("MAKE A DEAL WITH FENRIR"): a blood-stained scroll with the boons you ask for
----------------------------------------------------------------------
local GLYPHS = { "#", "%", "&", "@", "$", "?", "!", "/", "\\", "|", "X", "0", "*", "+", "=" }
local WHISPERS = { "LET ME OUT", "MINE", "SUFFER", "BURN", "RUN", "FREE" }

local function randomGlyph()
	return GLYPHS[math.random(#GLYPHS)]
end

local BOX_W, BOX_H = 476, 408
local CARD_X, CARD_Y = 8, 14
local CARD_W, CARD_H = 460, 380
local TITLE_Y = 20
local SIG_Y = 326
local FIELD_X, FIELD_Y = 112, SIG_Y - 24
local ROD_BASE = 18

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

-- CanvasGroup lets the whole scroll fade as one piece
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

-- Extra upward shift while the phone keyboard is open, so the signature stays visible
local boxShiftY = 0
local function basePos()
	return UDim2.new(0.5, 0, 0.5, -boxShiftY)
end

-- On a phone the keyboard covers the lower half of the screen: lift the contract so the field stays visible
local function liftForKeyboard(fieldCenterY)
	if UserInputService.TouchEnabled then
		local screen = gui.AbsoluteSize
		boxShiftY = math.max(0, 0.14 * screen.Y + (fieldCenterY - BOX_H / 2) * boxScale.Scale)
		tween(box, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { Position = basePos() })
	end
end

local function dropKeyboardLift()
	if boxShiftY ~= 0 then
		boxShiftY = 0
		tween(box, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { Position = basePos() })
	end
end

local boxStroke = stroke(BLOOD.Red, 2, 0)
local card = new("Frame", {
	Name = "Card",
	Position = UDim2.fromOffset(CARD_X, CARD_Y),
	Size = UDim2.fromOffset(CARD_W, CARD_H),
	BackgroundColor3 = THEME.White, -- tinted by the gradient below
	BorderSizePixel = 0,
	ClipsDescendants = true, -- the paper rolls up inside this frame
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
	Position = UDim2.fromOffset(0, 86),
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

-- Thin ornamental rule between the header and the boons
new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 112),
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

----------------------------------------------------------------------
-- The boons: what you ask Fenrir to grant you (these ARE the settings)
----------------------------------------------------------------------
local BOONS = {
	{ key = "ShowHighlight", text = "SIGHT THROUGH WALLS" },
	{ key = "ShowNames", text = "THEIR TRUE NAMES" },
	{ key = "ShowHealth", text = "THEIR LIFE FORCE" },
	{ key = "ShowDistance", text = "THE DISTANCE TO PREY" },
	{ key = "UseTeamColor", text = "THEIR ALLEGIANCE" },
	{ key = "InfiniteJump", text = "ENDLESS LEAPS" }, -- infinite jump
	{ key = "Noclip", text = "GHOSTING" }, -- noclip (it gets its own quick on / off button)
	{ key = "LockButton", text = "BIND THIS TOME IN PLACE" }, -- locks the Revenge book where it is
}
-- (Fenrir's speed is the row below the grid: a blood slider)

local boonHeader = new("TextLabel", {
	Position = UDim2.fromOffset(36, 118),
	Size = UDim2.fromOffset(CARD_W - 72, 18),
	BackgroundTransparency = 1,
	Font = Enum.Font.Antique,
	TextSize = 14,
	TextColor3 = BLOOD.Bone,
	TextTransparency = 0.35,
	TextXAlignment = Enum.TextXAlignment.Left,
	MaxVisibleGraphemes = 0,
	Text = "",
	Parent = card,
})

local boonRows = {}

-- The tick box + label every boon row starts with
local function makeBoonParts(text, labelWidth)
	local checkStroke = stroke(BLOOD.Bone, 1.5, 1)
	local markScale = new("UIScale", { Scale = 0 })
	local function markBar(rotation)
		return new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(2, 20),
			Rotation = rotation,
			BackgroundColor3 = BLOOD.Bright,
			BorderSizePixel = 0,
		}, { round() })
	end
	local check = new("Frame", {
		Position = UDim2.fromOffset(0, 5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, {
		corner(2),
		checkStroke,
		new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0 }, {
			markScale,
			markBar(45),
			markBar(-45),
		}),
	})
	local label = new("TextLabel", {
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.fromOffset(labelWidth, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.Antique,
		TextScaled = true,
		TextColor3 = BLOOD.Bone,
		TextTransparency = 0.1,
		TextXAlignment = Enum.TextXAlignment.Left,
		MaxVisibleGraphemes = 0,
		Text = text,
	}, { new("UITextSizeConstraint", { MaxTextSize = 14, MinTextSize = 8 }) })
	return check, checkStroke, markScale, label
end

-- The eight boons in two columns
for i, boon in ipairs(BOONS) do
	local col = (i - 1) % 2
	local rowIndex = math.floor((i - 1) / 2)
	local x = col == 0 and 36 or 246
	local y = 142 + rowIndex * 28

	local check, checkStroke, markScale, label = makeBoonParts(boon.text, 176)
	local row = new("TextButton", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(200, 24),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Parent = card,
	}, { check, label })

	boonRows[i] = { row = row, checkStroke = checkStroke, markScale = markScale, label = label, key = boon.key }
end

----------------------------------------------------------------------
-- Fenrir's speed: a horizontal blood slider (1 to 1000) + a box to type the exact number
----------------------------------------------------------------------
local SPEED_Y = 142 + 4 * 28
local SLIDER_X, SLIDER_W = 184, 180

-- Logarithmic scale: normal speeds (16-100) get plenty of room, and 1000 is still at the end
local function speedToFraction(v)
	return math.clamp(math.log(math.clamp(v, 1, 1000)) / math.log(1000), 0, 1)
end
local function fractionToSpeed(f)
	return math.clamp(math.floor(1000 ^ f + 0.5), 1, 1000)
end

local speedCheck, speedCheckStroke, speedMarkScale, speedLabel = makeBoonParts("FENRIR'S SPEED", 112)
local speedToggle = new("TextButton", {
	Position = UDim2.fromOffset(36, SPEED_Y),
	Size = UDim2.fromOffset(140, 24),
	BackgroundTransparency = 1,
	AutoButtonColor = false,
	Text = "",
	Parent = card,
}, { speedCheck, speedLabel })

local handleScale = new("UIScale", { Scale = 1 })
local speedHandle = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0, 0, 0.5, 0),
	Size = UDim2.fromOffset(16, 16),
	BackgroundColor3 = BLOOD.Bone,
	BorderSizePixel = 0,
}, {
	round(),
	stroke(BLOOD.Red, 2, 0),
	handleScale,
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = BLOOD.Bright,
		BorderSizePixel = 0,
	}, { round() }),
})

local speedFill = new("Frame", {
	Size = UDim2.fromScale(0.4, 1),
	BackgroundColor3 = THEME.White, -- tinted by the gradient below
	BorderSizePixel = 0,
}, { round(), new("UIGradient", { Color = colorSeq(BLOOD.Crimson, BLOOD.Bright) }) })

local speedTrack = new("Frame", {
	Position = UDim2.fromOffset(0, 8),
	Size = UDim2.fromOffset(SLIDER_W, 8),
	BackgroundColor3 = Color3.fromRGB(22, 3, 5),
	BorderSizePixel = 0,
}, {
	round(),
	stroke(BLOOD.Bone, 1, 0.65),
	speedFill,
	new("Frame", { -- a faint mark where the normal walking speed (16) is
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(speedToFraction(16), 0, 0.5, 0),
		Size = UDim2.fromOffset(2, 14),
		BackgroundColor3 = BLOOD.Bone,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
	}),
	speedHandle,
})

local speedBox = new("TextBox", {
	Position = UDim2.fromOffset(SLIDER_W + 12, 2),
	Size = UDim2.fromOffset(44, 20),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ClearTextOnFocus = true,
	MultiLine = false,
	Text = tostring(CONFIG.SpeedValue),
	PlaceholderText = "1-1000",
	PlaceholderColor3 = Color3.fromRGB(130, 80, 78),
	Font = Enum.Font.Antique,
	TextSize = 14,
	TextColor3 = BLOOD.Bright,
}, { corner(3), stroke(BLOOD.Crimson, 1, 0.3) })

local speedHit = new("TextButton", { -- invisible, a little bigger than the bar, catches the finger
	Position = UDim2.fromOffset(-8, 0),
	Size = UDim2.fromOffset(SLIDER_W + 16, 24),
	BackgroundTransparency = 1,
	AutoButtonColor = false,
	Text = "",
})

local sliderGroup = new("Frame", {
	Position = UDim2.fromOffset(SLIDER_X, SPEED_Y),
	Size = UDim2.fromOffset(SLIDER_W + 60, 24),
	BackgroundTransparency = 1,
	Visible = false, -- appears when the boon is written
	Parent = card,
}, { speedTrack, speedHit, speedBox })

local function setSpeedVisual(v)
	local f = speedToFraction(v)
	speedFill.Size = UDim2.fromScale(f, 1)
	speedHandle.Position = UDim2.new(f, 0, 0.5, 0)
	if not speedBox:IsFocused() then
		speedBox.Text = tostring(v)
	end
end
setSpeedVisual(CONFIG.SpeedValue)

local function setSpeedFromInput(input)
	local rel = (input.Position.X - speedTrack.AbsolutePosition.X) / math.max(1, speedTrack.AbsoluteSize.X)
	local v = fractionToSpeed(math.clamp(rel, 0, 1))
	if v ~= CONFIG.SpeedValue then
		CONFIG.SpeedValue = v
		setSpeedVisual(v)
		refreshSpeed() -- live: the speed changes while you slide, if the deal is active
	end
end

speedHit.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	tween(handleScale, TweenInfo.new(0.1), { Scale = 1.3 })
	setSpeedFromInput(input)

	local moveConn, endConn
	moveConn = UserInputService.InputChanged:Connect(function(changed)
		if changed.UserInputType == Enum.UserInputType.MouseMovement or changed == input then
			setSpeedFromInput(changed)
		end
	end)
	endConn = input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End then
			moveConn:Disconnect()
			endConn:Disconnect()
			tween(handleScale, TweenInfo.new(0.1), { Scale = 1 })
		end
	end)
end)

-- Typing the number: digits only, at most four of them
speedBox:GetPropertyChangedSignal("Text"):Connect(function()
	local cleaned = speedBox.Text:gsub("%D", "")
	if #cleaned > 4 then
		cleaned = cleaned:sub(1, 4)
	end
	if cleaned ~= speedBox.Text then
		speedBox.Text = cleaned
	end
end)
speedBox.Focused:Connect(function()
	liftForKeyboard(CARD_Y + SPEED_Y + 12)
end)
speedBox.FocusLost:Connect(function()
	dropKeyboardLift()
	local n = tonumber(speedBox.Text)
	if n then
		CONFIG.SpeedValue = math.clamp(math.floor(n), 1, 1000)
		refreshSpeed()
	end
	setSpeedVisual(CONFIG.SpeedValue)
	speedBox.Text = tostring(CONFIG.SpeedValue)
end)

-- The speed row joins the others, so it is written, ticked and reset like them
boonRows[#boonRows + 1] = {
	row = speedToggle,
	checkStroke = speedCheckStroke,
	markScale = speedMarkScale,
	label = speedLabel,
	key = "Swiftness",
	extra = sliderGroup,
}

local function setBoonMark(r, checked, animate)
	if animate then
		tween(r.markScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = checked and 1 or 0 })
	else
		r.markScale.Scale = checked and 1 or 0
	end
end

for _, r in ipairs(boonRows) do
	r.row.Activated:Connect(function()
		local value = not CONFIG[r.key]
		CONFIG[r.key] = value
		setBoonMark(r, value, true)
		if r.key == "InfiniteJump" or r.key == "Swiftness" or r.key == "Noclip" then
			applyPowers() -- live: takes effect at once if the deal is already active
		elseif r.key ~= "LockButton" then
			applyFeatures() -- live: the ESP updates at once if it is already on
		end
	end)
end

local function resetBoons()
	boonHeader.Text = ""
	boonHeader.MaxVisibleGraphemes = 0
	for _, r in ipairs(boonRows) do
		r.label.MaxVisibleGraphemes = 0
		r.label.TextTransparency = 0.1
		r.checkStroke.Transparency = 1
		r.markScale.Scale = 0
		if r.extra then
			r.extra.Visible = false
		end
	end
end

----------------------------------------------------------------------
-- Signature: type YES or NO on the line
----------------------------------------------------------------------
new("TextLabel", {
	Position = UDim2.fromOffset(88, SIG_Y - 20),
	Size = UDim2.fromOffset(22, 28),
	BackgroundTransparency = 1,
	Text = "X",
	Font = Enum.Font.Creepster,
	TextSize = 26,
	TextColor3 = BLOOD.Red,
	Parent = card,
})
new("Frame", {
	Position = UDim2.fromOffset(FIELD_X, SIG_Y + 8),
	Size = UDim2.fromOffset(270, 1),
	BackgroundColor3 = BLOOD.Bone,
	BackgroundTransparency = 0.55,
	BorderSizePixel = 0,
	Parent = card,
})
new("TextLabel", {
	Position = UDim2.fromOffset(FIELD_X, SIG_Y + 11),
	Size = UDim2.fromOffset(270, 14),
	BackgroundTransparency = 1,
	Text = "SIGN IN BLOOD  -  TYPE YES OR NO",
	Font = Enum.Font.Antique,
	TextSize = 11,
	TextColor3 = BLOOD.Bone,
	TextTransparency = 0.5,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = card,
})

local signField = new("TextBox", {
	Name = "Signature",
	Position = UDim2.fromOffset(FIELD_X, FIELD_Y),
	Size = UDim2.fromOffset(270, 30),
	BackgroundTransparency = 1,
	ClearTextOnFocus = false,
	MultiLine = false,
	Text = "",
	PlaceholderText = "type  YES  or  NO",
	PlaceholderColor3 = Color3.fromRGB(130, 80, 78),
	Font = Enum.Font.Creepster,
	TextSize = 26,
	TextColor3 = BLOOD.Bright,
	TextXAlignment = Enum.TextXAlignment.Left,
	Visible = false, -- appears once the contract has been written
	Parent = card,
})

-- The signature scribbled in blood when you sign
local sigInk = new("Frame", {
	Position = UDim2.fromOffset(FIELD_X, SIG_Y + 7),
	Size = UDim2.fromOffset(0, 3),
	BackgroundColor3 = BLOOD.Bright,
	BorderSizePixel = 0,
	Parent = card,
}, { round() })

local scribbles = {}
for i = 1, 8 do
	local up = i % 2 == 0
	scribbles[i] = {
		w = math.random(22, 38),
		frame = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(122 + (i - 1) * 30, SIG_Y - 4 + (up and -7 or 5) + math.random(-2, 2)),
			Size = UDim2.fromOffset(0, 2),
			Rotation = (up and -1 or 1) * math.random(18, 38),
			BackgroundColor3 = BLOOD.Bright,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = card,
		}, { round() }),
	}
end

-- Wax seal
local sealScale = new("UIScale", { Scale = 1 })
new("Frame", {
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
	box.Position = UDim2.new(0.5, math.random(-power, power), 0.5, -boxShiftY + math.random(-power, power))
	tween(box, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = basePos() })
end

local function setSigned(signed)
	sigInk.Size = UDim2.fromOffset(signed and 260 or 0, 3)
	for _, sc in ipairs(scribbles) do
		sc.frame.BackgroundTransparency = signed and 0.05 or 1
		sc.frame.Size = UDim2.fromOffset(signed and sc.w or 0, 2)
	end
	sealCrack.Size = UDim2.fromOffset(0, 2)
	for _, bar in ipairs(voidBars) do
		bar.BackgroundTransparency = 1
		bar.Size = UDim2.fromOffset(0, 7)
	end
end

-- Signing: the signature is scribbled in blood, then the seal is pressed
local function signContract()
	tween(sigInk, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(260, 3) })
	for i, sc in ipairs(scribbles) do
		task.delay((i - 1) * 0.045, function()
			sc.frame.BackgroundTransparency = 0.05
			sc.frame.Size = UDim2.fromOffset(0, 2)
			tween(sc.frame, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(sc.w, 2) })
		end)
	end
	task.delay(0.42, function()
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

----------------------------------------------------------------------
-- The demon's cage: heavy blood-soaked chains hanging down both sides
----------------------------------------------------------------------
local rage = 0 -- while > 0 the demon thrashes violently
local signReady = false -- true while the signature line is waiting for YES / NO

local chainLinks = {}
local chainDrips = {}
local chainHolders = {}
local chainRows = math.floor((CARD_H - 28) / 16)

for side = 1, 2 do
	local x = side == 1 and 14 or CARD_W - 14
	local holder = new("Frame", {
		Name = "Chain" .. side,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = card,
	})
	chainHolders[side] = holder

	-- iron bolt the chain hangs from, and the pool of blood it drips into
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, 8),
		Size = UDim2.fromOffset(13, 13),
		BackgroundColor3 = Color3.fromRGB(86, 86, 94),
		BorderSizePixel = 0,
		Parent = card,
	}, { round(), stroke(Color3.fromRGB(36, 36, 42), 2, 0) })
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, CARD_H - 12),
		Size = UDim2.fromOffset(34, 9),
		BackgroundColor3 = BLOOD.Crimson,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Parent = card,
	}, { round() })

	for i = 0, chainRows - 1 do
		local y = 16 + i * 16
		-- some links are coated in blood, some are rusty, some are bare iron
		local coated = math.random() < 0.5
		local rusty = (not coated) and math.random() < 0.35
		local dark = coated and Color3.fromRGB(70, 8, 12) or (rusty and Color3.fromRGB(70, 38, 28) or Color3.fromRGB(44, 44, 50))
		local light = coated and Color3.fromRGB(176, 26, 36) or (rusty and Color3.fromRGB(150, 84, 56) or Color3.fromRGB(170, 170, 178))
		local record = { x = x, y = y, strokes = {}, fills = {} }

		if i % 2 == 0 then
			-- face-on link: a thick dark ring with a thin bright highlight on its edge
			local outer = stroke(dark, 3, 0)
			local inner = stroke(light, 1, 0.1)
			local main = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(12, 18),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Parent = holder,
			}, {
				round(),
				outer,
				new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, -1, 0.5, -1),
					Size = UDim2.new(1, -5, 1, -5),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, { round(), inner }),
			})
			record.frame = main
			record.strokes = { { stroke = outer, base = 0 }, { stroke = inner, base = 0.1 } }
		else
			-- edge-on link: a metal bar, shaded dark - bright - dark across its width
			local main = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(6, 14),
				BackgroundColor3 = THEME.White, -- tinted by the gradient
				BorderSizePixel = 0,
				Parent = holder,
			}, { round(), new("UIGradient", { Color = colorSeq(dark, light, dark), Rotation = 0 }) })
			record.frame = main
			record.fills = { { frame = main, base = 0 } }
		end

		if coated then
			-- wet glisten on the blood
			local sheen = new("Frame", {
				Position = UDim2.fromOffset(2, 2),
				Size = UDim2.fromOffset(2, 5),
				BackgroundColor3 = Color3.fromRGB(255, 150, 150),
				BackgroundTransparency = 0.3,
				BorderSizePixel = 0,
				Parent = record.frame,
			}, { round() })
			record.fills[#record.fills + 1] = { frame = sheen, base = 0.3 }
		end
		chainLinks[#chainLinks + 1] = record

		-- blood running down the chain from some of the links
		if coated and math.random() < 0.35 then
			chainDrips[#chainDrips + 1] = new("Frame", {
				Position = UDim2.fromOffset(x + math.random(-3, 3), y + 8),
				Size = UDim2.fromOffset(2, 3),
				BackgroundColor3 = BLOOD.Red,
				BorderSizePixel = 0,
				Parent = holder,
			}, { round() })
		end
	end
end

local function setLinkAlpha(l, visible)
	for _, st in ipairs(l.strokes) do
		st.stroke.Transparency = visible and st.base or 1
	end
	for _, f in ipairs(l.fills) do
		f.frame.BackgroundTransparency = visible and f.base or 1
	end
end

local function setChainsVisible(visible)
	for _, l in ipairs(chainLinks) do
		l.frame.Position = UDim2.fromOffset(l.x, l.y)
		l.frame.Rotation = 0
		setLinkAlpha(l, visible)
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
		tween(l.frame, info, {
			Position = UDim2.fromOffset(l.x + dir * math.random(10, 40), l.y + math.random(30, 90)),
			Rotation = math.random(-160, 160),
		})
		for _, st in ipairs(l.strokes) do
			tween(st.stroke, info, { Transparency = 1 })
		end
		for _, f in ipairs(l.fills) do
			tween(f.frame, info, { BackgroundTransparency = 1 })
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
			tween(l.frame, info, { Position = UDim2.fromOffset(l.x, l.y), Rotation = 0 })
			for _, st in ipairs(l.strokes) do
				tween(st.stroke, info, { Transparency = st.base })
			end
			for _, f in ipairs(l.fills) do
				tween(f.frame, info, { BackgroundTransparency = f.base })
			end
		end)
	end
end

-- The chains sway slowly and blood drips from them while the contract is open
local chainLife = {}
local function stopChainLife()
	for _, tw in ipairs(chainLife) do
		tw:Cancel()
	end
	chainLife = {}
	for _, holder in ipairs(chainHolders) do
		holder.Position = UDim2.fromOffset(0, 0)
	end
	for _, drip in ipairs(chainDrips) do
		drip.Size = UDim2.fromOffset(2, 3)
		drip.BackgroundTransparency = 1
	end
end

local function startChainLife()
	stopChainLife()
	for side, holder in ipairs(chainHolders) do
		chainLife[#chainLife + 1] = tween(
			holder,
			TweenInfo.new(1.8 + side * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Position = UDim2.fromOffset(side == 1 and 2 or -2, 0) }
		)
	end
	for _, drip in ipairs(chainDrips) do
		task.delay(math.random() * 1.5, function()
			if drip.Parent then
				drip.BackgroundTransparency = 0.1
				chainLife[#chainLife + 1] = tween(
					drip,
					TweenInfo.new(1.3 + math.random() * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In, -1),
					{ Size = UDim2.fromOffset(2, 22), BackgroundTransparency = 1 }
				)
			end
		end)
	end
end

----------------------------------------------------------------------
-- Claw marks, glowing eyes
----------------------------------------------------------------------
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

-- Blood drips hanging from the top edge of the paper
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
-- The scroll: two wooden rods; the paper rolls up and unrolls between them
----------------------------------------------------------------------
local function makeRod(y)
	local function knob(x)
		return new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Size = UDim2.fromOffset(22, 22),
			BackgroundColor3 = Color3.fromRGB(150, 110, 60),
			BorderSizePixel = 0,
		}, { round(), stroke(Color3.fromRGB(50, 30, 14), 2, 0) })
	end
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(BOX_W / 2, y),
		Size = UDim2.fromOffset(BOX_W - 28, ROD_BASE),
		BackgroundColor3 = THEME.White, -- tinted by the gradient below
		BorderSizePixel = 0,
		Parent = box,
	}, {
		corner(9),
		stroke(Color3.fromRGB(30, 16, 8), 1.5, 0),
		new("UIGradient", {
			Color = colorSeq(Color3.fromRGB(70, 42, 26), Color3.fromRGB(176, 124, 76), Color3.fromRGB(58, 34, 20)),
			Rotation = 90,
		}),
		knob(-4),
		knob(BOX_W - 24),
	})
end

local rodTop = makeRod(CARD_Y)
local rodBottom = makeRod(CARD_Y + CARD_H)

-- Instantly show the scroll at a given openness (0 = rolled up, 1 = fully open)
local function setScroll(fraction)
	local h = math.max(6, math.floor(CARD_H * fraction))
	card.Size = UDim2.fromOffset(CARD_W, h)
	rodBottom.Position = UDim2.fromOffset(BOX_W / 2, CARD_Y + h)
	rodBottom.Size = UDim2.fromOffset(BOX_W - 28, ROD_BASE + math.floor((1 - fraction) * 12))
end

-- Roll the scroll up / unroll it. The bottom rod carries the paper with it.
local function animateScroll(fraction, seconds, style, direction)
	local h = math.max(6, math.floor(CARD_H * fraction))
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Sine, direction or Enum.EasingDirection.InOut)
	tween(card, info, { Size = UDim2.fromOffset(CARD_W, h) })
	tween(rodBottom, info, {
		Position = UDim2.fromOffset(BOX_W / 2, CARD_Y + h),
		Size = UDim2.fromOffset(BOX_W - 28, ROD_BASE + math.floor((1 - fraction) * 12)),
	})
end

----------------------------------------------------------------------
-- Contract logic: state, decode effect, glitch loop, open / sign / close
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

-- Text that writes itself, a few letters at a time
local function typeInto(label, token, step, delay)
	local n = #label.Text
	local shown = 0
	while shown < n do
		if token ~= pactToken then
			return false
		end
		shown = math.min(n, shown + step)
		label.MaxVisibleGraphemes = shown
		task.wait(delay)
	end
	label.MaxVisibleGraphemes = -1
	return true
end

-- The header and the six boons write themselves onto the contract
local function revealBoons(token, breaking)
	boonHeader.Text = breaking and "THE TERMS OF OUR DEAL:" or "I ASK OF FENRIR:"
	boonHeader.MaxVisibleGraphemes = 0
	if not typeInto(boonHeader, token, 3, 0.02) then
		return false
	end
	for _, r in ipairs(boonRows) do
		if token ~= pactToken then
			return false
		end
		tween(r.checkStroke, TweenInfo.new(0.15), { Transparency = 0.2 })
		if not typeInto(r.label, token, 3, 0.02) then
			return false
		end
		setBoonMark(r, CONFIG[r.key], true)
		if r.extra then
			setSpeedVisual(CONFIG.SpeedValue)
			r.extra.Visible = true
		end
	end
	return true
end

local function calmGlitch()
	ghostA.Position = UDim2.fromOffset(0, 0)
	ghostB.Position = UDim2.fromOffset(0, 0)
	titleHolder.Position = UDim2.fromOffset(0, TITLE_Y)
	titleMain.Rotation = 0
	box.Position = basePos()
	resetChains()
	if subText ~= "" then
		subLabel.Text = subText
	end
	for _, r in ipairs(boonRows) do
		r.label.TextTransparency = 0.1
	end
	signField.Position = UDim2.fromOffset(FIELD_X, FIELD_Y)
end

-- Runs only while the contract is open. Nothing is on a fixed rhythm: it trembles, then
-- suddenly thrashes, flashes whispers, opens its eyes, and twitches the signature line.
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
				box.Position = UDim2.new(0.5, math.random(-power, power) * 2, 0.5, -boxShiftY + math.random(-power, power))
				rattleChains(math.min(power, 5))
				boxStroke.Transparency = math.random() < 0.4 and 0.7 or 0
				boonRows[math.random(#boonRows)].label.TextTransparency = 0.65

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
				titleHolder.Position = UDim2.fromOffset(math.random(-1, 1), TITLE_Y + math.random(-1, 1))
				if math.random() < 0.03 * glitchIntensity then
					burst = math.random(2, 4)
				end
				if math.random() < 0.012 then
					eyes()
				end

				-- cunning: the signature line twitches like bait
				if signReady and not signField:IsFocused() then
					if math.random() < 0.08 then
						signField.Position = UDim2.fromOffset(FIELD_X + math.random(-3, 3), FIELD_Y + math.random(-2, 2))
					else
						signField.Position = UDim2.fromOffset(FIELD_X, FIELD_Y)
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
				playSound(CONFIG.Sounds.Heartbeat, 0.6)
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

-- Reads what was typed on the signature line: YES / NO in any capitalization
local function readAnswer(text)
	text = string.lower(text or "")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "yes" then
		return "yes"
	elseif text == "no" then
		return "no"
	end
	return nil
end

-- Quick close: the paper rolls itself up like a scroll, then everything fades
local function closePact()
	if not pactOpen then
		return
	end
	pactOpen = false
	pactToken += 1
	signReady = false
	rage = 0
	fadeOutOptionsSound(0.9)
	stopChainLife()
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	if signField:IsFocused() then
		signField:ReleaseFocus()
	end
	boxShiftY = 0
	tween(box, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = basePos() })

	animateScroll(0, 0.42, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	tween(overlay, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = 1 })
	task.delay(0.36, function()
		if pactOpen then
			return
		end
		tween(box, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { GroupTransparency = 1 })
		tween(boxScale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = fitScale() * 0.9 })
	end)
	task.delay(0.6, function()
		if not pactOpen then
			overlay.Visible = false
		end
	end)
end

-- The signature line appears: this is where YES or NO is typed
local function showSignField()
	signReady = true
	playOptionsSound() -- starts the instant the signature line appears
	signField.Visible = true
	signField.TextEditable = true
	signField.TextTransparency = 0
	if UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		signField:CaptureFocus()
	end
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
	signReady = false
	rage = 0
	pactToken += 1
	local token = pactToken
	local fit = fitScale()
	local breaking = pactDisabling

	setTitle("")
	setSub("")
	resetBoons()
	for _, r in ipairs(boonRows) do
		-- the boons always show the real settings
		r.markScale.Scale = 0
	end
	signField.Text = ""
	signField.Visible = false
	signField.TextEditable = true
	signField.TextTransparency = 0
	signField.PlaceholderText = "type  YES  or  NO"
	signField.PlaceholderColor3 = Color3.fromRGB(130, 80, 78)
	titleMain.TextTransparency = 1
	titleMain.TextColor3 = Color3.fromRGB(225, 22, 34)
	boxStroke.Color = BLOOD.Red
	boxStroke.Transparency = 0
	setChainsVisible(not breaking) -- demon still chained (first time) or already free (ESP on)
	setSigned(breaking) -- already signed in blood when the deal exists
	buildDrips(0)
	boxShiftY = 0
	calmGlitch()

	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.Visible = true
	box.GroupTransparency = 1
	boxScale.Scale = fit * 0.92
	setScroll(0)
	tween(overlay, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { BackgroundTransparency = 0.38 })
	tween(box, TweenInfo.new(0.18, Enum.EasingStyle.Sine), { GroupTransparency = 0 })
	tween(boxScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = fit })
	animateScroll(1, 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- the scroll unrolls

	-- The border slowly pulses, like something breathing
	if pulseTween then
		pulseTween:Cancel()
	end
	boxStroke.Thickness = 2
	pulseTween = tween(boxStroke, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Thickness = 3.5,
	})

	startChainLife()
	startGlitchLoop(token)
	startHeartbeat(token)

	local boonsDone = false
	task.spawn(function()
		task.wait(0.4)
		if token ~= pactToken then
			return
		end
		boonsDone = revealBoons(token, breaking)
	end)

	task.spawn(function()
		task.wait(0.15)
		if token ~= pactToken then
			return
		end
		if not decodeTitle(breaking and "BREAK THE DEAL WITH FENRIR" or "MAKE A DEAL WITH FENRIR", token, 0.04) then
			return
		end
		setSub(breaking and "A BROKEN DEAL IS PAID IN BLOOD" or "SEALED FOR A THOUSAND YEARS")
		-- wait until the boons have finished writing themselves
		local waited = 0
		while token == pactToken and not boonsDone and waited < 3 do
			task.wait(0.05)
			waited += 0.05
		end
		if token ~= pactToken then
			return
		end
		eyes()
		showSignField()
	end)
end

-- YES was signed
local function acceptPact()
	if not pactOpen or accepted then
		return
	end
	accepted = true
	signReady = false
	signField.TextEditable = false
	tween(signField, TweenInfo.new(0.35), { TextTransparency = 1 }) -- the typed word dissolves into the signature
	local token = pactToken
	local breaking = pactDisabling

	fadeOutOptionsSound(0.9) -- the options sound fades away
	subText = ""
	tween(subLabel, TweenInfo.new(0.3), { TextTransparency = 1 })

	if breaking then
		-- Second time around: the deal is torn up, the chains slam back, ESP turns off at once
		playSound(CONFIG.Sounds.Revoke)
		setEnabled(false)
		restoreChains()
		voidContract()
		glitchIntensity = 4
	else
		-- First time: signed in blood, the chains shatter, the chosen boons turn on immediately
		playSound(CONFIG.Sounds.Accept)
		setEnabled(true)
		signContract()
		task.delay(0.3, function()
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

-- Something other than YES / NO was typed
local function rejectAnswer()
	signField.Text = ""
	signField.PlaceholderText = "ONLY  YES  OR  NO"
	signField.PlaceholderColor3 = BLOOD.Bright
	rage = 6
	slash()
	task.delay(1.4, function()
		signField.PlaceholderText = "type  YES  or  NO"
		signField.PlaceholderColor3 = Color3.fromRGB(130, 80, 78)
	end)
end

-- On a phone the keyboard covers the lower half of the screen: lift the contract so the line stays visible
signField.Focused:Connect(function()
	liftForKeyboard(CARD_Y + FIELD_Y + 15)
end)

signField.FocusLost:Connect(function()
	dropKeyboardLift()
	if not pactOpen or accepted or not signReady then
		return
	end
	local answer = readAnswer(signField.Text)
	if answer == "yes" then
		acceptPact()
	elseif answer == "no" then
		closePact()
	elseif signField.Text ~= "" then
		rejectAnswer()
	end
end)

local function isPressInput(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- Tap the dark area outside the contract to roll it up quickly
overlay.InputBegan:Connect(function(input)
	if pactOpen and isPressInput(input) and not signField:IsFocused() then
		closePact()
	end
end)

-- After signing, tap the contract to skip the speech
box.InputBegan:Connect(function(input)
	if pactOpen and accepted and isPressInput(input) then
		closePact()
	end
end)

----------------------------------------------------------------------
-- UI: tome look + dragging (mouse + touch)
----------------------------------------------------------------------
-- The tome glows brighter while the deal is active
function updateButtonVisual()
	local on = CONFIG.Enabled
	tween(coverStroke, TI_FAST, {
		Color = on and BLOOD.Bright or BLOOD.Crimson,
		Thickness = on and 2 or 1.5,
		Transparency = on and 0 or 0.15,
	})
	tween(emblem, TI_FAST, { BackgroundColor3 = on and BLOOD.Bright or BLOOD.Crimson })

	-- Picture version: swap to the "active" picture (if given) and glow red while the deal is active
	if bookImage then
		local activeId = CONFIG.BookImageActive ~= "" and CONFIG.BookImageActive or CONFIG.BookImage
		bookImage.Image = "rbxassetid://" .. (on and activeId or CONFIG.BookImage)
		tween(bookImage, TI_FAST, { ImageColor3 = on and Color3.fromRGB(255, 225, 225) or Color3.new(1, 1, 1) })
		if glowPulse then
			glowPulse:Cancel()
			glowPulse = nil
		end
		if on then
			bookGlow.BackgroundTransparency = 0.78
			glowPulse = tween(bookGlow, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
				BackgroundTransparency = 0.92,
			})
		else
			tween(bookGlow, TI_FAST, { BackgroundTransparency = 1 })
		end
	end
end

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

-- Each draggable button has its own anchor and lock setting
local mainTarget = {
	anchor = anchor,
	locked = function()
		return CONFIG.LockButton
	end,
}
local ghostTarget = {
	anchor = ghostAnchor,
	locked = function()
		return false
	end,
}

local function beginDrag(input, target, onTap)
	if not isPressInput(input) then
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
				return -- bound in place: the tome stays where it is
			end
			local pos = clampToScreen(dragOrigin + Vector2.new(delta.X, delta.Y))
			target.anchor.Position = UDim2.fromOffset(pos.X, pos.Y)
		end
	end)
end

-- Tap the tome = open the contract
button.InputBegan:Connect(function(input)
	if isPressInput(input) then
		tween(btnScale, TI_FAST, { Scale = 0.92 })
	end
	beginDrag(input, mainTarget, openPact)
end)
button.InputEnded:Connect(function(input)
	if isPressInput(input) then
		tween(btnScale, TI_FAST, { Scale = 1 })
	end
end)

-- Ghosting button: tap = noclip on / off, drag = move it
ghostButton.InputBegan:Connect(function(input)
	if isPressInput(input) then
		tween(ghostScale, TI_FAST, { Scale = 0.9 })
	end
	beginDrag(input, ghostTarget, function()
		ghostOn = not ghostOn
		applyPowers()
	end)
end)
ghostButton.InputEnded:Connect(function(input)
	if isPressInput(input) then
		tween(ghostScale, TI_FAST, { Scale = 1 })
	end
end)

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local current = Vector2.new(ghostAnchor.Position.X.Offset, ghostAnchor.Position.Y.Offset)
	local pos = clampToScreen(current)
	if pos ~= current then
		tween(ghostAnchor, TI_MED, { Position = UDim2.fromOffset(pos.X, pos.Y) })
	end
end)

-- Keep the tome on screen (and the contract the right size) if the screen changes
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local current = Vector2.new(anchor.Position.X.Offset, anchor.Position.Y.Offset)
	local pos = clampToScreen(current)
	if pos ~= current then
		tween(anchor, TI_MED, { Position = UDim2.fromOffset(pos.X, pos.Y) })
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
	emblemPulse:Cancel()
	if glowPulse then
		glowPulse:Cancel()
	end
	stopChainLife()
	setInfiniteJump(false)
	stopSpeed()
	stopNoclip()
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
tween(btnScale, TI_POP, { Scale = 1 })
-- Watchdog: games hide every GUI during cutscenes. Switch it back on at once, every frame if needed.
local function keepVisible()
	if running and not gui.Enabled then
		gui.Enabled = true
	end
end
gui:GetPropertyChangedSignal("Enabled"):Connect(keepVisible)
globalConns[#globalConns + 1] = RunService.RenderStepped:Connect(keepVisible)

-- Once a second: put it back if it was moved, and keep it on top of every other UI
task.spawn(function()
	while running do
		task.wait(1)
		if gui.Parent ~= guiParent then
			pcall(function()
				gui.Parent = guiParent
			end)
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
