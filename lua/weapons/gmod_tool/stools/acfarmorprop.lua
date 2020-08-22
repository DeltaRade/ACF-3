
local cat = ((ACF.CustomToolCategory and ACF.CustomToolCategory:GetBool()) and "ACF" or "Construction");

TOOL.Category	= cat
TOOL.Name		= "#tool.acfarmorprop.name"
TOOL.Command	= nil
TOOL.ConfigName	= ""

TOOL.ClientConVar["thickness"] = 1
TOOL.ClientConVar["ductility"] = 0

local ArmorProp_Area = CreateClientConVar( "acfarmorprop_area", 0, false, true ) -- we don't want this one to save
local ArmorProp_Ductility = CreateClientConVar("acfarmorprop_ductility", 0, false, true)
local ArmorProp_Thickness = CreateClientConVar("acfarmorprop_thickness", 1, false, true)

-- Calculates mass, armor, and health given prop area and desired ductility and thickness.
local function CalcArmor( Area, Ductility, Thickness )

	local mass = Area * ( 1 + Ductility ) ^ 0.5 * Thickness * 0.00078
	local armor = ACF_CalcArmor( Area, Ductility, mass )
	local health = (Area / ACF.Threshold) * (1 + Ductility)

	return mass, armor, health

end

if CLIENT then

	language.Add( "tool.acfarmorprop.name", "ACF Armor Properties" )
	language.Add( "tool.acfarmorprop.desc", "Sets the weight of a prop by desired armor thickness and ductility." )
	language.Add( "tool.acfarmorprop.0", "Left click to apply settings.  Right click to copy settings.  Reload to get the total mass of an object and all constrained objects." )

	function TOOL.BuildCPanel( panel )

		local Presets = vgui.Create( "ControlPresets" )
			Presets:AddConVar( "acfarmorprop_thickness" )
			Presets:AddConVar( "acfarmorprop_ductility" )
			Presets:SetPreset( "acfarmorprop" )
		panel:AddItem( Presets )

		panel:NumSlider( "Thickness", "acfarmorprop_thickness", 1, 5000 )
		panel:ControlHelp( "Set the desired armor thickness (in mm) and the mass will be adjusted accordingly." )

		panel:NumSlider( "Ductility", "acfarmorprop_ductility", -80, 80 )
		panel:ControlHelp( "Set the desired armor ductility (thickness-vs-health bias). A ductile prop can survive more damage but is penetrated more easily (slider > 0).  A non-ductile prop is brittle - hardened against penetration, but more easily shattered by bullets and explosions (slider < 0)." )

	end

	surface.CreateFont( "Torchfont", { size = 40, weight = 1000, font = "arial" } )

	-- clamp thickness if the change in ductility puts mass out of range
	cvars.AddChangeCallback( "acfarmorprop_ductility", function( _, _, value )

		local area = ArmorProp_Area:GetFloat()

		-- don't bother recalculating if we don't have a valid ent
		if area == 0 then return end

		local ductility = math.Clamp( ( tonumber( value ) or 0 ) / 100, -0.8, 0.8 )
		local thickness = math.Clamp( ArmorProp_Thickness:GetFloat(), 0.1, 5000 )
		local mass = CalcArmor( area, ductility, thickness )

		if mass > 50000 or mass < 0.1 then
			mass = math.Clamp(mass, 0.1, 50000)

			thickness = ACF_CalcArmor(area, ductility, mass)
			ArmorProp_Thickness:SetFloat(math.Clamp(thickness, 0.1, 5000))
		end
	end )

	-- clamp ductility if the change in thickness puts mass out of range
	cvars.AddChangeCallback( "acfarmorprop_thickness", function( _, _, value )

		local area = ArmorProp_Area:GetFloat()

		-- don't bother recalculating if we don't have a valid ent
		if area == 0 then return end

		local thickness = math.Clamp( tonumber( value ) or 0, 0.1, 5000 )
		local ductility = math.Clamp( ArmorProp_Ductility:GetFloat() / 100, -0.8, 0.8 )
		local mass = CalcArmor( area, ductility, thickness )

		if mass > 50000 or mass < 0.1 then
			mass = math.Clamp(mass, 0.1, 50000)

			ductility = -( 39 * area * thickness - mass * 50000 ) / ( 39 * area * thickness )
			ArmorProp_Ductility:SetFloat(math.Clamp(ductility * 100, -80, 80))
		end
	end )
end

do -- Allowing everyone to read contraptions
	local HookCall = hook.Call

	function hook.Call(Name, Gamemode, Player, Entity, Tool, ...)
		if Name == "CanTool" and Tool == "acfarmorprop" and Player:KeyPressed(IN_RELOAD) then
			return true
		end

		return HookCall(Name, Gamemode, Player, Entity, Tool, ...)
	end
end

-- Apply settings to prop and store dupe info
local function ApplySettings(_, Entity, Data)
	if CLIENT then return end
	if not Data then return end
	if not ACF_Check(Entity) then return end

	if Data.Mass then
		local PhysObj = Entity.ACF.PhysObj -- If it passed ACF_Check, then the PhysObj will always be valid
		local Mass = math.Clamp(Data.Mass, 0.1, 50000)

		PhysObj:SetMass(Mass)

		duplicator.StoreEntityModifier(Entity, "mass", { Mass = Mass })
	end

	if Data.Ductility then
		local Ductility = math.Clamp(Data.Ductility, -80, 80)

		Entity.ACF.Ductility = Ductility * 0.01

		duplicator.StoreEntityModifier(Entity, "acfsettings", { Ductility = Ductility })
	end

	ACF_Check(Entity, true) -- Forcing the entity to update its information
end
duplicator.RegisterEntityModifier("acfsettings", ApplySettings)
duplicator.RegisterEntityModifier("mass", ApplySettings)

-- Apply settings to prop
function TOOL:LeftClick( Trace )
	local Ent = Trace.Entity

	if not IsValid(Ent) then return false end
	if Ent:IsPlayer() or Ent:IsNPC() then return false end
	if CLIENT then return true end
	if not ACF_Check( Ent ) then return false end

	local ply = self:GetOwner()

	local ductility = math.Clamp( self:GetClientNumber( "ductility" ), -80, 80 )
	local thickness = math.Clamp( self:GetClientNumber( "thickness" ), 0.1, 5000 )
	local mass = CalcArmor( Ent.ACF.Area, ductility / 100, thickness )

	ApplySettings( ply, Ent, { Mass = mass, Ductility = ductility } )

	-- this invalidates the entity and forces a refresh of networked armor values
	self.AimEntity = nil

	return true
end

-- Suck settings from prop
function TOOL:RightClick(Trace)
	local Ent = Trace.Entity

	if not IsValid(Ent) then return false end
	if Ent:IsPlayer() or Ent:IsNPC() then return false end
	if CLIENT then return true end
	if not ACF_Check(Ent) then return false end

	local Player = self:GetOwner()

	Player:ConCommand("acfarmorprop_thickness " .. Ent.ACF.MaxArmour)
	Player:ConCommand("acfarmorprop_ductility " .. Ent.ACF.Ductility * 100)

	return true
end

-- Total up mass of constrained ents
function TOOL:Reload(Trace)
	local Ent = Trace.Entity

	if not IsValid(Ent) then return false end
	if Ent:IsPlayer() or Ent:IsNPC() then return false end
	if CLIENT then return true end

	local Power, Fuel, PhysNum, ParNum, ConNum, Name, OtherNum = ACF_CalcMassRatio(Ent, true)

	local Player		= self:GetOwner()
	local Total 		= Ent.acftotal
	local phystotal 	= Ent.acfphystotal
	local parenttotal 	= Total - Ent.acfphystotal
	local physratio 	= 100 * Ent.acfphystotal / Total, 1

	Player:ChatPrint("--- ACF Contraption Readout (Owner: " .. Name .. ") ---")
	Player:ChatPrint("Mass: " .. math.Round(Total, 1) .. " kg total | " ..  math.Round(phystotal, 1) .. " kg physical (" .. math.Round(physratio) .. "%) | " .. math.Round(parenttotal, 1) .. " kg parented")
	Player:ChatPrint("Mobility: " .. math.Round(Power / (Total / 1000), 1) .. " hp/ton @ " .. math.Round(Power) .. " hp | " .. math.Round(Fuel) .. " liters of fuel")
	Player:ChatPrint("Entities: " .. PhysNum + ParNum + OtherNum .. " (" .. PhysNum .. " physical, " .. ParNum .. " parented, " .. OtherNum .. " other entities) | " .. ConNum .. " constraints")

	return true
end

function TOOL:Think()

	if not SERVER then return end

	local ply = self:GetOwner()
	local Ent = ply:GetEyeTrace().Entity
	if Ent == self.AimEntity then return end

	if ACF_Check( Ent ) then

		ply:ConCommand("acfarmorprop_area " .. Ent.ACF.Area)
		ply:ConCommand("acfarmorprop_thickness " .. self:GetClientNumber("thickness")) -- Force sliders to update themselves
		self.Weapon:SetNWFloat( "WeightMass", Ent:GetPhysicsObject():GetMass() )
		self.Weapon:SetNWFloat( "HP", Ent.ACF.Health )
		self.Weapon:SetNWFloat( "Armour", Ent.ACF.Armour )
		self.Weapon:SetNWFloat( "MaxHP", Ent.ACF.MaxHealth )
		self.Weapon:SetNWFloat( "MaxArmour", Ent.ACF.MaxArmour )

	else

		ply:ConCommand( "acfarmorprop_area 0" )
		self.Weapon:SetNWFloat( "WeightMass", 0 )
		self.Weapon:SetNWFloat( "HP", 0 )
		self.Weapon:SetNWFloat( "Armour", 0 )
		self.Weapon:SetNWFloat( "MaxHP", 0 )
		self.Weapon:SetNWFloat( "MaxArmour", 0 )

	end

	self.AimEntity = Ent

end

function TOOL:DrawHUD()

	if not CLIENT then return end

	local Ent = self:GetOwner():GetEyeTrace().Entity

	if not IsValid(Ent) then return false end
	if Ent:IsPlayer() or Ent:IsNPC() then return false end

	local curmass = self.Weapon:GetNWFloat( "WeightMass" )
	local curarmor = self.Weapon:GetNWFloat( "MaxArmour" )
	local curhealth = self.Weapon:GetNWFloat( "MaxHP" )

	local area = ArmorProp_Area:GetFloat()
	local ductility = ArmorProp_Ductility:GetFloat()
	local thickness = ArmorProp_Thickness:GetFloat()

	local mass, armor, health = CalcArmor( area, ductility / 100, thickness )
	mass = math.min( mass, 50000 )

	local text = "Current:\nMass: " .. math.Round( curmass, 2 )
	text = text .. "\nArmor: " .. math.Round( curarmor, 2 )
	text = text .. "\nHealth: " .. math.Round( curhealth, 2 )
	text = text .. "\nAfter:\nMass: " .. math.Round( mass, 2 )
	text = text .. "\nArmor: " .. math.Round( armor, 2 )
	text = text .. "\nHealth: " .. math.Round( health, 2 )

	local pos = Ent:GetPos()
	AddWorldTip( nil, text, nil, pos, nil )

end

function TOOL:DrawToolScreen()

	if not CLIENT then return end

	local Health = math.Round( self.Weapon:GetNWFloat( "HP", 0 ), 2 )
	local MaxHealth = math.Round( self.Weapon:GetNWFloat( "MaxHP", 0 ), 2 )
	local Armour = math.Round( self.Weapon:GetNWFloat( "Armour", 0 ), 2 )
	local MaxArmour = math.Round( self.Weapon:GetNWFloat( "MaxArmour", 0 ), 2 )

	local HealthTxt = Health .. "/" .. MaxHealth
	local ArmourTxt = Armour .. "/" .. MaxArmour

	cam.Start2D()
		render.Clear( 0, 0, 0, 0 )

		surface.SetMaterial( Material( "models/props_combine/combine_interface_disp" ) )
		surface.SetDrawColor( color_white )
		surface.DrawTexturedRect( 0, 0, 256, 256 )
		surface.SetFont( "Torchfont" )

		-- header
		draw.SimpleTextOutlined( "ACF Stats", "Torchfont", 128, 30, Color( 224, 224, 255, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 4, color_black )

		-- armor bar
		draw.RoundedBox( 6, 10, 83, 236, 64, Color( 200, 200, 200, 255 ) )
		if Armour ~= 0 and MaxArmour ~= 0 then
			draw.RoundedBox( 6, 15, 88, Armour / MaxArmour * 226, 54, Color( 0, 0, 200, 255 ) )
		end

		draw.SimpleTextOutlined( "Armour", "Torchfont", 128, 100, Color( 224, 224, 255, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 4, color_black )
		draw.SimpleTextOutlined( ArmourTxt, "Torchfont", 128, 130, Color( 224, 224, 255, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 4, color_black )

		-- health bar
		draw.RoundedBox( 6, 10, 183, 236, 64, Color( 200, 200, 200, 255 ) )
		if Health ~= 0 and MaxHealth ~= 0 then
			draw.RoundedBox( 6, 15, 188, Health / MaxHealth * 226, 54, Color( 200, 0, 0, 255 ) )
		end

		draw.SimpleTextOutlined( "Health", "Torchfont", 128, 200, Color( 224, 224, 255, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 4, color_black )
		draw.SimpleTextOutlined( HealthTxt, "Torchfont", 128, 230, Color( 224, 224, 255, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 4, color_black )
	cam.End2D()

end
