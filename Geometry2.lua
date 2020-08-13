require("common.log")
module("Geometry2", package.seeall, log.setup)

local _SDK = _G.CoreEx
local ObjManager, EventManager, Input, Enums, Game = _SDK.ObjectManager, _SDK.EventManager, _SDK.Input, _SDK.Enums, _SDK.Game
local SpellSlots, SpellStates = Enums.SpellSlots, Enums.SpellStates 
local Player = ObjManager.Player
local Vector = _SDK.Geometry.Vector
local Renderer = _SDK.Renderer

--useful
local function clamp(x, min, max)
	return math.max( math.min(x, max), min)
end

--tempfix
function Vector:Normalized()
	return Vector(self.x, self.y, self.z)/self:Len()
end
--as of 13/08/2020 :Normalized() was acting in place rather than on a new Vector

local LineSegment = {}
setmetatable(LineSegment, {
	--wowee now turbo dogs can go ape mode and print linesegments
	__tostring = function(self)
		return "LineSegment(" .. tostring(self.Start.x) .. " , " .. tostring(self.Start.z) .. " , " .. tostring(self.End.x) .. " , " .. tostring(self.End.z) .. ")"
	end,
	--Class Instance Constructor
	__call = function(self,a,b)
		local self = {}
		self.Start = a
		self.End = b
		self.Direction = self.End - self.Start
		setmetatable(self, {
			__index=LineSegment
		})
		return self
	end
})

--Does some trigonometry to give you the projection of v from the LineSegment.Start onto the LineSegment Direction, as a multiple of the LineSegment length
function LineSegment:ScalarProjection(v)
	v = Vector(v.x, self.Start.y, v.z)--fuggem 3 dimensional shitter 
	local localspace = (v-self.Start)
	return (localspace:Normalized():DotProduct(self.Direction:Normalized()) * localspace:Len()) / self.Direction:Len()
end

--Returns the nearest point within the bounds of the LineSegment to a given 3d Vector
function LineSegment:NearestPointToVector(v)
	return self.Start + clamp(self:ScalarProjection(v), 0, 1) * self.Direction  --from cos(<ab) = a.b/|a||b| dot product law
end

--Returns the minimum Distance between a Vector Position and the LineSegment
function LineSegment:DistanceToVector(v)
	return (v-self:NearestPointToVector(v)):Len()
end

--returns the point of Intersection of two LineSegment instances, if the Intersection is within the bounds of the LineSegment(s)
function LineSegment:Intersect(l)
	--2D only solution, fugg Y gang, we XZ 
	local Startq1X = self.Start.x - l.Start.x
	local Startq1Y = self.Start.z - l.Start.z	
	
	local a = l.Direction.x
	local b = -self.Direction.x
	local c = l.Direction.z
	local d = -self.Direction.z
	
	local detA = a*d - b*c
	
	local mew = Startq1X * d/detA  + Startq1Y * -b/detA
	local lambda = Startq1X * -c/detA + Startq1Y * a/detA
	
	if mew < 0 or mew > 1 then return false end
	if lambda < 0 or lambda > 1 then return false end
	
	res = l.Start + l.Direction*mew
	
	return res
	--derived from solving for lambda and mu given start + lambda direction and start2 + mu direction2 with matrix inverse law for solving system of unknowns
	--it's 5am code and I didn't sleep, ignore plz
end

--Debug draw, ignore pls
function LineSegment:Draw(color)
	local color = color or 0xffffffff
	Renderer.DrawLine(Vector(self.Start.x, Player.Position.y, self.Start.z):ToScreen(), Vector(self.End.x, Player.Position.y, self.End.z):ToScreen(), 5, color)
end

local Polygon = {}
setmetatable(Polygon, {
	--Creates a Polygon with retard friendly OOP syntax
	__call = function(self, ...)
		local args = {...}

		local self = {}
		self.Lines = {}
		self.Points = {}

		for _, Point in pairs(args) do
			local last = self.Points[#self.Points]
			if last then
				table.insert(self.Lines, LineSegment(last, Point))
			end

			table.insert(self.Points, Point)
		end
		table.insert(self.Lines, LineSegment(self.Points[#self.Points], self.Points[1]))
		setmetatable(self, {__index=Polygon})
		return self
	end
})

--returns whether the given Vector Position v is within the Polygon
function Polygon:Contains(v)
	--horizontal raycast algorithm, may need testing along edge of toplane for errors
	local ray = LineSegment(Vector(-1000, v.y, v.z), v)
	local intersections = 0
	for _, Line in pairs(self.Lines) do
		if Line:Intersect(ray) then
			intersections = intersections + 1
		end
	end
	return intersections%2 == 0
end

--debug draw, kill pls
function Polygon:Draw()
	local contains = self:Contains(Player.Position)
	for _, LineSegment in pairs(self.Lines) do
		LineSegment:Draw(contains and 0x00ff00ff or 0xff0000ff)
	end
end

local Lib = {}
Lib.LineSegment = LineSegment
Lib.Polygon = Polygon
return Lib