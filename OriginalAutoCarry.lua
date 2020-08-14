require("common.log")
module("OriginalAutoCarry", package.seeall, log.setup)

local DMGLib = require("lol/Modules/Common/DamageLib")
local ts = require("lol/Modules/Common/simpleTS")

local _SDK = _G.CoreEx
local ObjManager, EventManager, Input, Enums, Game = _SDK.ObjectManager, _SDK.EventManager, _SDK.Input, _SDK.Enums, _SDK.Game
local SpellSlots, SpellStates = Enums.SpellSlots, Enums.SpellStates 
local Player = ObjManager.Player
local Vector = _SDK.Geometry.Vector
local Renderer = _SDK.Renderer


function BBDist(objA, objB)
	return objA.Position:Distance(objB.Position) - objA.BoundingRadius - objB.BoundingRadius
end

function InScreenBounds(v)
	return v.x > 0 and v.x < 1920 and v.y > 0 and v.y < 1080
end

function clamp(x, min, max)
	return math.min(x,math.max(x, min))
end

local OACEvent = {}
setmetatable(OACEvent, {
	__call = function()
		local self = {}
		setmetatable(self, {
			__index=OACEvent,
			__tostring = function(self) 
				return "OACEvent{ Active Hooks: " .. tostring(#self.Listeners) .. " , Total Hooks " .. tostring(self.UniqueCounter) .. "}"
			end
		}) --Check OACEvent for metamethods or backup __index

		self.Listeners = {}
		self.UniqueCounter = 1

		return self
	end
})

function OACEvent:Fire(...)
	local args = table.pack(...) --lua5.1 passing ... as argument passes it as a table, packing and passing unpack call will pass as separate args
	for HookId, Hook in pairs(self.Listeners) do
		Hook(unpack(args))
	end
end

function OACEvent:Hook(closure)
	self.Listeners[self.UniqueCounter] = closure
	self.UniqueCounter = self.UniqueCounter+1
	return self.UniqueCounter --numeric id no conflicts on remove add remove add multiple times
end

function OACEvent:UnHook(HookId)
	assert(self.Listeners[HookId], "Invalid HookId [" .. tostring(HookId) .. "]")
end

local Orbwalker = {}
Orbwalker.__index = Orbwalker
setmetatable(Orbwalker, Orbwalker)

local MissileManager = {}
function MissileManager:Init(ScanRange)
	self.ScanRange = ScanRange or 4000

	self.Missiles = {}
	self.MissilesKeyTarget = {}
	self.MissilesKeySource = {}
end

function MissileManager:ProcessObjectCreated(Obj)
	if Obj.AsMissile and BBDist(Obj,Player) < 8000 and Obj.AsMissile.Target.__obj ~= 0 and Obj.AsMissile.Source.__obj ~= 0 then

		Obj.SrcHandle = Obj.AsMissile.Source.__obj
		Obj.TargetHandle = Obj.AsMissile.Target.__obj

		if Obj.AsMissile.Source.Handle == Orbwalker.Player.Handle then
			Orbwalker._ProjectileSpeed = Obj.AsMissile.Speed
		end
			
		if Obj.SrcHandle and Obj.TargetHandle then

			MissileManager.Missiles[Obj.__obj] = Obj

			MissileManager.MissilesKeyTarget[Obj.TargetHandle] = MissileManager.MissilesKeyTarget[Obj.TargetHandle] or {}
			MissileManager.MissilesKeyTarget[Obj.TargetHandle][Obj.__obj] = Obj

			MissileManager.MissilesKeySource[Obj.SrcHandle] = MissileManager.MissilesKeySource[Obj.SrcHandle] or {}
			MissileManager.MissilesKeySource[Obj.SrcHandle][Obj.__obj] = Obj

		end
	end
end

function MissileManager:ProcessObjectDestroyed(Obj)
	pcall(function()
		if Obj.AsMissile then
			local TargetHandle = Obj.AsMissile.Target.__obj
			local SourceHandle = Obj.AsMissile.Source.__obj

			if MissileManager.Missiles[Obj.__obj] then
				
				MissileManager.Missiles[Obj.__obj] = nil
				MissileManager.MissilesKeyTarget[TargetHandle][Obj.__obj] = nil
				MissileManager.MissilesKeySource[SourceHandle][Obj.__obj] = nil
			end
		end

		MissileManager.MissilesKeyTarget[Obj.__obj] = nil
		MissileManager.MissilesKeySource[Obj.__obj] = nil
	end)
end

function MissileManager:CalcMissileDamage(Missile)
	return Missile.AsMissile.Source.IsAlive and DMGLib:CalcPhysicalDamage(Missile.AsMissile.Source, Missile.AsMissile.Target, clamp(Missile.AsMissile.Source.TotalAD,0, 2000)) or 0
	--this needs to be changed to a custom calc which factors

	--[[
		SEASON 6: IF YOUR TEAM HAS 2 TURRETS ON A LANE MORE THAN THE ENEMY, MINIONS GAIN 90% DAMAGE
	]]
end

--[[
	Init

	Initialises the state for the Orbwalker module, and stores a ref in the environment _G table for script integration. 
]]
function Orbwalker:Init()
	_G.OAC = self
	_G.OACLoaded = false

	self.Player = Player

	self.LastAttackTick = 0
	self.WindUp = 500
	self.LastMoveTick = 0
	self._ProjectileSpeed = 1000
	self.LastAttackStart = self:GetTick()

	self.KeyBinds = {
		Clear = 86,
		Combo = 32,
		Farm = 88,
		Harrass = 67,
	}

	self.Keys = {}

	MissileManager:Init()
	self.MissileManager = MissileManager

	self.VarFuncs = {
		Ping = function() return math.max(Game.GetLatency()/2, 0) end,
		AttackSpeed = function() return 1/self.Player.AttackDelay end,
		AttackDelay = function() return self.Player.AttackDelay end,
		AttackCastDelay = function() return self.Player.AttackCastDelay end,
		Range = function() return self.Player.AttackRange end,
		ProjectileSpeed = function() return self:Melee() and math.huge or self._ProjectileSpeed end,
	}
	local VarFuncs = self.VarFuncs

	self.Enemies = ObjManager.Get("enemy", "heroes")
	self.Allies = ObjManager.Get("ally", "heroes")

	self.Turrets = {}
	self.TurretTargets = {}
	self.TurretShotTimers = {}

	setmetatable(self, {
		__index = function(t, k)
			return rawget(t, k) or VarFuncs[k] and VarFuncs[k]()
		end,
	})

	_G.OACLoaded = true
	return self -- redundant but w/e now u can get ref
end

function Orbwalker:OnProcessSpell(AIBaseSrc, Spell)
	if AIBaseSrc.Handle == Player.Handle then
		if Spell.Name:lower():find("attack") then
			self.LastAttackTick = self:GetTick()
			self.WindUp = math.floor(Spell.CastDelay * 1000) + 1
		end
	elseif AIBaseSrc.IsTurret then
		if not self.Turrets[AIBaseSrc.__obj] then
			self.Turrets[AIBaseSrc.__obj] = AIBaseSrc.AsAttackableUnit
			AIBaseSrc.MissileSpeed = Spell.MissileSpeed
		end

		local Turret = AIBaseSrc.AsAttackableUnit
		if BBDist(Turret,Player) < 1500 then
			self.TurretTargets[Turret.__obj] = Spell.Target
			self.TurretShotTimers[Turret.__obj] = self:GetTick()
		end
	end
end

function Orbwalker:GetNearestTurret(team)
	local team = team or "ally"
	
	local closest,dist = nil, math.huge
	pcall(function()
		for i, turret in pairs(self.Turrets) do
			if turret and (turret.TeamId == Player.TeamId) == (team == "ally") then
				local dist2 = BBDist(turret,Player)
				if dist2 < dist then
					closest = turret
					dist = dist2
				end
			end
		end
	end)

	return closest
	
end

function Orbwalker:Melee()
	return self.Range <= 325
end

function Orbwalker:Attacking()
	local elapsed = self:GetTick() - self.LastAttackStart
	local required = self.WindUp + self.Ping + 10
	--printf("Attacking elapsed " .. tostring(elapsed) .. " required " .. tostring(required))
	return elapsed <= required
end

function Orbwalker:CanAttack()
	local elapsed = self:GetTick() - self.LastAttackTick
	local required = self.AttackDelay*1000 - self.AttackCastDelay*1000 - self.Ping*2
	--printf("CanAttack elapsed " .. tostring(elapsed) .. " required " .. tostring(required))
	return elapsed > required
end

function Orbwalker:CanMove()
	return self:GetTick() > self.LastAttackTick + self.WindUp and self.Player.CanMove and not self:Attacking() and not Player.AsAI.IsChanneling
end

function Orbwalker:Attack(AIBase)
	self.LastAttackStart = self:GetTick()
	Input.Attack(AIBase)
end

function Orbwalker:MoveTo(v)
	Input.MoveTo(v)
	self.LastMoveTick = self:GetTick()
end

--[[
	GetTick

	returns: The game time in milliseconds
]]
function Orbwalker:GetTick()
	return math.floor(Game.GetTime() * 1000) 
end

function Orbwalker:AutoDamage()
	local modifier = 1
	local offset = 0

	--do draven/varus Q/W buffs and Sona Q buff etc etc etc...

	return self.Player.TotalAD * modifier + offset
end

function Orbwalker:HasItem(name)
	for i=6, 12 do
		local itemname = Player.AsAI:GetSpell(i) and Player.AsAI:GetSpell(i).Name
		if itemname and itemname:find(name) then return true end
	end
end

function Orbwalker:AADamageTo(Obj)
	local bonus_phys = 0
	if self:HasItem("ItemSwordOfFeastAndFamine") then 
		bonus_phys = bonus_phys + (self:Melee() and .12 or .08) * Obj.AsAI.Health
	end
	return DMGLib:CalcPhysicalDamage(self.Player, Obj, self:AutoDamage() + bonus_phys)
end

function Orbwalker:PredictMinionHealth(Minion, Delay)
	if not Minion.AsMinion or not Minion.AsMinion.IsTargetable or not Minion.AsMinion.IsAlive then
		return 999
	end

	local delay = Delay

	local health = Minion.AsMinion.Health
	pcall(function()
		local inbound = self.MissileManager.MissilesKeyTarget[Minion.__obj]
		if inbound then
			for _, Missile in pairs(inbound) do
				if Missile.__obj ~= 0 and Minion.__obj ~= 0 and not Missile.IsDead then
					local delay2 = Missile.Position:Distance(Missile.AsMissile.Target.Position) / Missile.AsMissile.Speed
					if delay2 < delay then
						local damage = self.MissileManager:CalcMissileDamage(Missile)
						health = health - damage
					end
				end
			end
		end
	end)

	return health
end

function Orbwalker:GetLastHitMinions()
	local EnemyMinions = ObjManager.Get("enemy", "minions")
	local LastHitMinions = {}

	for _, Minion in pairs(EnemyMinions) do
		if BBDist(Minion,Player) < self.Range+50 then
			if self:PredictMinionHealth(Minion, self.WindUp/1000 + self.Player.Position:Distance(Minion.Position) / self.ProjectileSpeed) < self:AADamageTo(Minion) then
				table.insert(LastHitMinions, Minion)
			end
		end
	end

	table.sort(LastHitMinions, function(a,b) return a.AsAttackableUnit.MaxHealth > b.AsAttackableUnit.MaxHealth end)
	return LastHitMinions
end

function Orbwalker:GetNextHitMinions()
	local AllyMinions = ObjManager.Get("ally", "minions")
	for i, Minion in pairs(AllyMinions) do
		if BBDist(Minion,Player) > 1500 then
			table.remove(AllyMinions, i)
		end
	end

	local EnemyMinions = ObjManager.Get("enemy", "minions")
	local Hit = {}

	for _, Minion in pairs(EnemyMinions) do
		if BBDist(Minion,Player) < self.Range+200 then
			local damage = Minion.AsAttackableUnit.Health - self:PredictMinionHealth(Minion, self.Player.Position:Distance(Minion.Position)/self.ProjectileSpeed + self.AttackDelay)
			if Minion.AsAttackableUnit.Health - 2.25*damage < self:AADamageTo(Minion) + 50 + (#AllyMinions>1 and 150 or 0) then
				table.insert(Hit, Minion)
			end
		end
	end

	table.sort(Hit, function(a,b) return a.AsAttackableUnit.MaxHealth > b.AsAttackableUnit.MaxHealth end)
	return Hit
end

function Orbwalker:GetSafeMinions()
	local EnemyMinions = ObjManager.Get("enemy", "minions")
	local Hit = {}

	local AlienMinions = ObjManager.Get("neutral", "minions")

	local EnemyStructures = ObjManager.Get("enemy", "turrets")

	for _, Minion in pairs(EnemyMinions) do
		if BBDist(Minion,Player) < self.Range then
			local damage = Minion.AsAttackableUnit.Health - self:PredictMinionHealth(Minion, self.Player.Position:Distance(Minion.Position)/self.ProjectileSpeed + self.AttackDelay)
			if Minion.AsAttackableUnit.Health - 2*damage > self:AADamageTo(Minion) then
				table.insert(Hit, Minion)
			end
		end
	end

	for x, y in pairs(AlienMinions) do
		if BBDist(y,Player) < self.Range then
			table.insert(Hit, y)
		end
	end

	table.sort(Hit, function(a,b) return a.AsAttackableUnit.Health < b.AsAttackableUnit.Health end)
	return Hit
end

function Orbwalker:LastHitTurret()
	local turret = self:GetNearestTurret("ally")

	local target = self.TurretTargets[turret.__obj]
	if not target or not target.AsAttackableUnit then
		if self:CanMove() then
			self:MoveTo(Renderer:GetMousePos())
		end
		return
	end

	if target.AsAttackableUnit.Health > 0 and target.AsAttackableUnit.Health < self:AADamageTo(target) and self:CanAttack() then
		printf("do simple")
		self:Attack(target)
		return
	end

	local predhp = self:PredictMinionHealth(target, self.WindUp/1000 + target.Position:Distance(Player.Position)/self.ProjectileSpeed - self.Ping/1000)
	if predhp > 0 and (predhp < self:AADamageTo(target)) and self:CanAttack() then
		printf("do pred1 attack")
		self:Attack(target)
		return
	end

	local towershots = target.AsAttackableUnit.Health / DMGLib:CalcPhysicalDamage(turret.AsAI, target.AsAI, turret.AsAI.TotalAD)
	local remain = target.AsAttackableUnit.Health - math.floor(towershots) * DMGLib:CalcPhysicalDamage(turret.AsAI, target.AsAI, turret.AsAI.TotalAD)
	if remain > self:AADamageTo(target) and self:CanAttack() and target.AsAI.CharName:find("Ranged") then
		printf(tostring(remain) .. " : " ..tostring(self:AADamageTo(target)))
		self:Attack(target)
		return
	end

	if self:CanMove() then
		self:MoveTo(Renderer:GetMousePos())
	end
end

function Orbwalker:LastHit()
	local turret = self:GetNearestTurret("ally")
	if turret and BBDist(turret, Player) < 1500 then
		self:LastHitTurret()
		return
	end 

	if self:CanAttack() then
		local lasthits = self:GetLastHitMinions()

		if #lasthits>0 then
			self:Attack(lasthits[1])
		end
	end

	if self:CanMove() then
		if self:GetTick() - self.LastMoveTick > 100 then
			self:MoveTo(Renderer:GetMousePos())
		end
	end
end

function Orbwalker:LaneClear()
	local DieMinions = self:GetLastHitMinions()
	local PushMinions = self:GetSafeMinions()
	local DangerMinions = self:GetNextHitMinions()

	local target = DieMinions[1] 
	if not DangerMinions[1] then target = self:GetHeroTarget() or PushMinions[1] end

	if target and self:CanAttack() and target.AsMinion.IsAlive and target.AsMinion.IsTargetable then
		self:Attack(target)
	end

	if self:CanMove() then
		if self:GetTick() - self.LastMoveTick > 100 then
			self:MoveTo(Renderer:GetMousePos())
		end
	end
end

function Orbwalker:Harrass()
	local DieMinions = self:GetLastHitMinions()

	local target = DieMinions[1] or self:GetHeroTarget()

	if target and self:CanAttack() and target.AsAI.IsAlive and target.AsAI.IsTargetable and BBDist(Player,target) < self.Range then
		self:Attack(target)
	end

	if self:CanMove() then
		if self:GetTick() - self.LastMoveTick > 100 then
			self:MoveTo(Renderer:GetMousePos())
		end
	end
end

function Orbwalker:Combo()
	local target = self:GetHeroTarget()

	if target and self:CanAttack() and target.AsAI.IsAlive and target.AsAI.IsTargetable and BBDist(target,Player) < self.Range-20 then
		self:Attack(target)
	end

	if self:CanMove() then
		if self:GetTick() - self.LastMoveTick > 100 then
			self:MoveTo(Renderer:GetMousePos())
		end
	end
end

function Orbwalker:GetHeroTarget()
	return ts:GetTarget(Player.AttackRange + Player.BoundingRadius-20, ts.Priority.LowestHealth)
end

function Orbwalker:OnTick()
	local mode = self:Mode()
	if mode then
		local map = {
			Combo = self.Combo,
			Farm = self.LastHit,
			Harrass = self.Harrass,
			Clear = self.LaneClear
		}
		local t = map[mode] and map[mode](self)
	end
end

function Orbwalker:DebugText(t, adornee, offset)
	offset = offset or Vector(0,0,0)
	Renderer.DrawText(adornee and adornee.Position:ToScreen() + offset or Vector(200,200 + 30*self.DebugTextCount,0), Vector(200,40,0), t, 0xffffffff)
	self.DebugTextCount = self.DebugTextCount+1
end

function Orbwalker:OnDraw()
	Renderer.DrawCircle3D(Player.Position, self.Range + self.Player.AsAI.BoundingRadius, 30, 1, 0xffffffff)

	for i,v in pairs(ObjManager.Get("enemy", "heroes")) do
		Renderer.DrawCircle3D(v.Position, v.AsAI.AttackRange+v.AsAI.BoundingRadius, 10, 1, 0xffffffff)
	end
end

function Orbwalker:KeyDown(key)
	self.Keys[key] = true
end

function Orbwalker:KeyUp(key)
	self.Keys[key] = false
end

function Orbwalker:Mode()
	return self.Keys[self.KeyBinds.Combo] and "Combo" or self.Keys[self.KeyBinds.Clear] and "Clear" or self.Keys[self.KeyBinds.Farm] and "Farm" or self.Keys[self.KeyBinds.Harrass] and "Harrass"
end

local function OnProcessSpell(AIBaseSrc, Spell)
	Orbwalker:OnProcessSpell(AIBaseSrc, Spell)
end

local function OnCreateObject(Obj)
	Orbwalker.MissileManager:ProcessObjectCreated(Obj)
end

local function OnDeleteObject(Obj)
	Orbwalker.MissileManager:ProcessObjectDestroyed(Obj)
end

local function OnTick()
	Orbwalker:OnTick()
end

local function OnDraw()
	Orbwalker:OnDraw()
end

local function OnKeyDown(key)
	Orbwalker:KeyDown(key)
end

local function OnKeyUp(key)
	Orbwalker:KeyUp(key)
end

function OnLoad() 
	EventManager.RegisterCallback(Enums.Events.OnTick, OnTick)
	EventManager.RegisterCallback(Enums.Events.OnProcessSpell, OnProcessSpell)
	EventManager.RegisterCallback(Enums.Events.OnDraw, OnDraw)
	EventManager.RegisterCallback(Enums.Events.OnCreateObject, OnCreateObject)
	EventManager.RegisterCallback(Enums.Events.OnDeleteObject, OnDeleteObject)
	EventManager.RegisterCallback(Enums.Events.OnKeyDown, OnKeyDown)
	EventManager.RegisterCallback(Enums.Events.OnKeyUp, OnKeyUp)
	Orbwalker:Init()

	return true
end

return Orbwalker
