local ACF = ACF

ACF.Bullets          = ACF.Bullets or {}
ACF.UnusedIndexes    = ACF.UnusedIndexes or {}
ACF.HighestIndex     = ACF.HighestIndex or 0
ACF.IndexLimit       = 2000
ACF.SkyboxGraceZone  = 100

local Bullets       = ACF.Bullets
local Unused        = ACF.UnusedIndexes
local FlightTr  	= { start = true, endpos = true, filter = true, mask = true }
local BackRes 		= {}
local BackTrace 	= { start = true, endpos = true, filter = true, mask = true, output = BackRes }
local GlobalFilter 	= ACF.GlobalFilter
local AmmoTypes     = ACF.Classes.AmmoTypes
local Gravity       = Vector(0, 0, -GetConVar("sv_gravity"):GetInt())
local HookRun		= hook.Run
local ACF_KEPUSH    = GetConVar("acf_kepush")

cvars.AddChangeCallback("sv_gravity", function(_, _, Value)
	Gravity.z = -Value
end, "ACF Bullet Gravity")

-- This will check a vector against all of the hitboxes stored on an entity
-- If the vector is inside a box, it will return true, the box name (organization I guess, can do an E2 function with all of this), and the hitbox itself
-- If the entity in question does not have hitboxes, it returns false
-- Finally, if it never hits a hitbox in its check, it also returns false
function ACF_CheckInsideHitbox(Ent, Vec)
	if not Ent.HitBoxes then return false end -- If theres no hitboxes, then don't worry about them

	for k,v in pairs(Ent.HitBoxes) do
		-- v is the box table

		-- Need to make sure the vector is local and LEVEL with the box, otherwise WithinAABox will be wildly wrong
		local LocalPos = WorldToLocal(Vec,Angle(0,0,0),Ent:LocalToWorld(v.Pos),Ent:LocalToWorldAngles(v.Angle))
		local CheckHitbox = LocalPos:WithinAABox(-v.Scale / 2,v.Scale / 2)

		if CheckHitbox == true then return Check,k,v end
	end

	return false
end

-- This performs ray-OBB intersection with all of the hitboxes on an entity
-- Ray is the TOTAL ray to check with, so vec(500,0,0) to check all 500u forward
-- It will return false if there are no hitboxes or it didn't hit anything
-- If it hits any hitboxes, it will put them all together and return (true,HitBoxes)
function ACF_CheckHitbox(Ent,RayStart,Ray)
	if not Ent.HitBoxes then return false end -- Once again, cancel if there are no hitboxes

	local AllHit = {}

	for k,v in pairs(Ent.HitBoxes) do

		local _,_,Frac = util.IntersectRayWithOBB(RayStart, Ray, Ent:LocalToWorld(v.Pos), Ent:LocalToWorldAngles(v.Angle), -v.Scale / 2, v.Scale / 2)

		if Frac ~= nil then
			AllHit[k] = v
		end
	end

	return next(AllHit) and true or false, AllHit
end

-- This will create, or update, the tracer effect on the clientside
function ACF.BulletClient(Bullet, Type, Hit, HitPos)
	if Bullet.NoEffect then return end -- No clientside effect will be created for this bullet

	local Effect = EffectData()
	Effect:SetHitBox(Bullet.Index)
	Effect:SetStart(Bullet.Flight * 0.1)

	if Type == "Update" then
		if Hit > 0 then
			Effect:SetOrigin(HitPos)
		else
			Effect:SetOrigin(Bullet.Pos)
		end

		Effect:SetScale(Hit)
	else
		Effect:SetOrigin(Bullet.Pos)
		Effect:SetEntity(Entity(Bullet.Crate))
		Effect:SetScale(0)
	end

	util.Effect("ACF_Bullet_Effect", Effect, true, true)
end

function ACF.RemoveBullet(Bullet)
	local Index = Bullet.Index

	Bullets[Index] = nil
	Unused[Index]  = true

	if Bullet and Bullet.OnRemoved then
		Bullet:OnRemoved()
	end

	if not next(Bullets) then
		hook.Remove("Tick", "IterateBullets")
	end
end

function ACF.CalcBulletFlight(Bullet)
	if not Bullet.LastThink then return ACF.RemoveBullet(Bullet) end

	if Bullet.PreCalcFlight then
		Bullet:PreCalcFlight()
	end

	local DeltaTime = ACF.CurTime - Bullet.LastThink
	local Drag      = Bullet.Flight:GetNormalized() * (Bullet.DragCoef * Bullet.Flight:LengthSqr()) / ACF.DragDiv
	local Accel     = Bullet.Accel or Gravity

	Bullet.NextPos   = Bullet.Pos + (Bullet.Flight * ACF.Scale * DeltaTime)
	Bullet.Flight    = Bullet.Flight + (Accel - Drag) * DeltaTime
	Bullet.LastThink = ACF.CurTime
	Bullet.DeltaTime = DeltaTime

	ACF.DoBulletsFlight(Bullet)

	if Bullet.PostCalcFlight then
		Bullet:PostCalcFlight()
	end

	Bullet.LastPos = Bullet.Pos
	Bullet.Pos = Bullet.NextPos
end

local function GetBulletIndex()
	if next(Unused) then
		local Index = next(Unused)

		Unused[Index] = nil

		return Index
	end

	local Index = ACF.HighestIndex + 1

	if Index > ACF.IndexLimit then return end

	ACF.HighestIndex = Index

	return Index
end

local CalcFlight = ACF.CalcBulletFlight
local function IterateBullets()
	for _, Bullet in pairs(Bullets) do
		if not Bullet.HandlesOwnIteration then
			CalcFlight(Bullet)
		end
	end
end

function ACF.CreateBullet(BulletData)
	local Index = GetBulletIndex()

	if not Index then return end -- Too many bullets in the air

	local Bullet = table.Copy(BulletData)

	if not Bullet.Filter then
		Bullet.Filter = IsValid(Bullet.Gun) and { Bullet.Gun } or {}
	end

	Bullet.Index       = Index
	Bullet.LastThink   = ACF.CurTime
	Bullet.Fuze        = Bullet.Fuze and Bullet.Fuze + ACF.CurTime or nil -- Convert Fuze from fuze length to time of detonation
	Bullet.Mask        = MASK_SOLID -- Note: MASK_SHOT removed for smaller projectiles as it ignores armor
	Bullet.Ricochets   = 0
	Bullet.GroundRicos = 0
	Bullet.Color       = ColorRand(100, 255)

	if not next(Bullets) then
		hook.Add("Tick", "IterateBullets", IterateBullets)
	end

	Bullets[Index] = Bullet

	ACF.BulletClient(Bullet, "Init", 0)
	ACF.CalcBulletFlight(Bullet)

	return Bullet
end

local function OnImpact(Bullet, Trace, Type)
	local Data  = AmmoTypes[Bullet.Type]
	local Func  = Type == "World" and Data.WorldImpact or Data.PropImpact
	local Retry = Func(Data, Bullet, Trace)

	if Retry == "Penetrated" then
		if Bullet.OnPenetrated then
			Bullet.OnPenetrated(Bullet, Trace)
		end

		ACF.BulletClient(Bullet, "Update", 2, Trace.HitPos)
		ACF.DoBulletsFlight(Bullet)
	elseif Retry == "Ricochet" then
		if Bullet.OnRicocheted then
			Bullet.OnRicocheted(Bullet, Trace)
		end

		ACF.BulletClient(Bullet, "Update", 3, Trace.HitPos)
	else
		if Bullet.OnEndFlight then
			Bullet.OnEndFlight(Bullet, Trace)
		end

		ACF.BulletClient(Bullet, "Update", 1, Trace.HitPos)

		Data:OnFlightEnd(Bullet, Trace)
	end
end

function ACF.DoBulletsFlight(Bullet)
	if HookRun("ACF Bullet Flight", Bullet) == false then return end

	if Bullet.SkyLvL then
		if ACF.CurTime - Bullet.LifeTime > 30 then
			return ACF.RemoveBullet(Bullet)
		end

		if Bullet.NextPos.z + ACF.SkyboxGraceZone > Bullet.SkyLvL then
			if Bullet.Fuze and Bullet.Fuze <= ACF.CurTime then -- Fuze detonated outside map
				ACF.RemoveBullet(Bullet)
			end

			return
		elseif not util.IsInWorld(Bullet.NextPos) then
			return ACF.RemoveBullet(Bullet)
		else
			Bullet.SkyLvL = nil
			Bullet.LifeTime = nil

			return
		end
	end

	FlightTr.mask 	= Bullet.Mask
	FlightTr.filter = Bullet.Filter
	FlightTr.start 	= Bullet.Pos
	FlightTr.endpos = Bullet.NextPos

	local FlightRes, Filter = ACF.TraceF(FlightTr) -- Does not modify the bullet's original filter

	debugoverlay.Line(Bullet.Pos, FlightRes.HitPos, 15, Bullet.Color)
	-- Something was hit, let's make sure we're not phasing through armor
	if Bullet.LastPos and IsValid(FlightRes.Entity) and not GlobalFilter[FlightRes.Entity:GetClass()] then
		BackTrace.start  = Bullet.LastPos
		BackTrace.endpos = Bullet.Pos
		BackTrace.mask   = Bullet.Mask
		BackTrace.filter = Bullet.Filter

		ACF.TraceF(BackTrace) -- Does not modify the bullet's original filter

		-- There's something behind our trace, go back one tick
		if IsValid(BackRes.Entity) and not GlobalFilter[BackRes.Entity:GetClass()] then
			Bullet.NextPos = Bullet.Pos
			Bullet.Pos = Bullet.LastPos
			Bullet.LastPos = nil

			FlightTr.start 	= Bullet.Pos
			FlightTr.endpos = Bullet.NextPos

			FlightRes = ACF.Trace(FlightTr)
		else
			Bullet.Filter = Filter
		end
	else
		Bullet.Filter = Filter
	end

	if Bullet.Fuze and Bullet.Fuze <= ACF.CurTime then
		if not util.IsInWorld(Bullet.Pos) then -- Outside world, just delete
			return ACF.RemoveBullet(Bullet.Index)
		else
			if Bullet.OnEndFlight then
				Bullet.OnEndFlight(Bullet, nil)
			end

			local DeltaTime = Bullet.DeltaTime
			local DeltaFuze = ACF.CurTime - Bullet.Fuze
			local Lerp = DeltaFuze / DeltaTime
			--print(DeltaTime, DeltaFuze, Lerp)
			if FlightRes.Hit and Lerp < FlightRes.Fraction or true then -- Fuze went off before running into something
				local Pos = LerpVector(DeltaFuze / DeltaTime, Bullet.Pos, Bullet.NextPos)

				debugoverlay.Line(Bullet.Pos, Bullet.NextPos, 5, Color( 0, 255, 0 ))

				ACF.BulletClient(Bullet, "Update", 1, Pos)

				AmmoTypes[Bullet.Type]:OnFlightEnd(Bullet, Pos, Bullet.Flight:GetNormalized())
			end
		end
	end

	if FlightRes.Hit then
		if FlightRes.HitSky then
			if FlightRes.HitNormal == Vector(0, 0, -1) then
				Bullet.SkyLvL = FlightRes.HitPos.z
				Bullet.LifeTime = ACF.CurTime
			else
				ACF.RemoveBullet(Bullet)
			end
		else
			local Type = (FlightRes.HitWorld or FlightRes.Entity:CPPIGetOwner() == game.GetWorld()) and "World" or "Prop"

			OnImpact(Bullet, FlightRes, Type)
		end
	end
end

do -- Terminal ballistics --------------------------
	local function RicochetVector(Flight, HitNormal)
		local Vec = Flight:GetNormalized()

		return Vec - ( 2 * Vec:Dot(HitNormal) ) * HitNormal
	end

	function ACF_RoundImpact( Bullet, Speed, Energy, Target, HitPos, HitNormal , Bone  )
		local Angle = ACF_GetHitAngle( HitNormal , Bullet.Flight )

		local HitRes = ACF_Damage ( --DAMAGE !!
			Target,
			Energy,
			Bullet.PenArea,
			Angle,
			Bullet.Owner,
			Bone,
			Bullet.Gun,
			Bullet.Type
		)

		local Ricochet = 0
		if HitRes.Loss == 1 then
			-- Ricochet distribution center
			local sigmoidCenter = Bullet.DetonatorAngle or ( Bullet.Ricochet - math.abs(Speed / 39.37 - Bullet.LimitVel) / 100 )

			-- Ricochet probability (sigmoid distribution); up to 5% minimal ricochet probability for projectiles with caliber < 20 mm
			local ricoProb = math.Clamp( 1 / (1 + math.exp( (Angle - sigmoidCenter) / -4) ), math.max(-0.05 * (Bullet.Caliber - 2) / 2, 0), 1 )

			-- Checking for ricochet
			if ricoProb > math.random() and Angle < 90 then
				Ricochet       = math.Clamp(Angle / 90, 0.05, 1) -- atleast 5% of energy is kept
				HitRes.Loss    = 0.25 - Ricochet
				Energy.Kinetic = Energy.Kinetic * HitRes.Loss
			end
		end

		if ACF_KEPUSH:GetBool() then
			Shove(
				Target,
				HitPos,
				Bullet.Flight:GetNormalized(),
				Energy.Kinetic * HitRes.Loss * 1000 * Bullet.ShovePower
			)
		end

		if HitRes.Kill then
			local Debris = ACF_APKill( Target , (Bullet.Flight):GetNormalized() , Energy.Kinetic )
			table.insert( Bullet.Filter , Debris )
		end

		HitRes.Ricochet = false

		if Ricochet > 0 and Bullet.Ricochets < 3 then
			Bullet.Ricochets = Bullet.Ricochets + 1
			Bullet.NextPos = HitPos
			Bullet.Flight = (RicochetVector(Bullet.Flight, HitNormal) + VectorRand() * 0.025):GetNormalized() * Speed * Ricochet

			HitRes.Ricochet = true
		end

		return HitRes
	end

	function ACF_Ricochet(Bullet, Trace)
		local Ricochet = 0
		local Speed = Bullet.Flight:Length() / ACF.Scale
		local Angle = ACF_GetHitAngle( Trace.HitNormal, Bullet.Flight )
		local MinAngle = math.min(Bullet.Ricochet - Speed / 39.37 / 30 + 20,89.9)	--Making the chance of a ricochet get higher as the speeds increase

		if Angle > math.random(MinAngle,90) and Angle < 89.9 then	--Checking for ricochet
			Ricochet = Angle / 90 * 0.75
		end

		if Ricochet > 0 and Bullet.GroundRicos < 2 then
			Bullet.GroundRicos = Bullet.GroundRicos + 1
			Bullet.NextPos = Trace.HitPos
			Bullet.Flight = (RicochetVector(Bullet.Flight, Trace.HitNormal) + VectorRand() * 0.05):GetNormalized() * Speed * Ricochet

			print("Ricochet")
			return "Ricochet"
		end

		return false
	end

	local function DigTrace(From, To, Filter)
		local Dig = util.TraceHull({
			start  = From,
			endpos = To,
			mask   = MASK_NPCSOLID_BRUSHONLY, -- Map and brushes only
			mins   = Vector(),
			maxs   = Vector()
		})

		debugoverlay.Line(From, Dig.HitPos, 30, ColorRand(100, 255), true)

		if Dig.StartSolid then -- Started inside solid map volume
			if Dig.FractionLeftSolid == 0 then -- Trace could not move inside
				local Displacement = To - From
				local Normal       = Displacement:GetNormalized()
				local Length       = Displacement:Length()

				local C = math.Round(Length / 12)
				local N = Length / C

				for I = 1, C do
					local P = From + Normal * I * N

					debugoverlay.Cross(P, 1, 15, Color(255, 255, 0), true)

					local Back = util.TraceHull({ -- Send a trace backwards to hit the other side
						start  = P,
						endpos = From, -- Countering the initial offset position of the dig trace to handle things <1 inch thick
						mask   = MASK_NPCSOLID_BRUSHONLY, -- Map and brushes only
						mins   = Vector(),
						maxs   = Vector()
					})

					if Back.StartSolid or Back.HitNoDraw then continue end

					debugoverlay.Line(P, Back.HitPos, 30, Color(255, 0, 255), true)
					return true, Back.HitPos
				end

				return false
			elseif Dig.FractionLeftSolid == 1 then -- Non-penetration: too thick
				return false
			else -- Penetrated
				if Dig.HitNoDraw then -- Hit a layer inside
					return DigTrace(Dig.HitPos + (To - From):GetNormalized() * 0.1, To, Filter) -- Try again
				else -- Complete penetration
					local Back = util.TraceHull({
						start  = Dig.StartPos,
						endpos = From,
						mask   = MASK_NPCSOLID_BRUSHONLY, -- Map and brushes only
						mins   = Vector(),
						maxs   = Vector()
					})

					-- False positive, still inside the world
					-- Typically occurs when two brushes meet
					if Back.StartSolid or Back.HitNoDraw then
						return DigTrace(Dig.StartPos + (To - From):GetNormalized() * 0.1, To, Filter)
					end

					debugoverlay.Cross(Dig.StartPos, 5, 30, Color(255, 0, 0), true) -- Red cross: Exit point

					return true, Dig.StartPos
				end
			end
		else -- Started inside a brush
			local Back = util.TraceHull({ -- Send a trace backwards to hit the other side
				start  = Dig.HitPos,
				endpos = From + (From - Dig.HitPos):GetNormalized(), -- Countering the initial offset position of the dig trace to handle things <1 inch thick
				mask   = MASK_NPCSOLID_BRUSHONLY, -- Map and brushes only
				mins   = Vector(),
				maxs   = Vector()
			})

			local Up = (Dig.HitPos - Back.HitPos):Angle():Up()
			debugoverlay.Line(Dig.HitPos + Up, Back.HitPos + Up, 30, Color(255, 0, 160), true)

			if Back.StartSolid then -- object is too thick
				return false
			elseif not Back.Hit or Back.HitNoDraw then
				-- Hit nothing on the way back
				-- Map edge, going into the ground, whatever...
				-- Effectively infinitely thick

				return false
			else -- Penetration
				debugoverlay.Cross(Back.HitPos, 5, Color(255, 0, 0), true) -- Red cross: Exit point

				return true, Back.HitPos
			end
		end
	end

	function ACF_PenetrateMapEntity(Bullet, Trace)
		print("PenetrateMapEntity")

		local Energy  = ACF_Kinetic(Bullet.Flight:Length() / ACF.Scale, Bullet.ProjMass, Bullet.LimitVel)
		local Density = (util.GetSurfaceData(Trace.SurfaceProps).density * 0.5 * math.Rand(0.9, 1.1)) ^ 0.9 / 10000
		local Pen     = Energy.Penetration / Bullet.PenArea * ACF.KEtoRHA -- Base RHA penetration of the projectile
		local RHAe    = math.max(Pen / Density, 1) -- RHA equivalent thickness of the target material

		local Enter   = Trace.HitPos -- Impact point
		local Fwd     = Bullet.Flight:GetNormalized()

		local PassThrough = util.TraceHull({
			start  = Enter,
			endpos = Enter + Fwd * RHAe / 25.4,
			filter = {Trace.Entity},
			mask   = MASK_SOLID_BRUSHONLY
		})

		debugoverlay.Line(PassThrough.StartPos, PassThrough.HitPos, 30, Color(255, 0, 160), true)

		local Filt = {}
		local Back

		repeat
			Back = util.TraceHull({
				start  = PassThrough.HitPos,
				endpos = Enter,
				filter = Filt
			})

			if Back.HitNonWorld and Back.Entity ~= Trace.Entity then
				Filt[#Filt + 1] = Back.Entity
				continue
			end

			if Back.StartSolid then return ACF_Ricochet(Bullet, Trace) end
		until Back.Entity == Trace.Entity

		local Thicc = (Back.HitPos - Enter):Length() * Density * 25.4 -- Obstacle thickness in RHA

		Bullet.Flight  = Bullet.Flight * (1 - Thicc / Pen)
		Bullet.Pos     = Back.HitPos + Fwd * 0.25

		debugoverlay.Cross(Back.HitPos, 5, 30, Color(255, 0, 0), true)

		return "Penetrated"
		--return true, Back.HitPos, Thickness
	end

	function ACF_PenetrateGround(Bullet, Trace)
		print("ACF_PenetrateGround")

		local Energy  = ACF_Kinetic(Bullet.Flight:Length() / ACF.Scale, Bullet.ProjMass, Bullet.LimitVel)
		local Density = (util.GetSurfaceData(Trace.SurfaceProps).density * 0.5 * math.Rand(0.9, 1.1)) ^ 0.9 / 10000
		local Pen     = Energy.Penetration / Bullet.PenArea * ACF.KEtoRHA -- Base RHA penetration of the projectile
		local RHAe    = math.max(Pen / Density, 1) -- RHA equivalent thickness of the target material

		local Enter   = Trace.HitPos -- Impact point
		local Fwd     = Bullet.Flight:GetNormalized()

		debugoverlay.Cross(Enter, 5, 30, Color(0, 255, 0), true) -- Green cross: entrance point

		local Penetrated, Exit = DigTrace(Enter + Fwd, Enter + Fwd * RHAe / 25.4)

		if Penetrated then
			print("Penetrated")
			local Thicc = (Exit - Enter):Length() * Density * 25.4 -- RHAe of the material passed through

			print("Pass-through RHAe: " .. math.Round(Thicc))
			debugoverlay.Cross(Exit, 5, 30, Color(255, 0, 0), true) -- Red cross: exit point

			Bullet.Flight  = Bullet.Flight * (1 - Thicc / Pen)
			Bullet.Pos     = Exit + Fwd * 0.25
			--Bullet.NextPos = Exit + Fwd * 0.25

			return "Penetrated" --, Exit, Thicc
		else -- Ricochet
			return ACF_Ricochet(Bullet, Trace)
		end
	end
end

-- Backwards compatibility
ACF_BulletClient = ACF.BulletClient
ACF_CalcBulletFlight = ACF.CalcBulletFlight
ACF_DoBulletsFlight = ACF.DoBulletsFlight
ACF_RemoveBullet = ACF.RemoveBullet
ACF_CreateBullet = ACF.CreateBullet
