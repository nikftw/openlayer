local ADDON = ...
local PREFIX, LT_PREFIX, CHANNEL = "OpenLayer", "LYRTRK1", "layer"
local HOST_TTL, FRESH, DROP, PRESENCE, REQUEST = 120, 600, 3600, 60, 90
local FONT, BOX, GAP, GRID = "Fonts\\ARIALN.ttf", 26, 3, 5
local issecretvalue = issecretvalue

local function isSecret(v)
	return issecretvalue and issecretvalue(v) and true or false
end

local function say(text)
	print("|cffffcc00OpenLayer|r " .. text)
end

local function bare(name)
	if isSecret(name) or type(name) ~= "string" or name == "" then return end
	return (strsplit("-", name))
end

local function myName()
	local first, sur = UnitName("player")
	if isSecret(first) or type(first) ~= "string" or first == "" then return end
	if not isSecret(sur) and type(sur) == "string" and sur ~= "" and not string.find(first, sur, 1, true) then
		return first .. " " .. sur
	end
	return first
end

local function mapHere()
	local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if isSecret(id) or type(id) ~= "number" or id <= 0 then return end
	return id
end

local function clock(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local db, current, vote, request, lastHost, evictAt, fromNum, pendingLand, toldBlock, shardText, noteUntil
local square, menu, note, tip, paintMenu
local layers, used, buttons, lastPresence = {}, {}, {}, 0

local function zoneList(map)
	local ids, zs, now = {}, layers[map], GetServerTime()
	if not zs then return ids end
	for zone, row in pairs(zs) do
		if now - (row.seen or 0) <= DROP then ids[#ids + 1] = zone end
	end
	table.sort(ids)
	return ids
end

local function layerNum(map, zone)
	for i, id in ipairs(zoneList(map)) do
		if id == zone then return i end
	end
end

local function rowFor(map, zone, server)
	map, zone = tonumber(map), tonumber(zone)
	if not map or not zone or zone <= 0 then return end
	layers[map] = layers[map] or {}
	local row = layers[map][zone]
	if not row then
		row = { seen = 0, who = {}, color = { math.random(), math.random(), math.random() } }
		layers[map][zone] = row
	end
	if type(server) == "string" and server ~= "" and server ~= "0" then row.server = server end
	return row
end

local function expire()
	local now = GetServerTime()
	for map, zs in pairs(layers) do
		for zone, row in pairs(zs) do
			if now - (row.seen or 0) > DROP then zs[zone] = nil end
		end
		if not next(zs) then layers[map] = nil end
	end
end

local function refresh()
	if not square then return end
	square.text:SetText(current and tostring(layerNum(current.map, current.zone) or "") or "")
	if menu and menu:IsShown() then paintMenu() end
end

local function note(map, zone, server, time, name, host)
	local row = rowFor(map, zone, server)
	if not row or not time then return end
	if name then
		name = bare(name)
		if not name then return end
		if time > GetServerTime() + 30 then time = GetServerTime() end
		local prev = row.who[name]
		if prev and time <= prev.t then return end
		row.who[name] = { t = time, host = host and true or false }
	end
	if time <= (row.seen or 0) then
		if name then refresh() end
		return
	end
	row.seen = time
	refresh()
end

local function sayNote(text)
	say(text)
	if not note then return end
	note:SetText(text)
	noteUntil = GetTime() + 20
end

local function sendAddon(msg)
	local fn = C_ChatInfo and C_ChatInfo.SendAddonMessage
	if not fn then return end
	local id = GetChannelName(CHANNEL)
	if id and id ~= 0 then pcall(fn, PREFIX, msg, "CHANNEL", id) end
	if IsInGuild() then pcall(fn, PREFIX, msg, "GUILD") end
end

local function publish(force)
	if not current then return end
	local now = GetServerTime()
	if not force and now - lastPresence < PRESENCE then return end
	lastPresence = now
	note(current.map, current.zone, current.server, now, myName(), db.hosting)
	sendAddon(string.format("P:%d:%d:%s:%d:%d", current.map, current.zone, current.server or "0", db.hosting and 1 or 0, now))
end

local function toggleHost()
	db.hosting = not db.hosting
	publish(true)
	say(db.hosting and "Hosting on." or "Hosting off.")
end

local function setCurrent(map, zone, server)
	local prev = current
	current = { map = map, zone = zone, server = server or "0" }
	vote = nil
	if not prev or prev.zone ~= zone or prev.server ~= current.server or prev.map ~= map then publish(true) end
	if pendingLand and GetTime() - pendingLand.at < 120 then
		local n = layerNum(map, zone)
		local text = "Layer " .. (pendingLand.from or "?") .. " -> " .. (n or "?")
		if pendingLand.wantZone and pendingLand.wantZone ~= zone then text = text .. " (asked for " .. (pendingLand.wantNum or "?") .. ")" end
		pendingLand, request = nil, nil
		sayNote(text)
	end
	refresh()
end

local function here(zone, server)
	return current and current.zone == zone and (not server or server == current.server)
end

local function readUnit(unit)
	if not UnitExists(unit) or (UnitPlayerControlled and UnitPlayerControlled(unit)) then return end
	local guid = UnitGUID(unit)
	if isSecret(guid) or type(guid) ~= "string" then return end
	local kind, _, server, _, zoneUID = strsplit("-", guid)
	zoneUID = tonumber(zoneUID)
	if (kind ~= "Creature" and kind ~= "Vehicle") or not server or server == "" or not zoneUID or zoneUID == 0 then return end
	return server, zoneUID, guid
end

local function observe(unit)
	if IsInInstance() or (UnitOnTaxi and UnitOnTaxi("player")) then return end
	local server, zone, guid = readUnit(unit)
	local map = server and mapHere()
	if not map then return end
	note(map, zone, server, GetServerTime())
	local id = server .. "-" .. zone
	if current and current.map == map and current.zone == zone and current.server == server then return publish(false) end
	if not vote or vote.id ~= id then vote = { id = id, guid = guid }; return end
	if vote.guid ~= guid then setCurrent(map, zone, server) end
end

local function scanPlates()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	local ok, plates = pcall(C_NamePlate.GetNamePlates)
	if not ok or type(plates) ~= "table" then return end
	for _, plate in ipairs(plates) do
		local unit = plate.namePlateUnitToken or plate.unitToken
		if unit and not isSecret(unit) then observe(unit) end
	end
end

local function hostToken(kind, zone, server)
	local now, best, bestT, me = GetServerTime(), nil, nil, bare(myName())
	for _, zs in pairs(layers) do
		for z, row in pairs(zs) do
			local hit = (kind == "W" and z == zone and (server == "0" or not row.server or row.server == server))
				or (kind ~= "W" and not (current and z == current.zone and row.server == current.server))
			if hit then
				for name, rec in pairs(row.who) do
					if rec.host and now - rec.t < HOST_TTL and not used[name] and name ~= me and (not bestT or rec.t > bestT) then
						best, bestT = name, rec.t
					end
				end
			end
		end
	end
	if not best then return lastHost and "!" .. lastHost end
	used[best], lastHost = true, best
	return best
end

local function sendAsk(kind, zone, server, num)
	if IsInGroup() then return say("You are in a group.") end
	if not current then return say("Layer unknown. Target an NPC.") end
	local id = GetChannelName(CHANNEL)
	if not id or id == 0 then
		pcall(JoinChannelByName, CHANNEL)
		return say("Joined the layer channel. Try again.")
	end
	server = server or current.server or "0"
	local token = hostToken(kind, zone, server)
	sendAddon(string.format("%s:%d:%d:%s", kind, current.map, zone, server) .. (token and (":" .. token) or ""))
	request = { at = GetTime(), zone = zone, num = num, kind = kind }
	sayNote(num and ("Asked for layer " .. num) or "Asked for another layer")
end

local function onAsk(kind, zone, server, token, sender)
	if not db.hosting or IsInGroup() or IsInInstance() or not current then return end
	local me, them = bare(myName()), bare(sender)
	if not them or them == me then return end
	if type(token) == "string" and token ~= "" then
		local skip = string.sub(token, 1, 1) == "!"
		local who = bare(skip and string.sub(token, 2) or token)
		if (skip and who == me) or (not skip and who ~= me) then return end
	end
	zone = tonumber(zone)
	if kind == "W" then
		if current.zone ~= zone or (server ~= "0" and current.server ~= server) then return end
	elseif kind ~= "A" or (current.zone == zone and current.server == server) then
		return
	end
	local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	if fn then pcall(fn, sender) end
end

local function onSync(prefix, msg, sender)
	if isSecret(prefix) or isSecret(msg) or type(msg) ~= "string" then return end
	local kind, map, zone, server, extra, time = strsplit(":", msg)
	if prefix == LT_PREFIX then
		if kind == "S" then note(map, zone, nil, GetServerTime()) end
		return
	end
	if prefix ~= PREFIX or bare(sender) == bare(myName()) then return end
	if kind == "P" then note(map, zone, server, tonumber(time) or GetServerTime(), sender, extra == "1")
	elseif kind == "W" or kind == "A" then onAsk(kind, zone, server, extra, sender) end
end

local function hookShard()
	if shardText or not ShardTransferImminentFrame then return end
	shardText = ShardTransferImminentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	shardText:SetPoint("BOTTOM", ShardTransferImminentFrame, "BOTTOM", 0, 14)
end

local function showTip()
	if not current then return tip:Hide() end
	tip.a:SetText("L" .. (layerNum(current.map, current.zone) or "?") .. " " .. (GetRealZoneText() or ""))
	tip.b:SetText((current.server or "?") .. "-" .. current.zone)
	tip:SetSize(math.max(tip.a:GetStringWidth(), tip.b:GetStringWidth()) + 8, tip.a:GetStringHeight() + tip.b:GetStringHeight() + 6)
	tip:Show()
end

local function box(parent, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	local edge = b:CreateTexture(nil, "BACKGROUND")
	edge:SetAllPoints()
	edge:SetColorTexture(0.2, 0.2, 0.2, 1)
	b.fill = b:CreateTexture(nil, "BORDER")
	b.fill:SetPoint("TOPLEFT", 1, -1)
	b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
	return b
end

paintMenu = function()
	local rows, now = {}, GetServerTime()
	if current and layers[current.map] then
		for i, zone in ipairs(zoneList(current.map)) do
			rows[#rows + 1] = { zone = zone, num = i, row = layers[current.map][zone] }
		end
	end
	local n = math.min(#rows, GRID * GRID)
	for i = 1, n do
		local b = buttons[i]
		if not b then
			b = box(menu, BOX, BOX)
			local hl = b:CreateTexture(nil, "HIGHLIGHT")
			hl:SetPoint("TOPLEFT", 1, -1)
			hl:SetPoint("BOTTOMRIGHT", -1, 1)
			hl:SetColorTexture(1, 1, 1, 0.18)
			b.label = b:CreateFontString(nil, "OVERLAY")
			b.label:SetPoint("CENTER")
			b.label:SetFont(FONT, 14, "OUTLINE")
			b:SetScript("OnClick", function(self) if self.fn then self.fn() end end)
			buttons[i] = b
		end
		local item, c = rows[i], rows[i].row.color
		local col, row = math.floor((i - 1) / GRID), (i - 1) % GRID
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", col * (BOX + GAP), -row * (BOX + GAP))
		b.fill:SetColorTexture(c[1], c[2], c[3], 1)
		b.label:SetText(item.num)
		local stale = now - (item.row.seen or 0) > FRESH
		b.fn = (stale or here(item.zone, item.row.server)) and nil or function()
			menu:Hide()
			sendAsk("W", item.zone, item.row.server or "0", item.num)
		end
		b:Show()
	end
	for i = n + 1, #buttons do buttons[i]:Hide() end
	local cols = n > 0 and math.ceil(n / GRID) or 0
	local gridRows = n > 0 and math.min(GRID, n) or 0
	menu:SetSize(cols > 0 and cols * BOX + (cols - 1) * GAP or BOX, gridRows > 0 and gridRows * BOX + (gridRows - 1) * GAP or 0)
end

local function toggleMenu()
	if menu:IsShown() then menu:Hide() else paintMenu(); menu:Show() end
end

local function font(parent, size, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(FONT, size, x and "" or "OUTLINE")
	fs:SetPoint("CENTER", x or 0, y or 0)
	return fs
end

local function buildUI()
	square = box(UIParent, BOX, BOX)
	square:SetFrameStrata("MEDIUM")
	square:SetClampedToScreen(true)
	square:SetMovable(true)
	square:RegisterForDrag("LeftButton")
	square:RegisterForClicks("LeftButtonUp", "MiddleButtonUp")
	square.fill:SetTexture("Interface\\Icons\\INV_Misc_PunchCards_Prismatic")
	square.fill:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local shade = square:CreateTexture(nil, "ARTWORK")
	shade:SetPoint("TOPLEFT", 1, -1)
	shade:SetPoint("BOTTOMRIGHT", -1, 1)
	shade:SetColorTexture(0.25, 0.25, 0.25, 0.4)
	square.text = font(square, 14)
	note = square:CreateFontString(nil, "OVERLAY")
	note:SetFont(FONT, 12, "OUTLINE")
	note:SetPoint("TOP", square, "BOTTOM", 0, -4)
	local point = db.point
	if type(point) == "table" and type(point[1]) == "string" and type(point[3]) == "number" and type(point[4]) == "number" then
		square:SetPoint(point[1], UIParent, point[2] or point[1], point[3], point[4])
	else
		square:SetPoint("TOP", UIParent, "TOP", 0, -80)
	end
	square:SetScript("OnDragStart", function(self) self.moved = true; self:StartMoving() end)
	square:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rel, x, y = self:GetPoint()
		db.point = { p, rel, x, y }
	end)
	square:SetScript("OnClick", function(self, button)
		if self.moved then self.moved = nil; return end
		if button == "MiddleButton" then return toggleHost() end
		toggleMenu()
	end)
	square:SetScript("OnEnter", showTip)
	square:SetScript("OnLeave", function() tip:Hide() end)

	tip = CreateFrame("Frame", nil, UIParent)
	tip:SetFrameStrata("TOOLTIP")
	tip:SetPoint("BOTTOMLEFT", square, "TOPRIGHT", 2, 2)
	local bg = tip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.85)
	tip.a = tip:CreateFontString(nil, "ARTWORK")
	tip.b = tip:CreateFontString(nil, "ARTWORK")
	tip.a:SetFont(FONT, 12)
	tip.b:SetFont(FONT, 12)
	tip.a:SetPoint("TOPLEFT", 4, -3)
	tip.b:SetPoint("TOPLEFT", tip.a, "BOTTOMLEFT", 0, -1)
	tip:Hide()

	menu = CreateFrame("Frame", nil, UIParent)
	menu:SetFrameStrata("DIALOG")
	menu:SetClampedToScreen(true)
	menu:SetPoint("TOPLEFT", square, "TOPRIGHT", GAP, 0)
	menu:Hide()
	refresh()
end

local function tick()
	hookShard()
	expire()
	if evictAt then
		local left = evictAt - GetTime()
		if left > -30 then
			local n = fromNum or (current and layerNum(current.map, current.zone))
			if shardText then shardText:SetText((n and ("Leaving layer " .. n) or "Leaving layer") .. (left > 0 and ("  " .. clock(left)) or "")) end
		else
			evictAt = nil
			if shardText then shardText:SetText("") end
		end
	end
	if noteUntil and GetTime() > noteUntil then note:SetText(""); noteUntil = nil end
	if current then publish(false) end
	refresh()
	if tip and tip:IsShown() then showTip() end
end

local f = CreateFrame("Frame")
for _, ev in ipairs({
	"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
	"PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
	"CHAT_MSG_ADDON", "PARTY_INVITE_REQUEST", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
}) do f:RegisterEvent(ev) end
pcall(f.RegisterEvent, f, "SHARD_TRANSFER_IMMINENT")
pcall(f.RegisterEvent, f, "SHARD_TRANSFER")

f:SetScript("OnEvent", function(_, event, ...)
	local a1, a2 = ...
	if event == "ADDON_LOADED" then
		if a1 ~= ADDON then return end
		OpenLayerDB = OpenLayerDB or {}
		if OpenLayerDB.hosting == nil then OpenLayerDB.hosting = true end
		db = OpenLayerDB
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, LT_PREFIX)
		end
		return buildUI()
	end
	if event == "PLAYER_LOGIN" then return C_Timer.NewTicker(1, tick) end
	if not db then return end
	if event == "PLAYER_TARGET_CHANGED" then return observe("target") end
	if event == "UPDATE_MOUSEOVER_UNIT" then return observe("mouseover") end
	if event == "NAME_PLATE_UNIT_ADDED" then return not isSecret(a1) and observe(a1) end
	if event == "PLAYER_ENTERING_WORLD" then return C_Timer.After(1, scanPlates) end
	if event == "ZONE_CHANGED_NEW_AREA" or event == "SHARD_TRANSFER" then
		if event == "SHARD_TRANSFER" then
			local hop = request and (GetTime() - request.at) <= REQUEST and request.kind == "W" and request or nil
			pendingLand = {
				at = GetTime(),
				from = fromNum or (current and layerNum(current.map, current.zone)),
				wantZone = hop and hop.zone or nil,
				wantNum = hop and hop.num or nil,
			}
			evictAt, fromNum = nil, nil
			if shardText then shardText:SetText("") end
		end
		current, vote = nil, nil
		refresh()
		return C_Timer.After(1, scanPlates)
	end
	if event == "SHARD_TRANSFER_IMMINENT" then
		fromNum = current and layerNum(current.map, current.zone)
		local left = type(GetEvictionTimeRemaining) == "function" and GetEvictionTimeRemaining() or nil
		if not isSecret(left) and type(left) == "number" then evictAt = GetTime() + left end
		return tick()
	end
	if event == "CHAT_MSG_ADDON" then return onSync(a1, a2, select(4, ...)) end
	if event == "PARTY_INVITE_REQUEST" and request and GetTime() - request.at <= REQUEST and not isSecret(a1) then
		local who = bare(a1)
		if who then used[who], lastHost = true, who end
		pcall(AcceptGroup)
		return pcall(StaticPopup_Hide, "PARTY_INVITE")
	end
	if (event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN") and a1 == ADDON and not toldBlock then
		toldBlock = true
		say("The game blocked " .. tostring(a2))
	end
end)

SLASH_LAYERME1 = "/layerme"
SlashCmdList.LAYERME = function(msg)
	if not db then return end
	msg = strtrim(msg or "")
	if msg == "" then return sendAsk("A", current and current.zone, current and current.server) end
	local num = tonumber(msg)
	if not num or num < 1 or not current then return say(current and "Usage: /layerme [number]" or "Layer unknown. Target an NPC.") end
	num = math.floor(num)
	local zone = zoneList(current.map)[num]
	local row = zone and layers[current.map][zone]
	if not row then return say("No layer " .. num) end
	if here(zone, row.server) then return say("Already on layer " .. num) end
	sendAsk("W", zone, row.server or "0", num)
end
