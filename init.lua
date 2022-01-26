
if not minetest.settings then
	error("Mod playeranim requires Minetest 0.4.16 or newer")
end

playeranim = {}

local ANIMATION_SPEED = tonumber(minetest.settings:get("playeranim.animation_speed")) or 2.4
local ANIMATION_SPEED_SNEAK = tonumber(minetest.settings:get("playeranim.animation_speed_sneak")) or 0.8
local BODY_ROTATION_DELAY = math.max(math.floor(tonumber(minetest.settings:get("playeranim.body_rotation_delay")) or 7), 1)
local BODY_X_ROTATION_SNEAK = tonumber(minetest.settings:get("playeranim.body_x_rotation_sneak")) or 6.0
local ROTATE_ON_SNEAK = true

local BONE_POSITION, BONE_ROTATION = (function()
	local modname = minetest.get_current_modname()
	local modpath = minetest.get_modpath(modname)
	return dofile(modpath .. "/model.lua")
end)()

local vector_add, vector_equals = vector.add, vector.equals
local math_sin, math_cos, math_pi, math_deg = math.sin, math.cos, math.pi, math.deg
local table_remove = table.remove

local get_animation = minetest.global_exists("player_api")
	and player_api.get_animation or default.player_get_animation
if not get_animation then
	error("player_api.get_animation or default.player_get_animation is not found")
end

-- stop player_api from messing stuff up (since 5.3)
if minetest.global_exists("player_api") then
	minetest.register_on_mods_loaded(function()
		for _, model in pairs(player_api.registered_models) do
			if model.animations then
				for _, animation in pairs(model.animations) do
					animation.x = 0
					animation.y = 0
				end
			end
		end
	end)

	minetest.register_on_joinplayer(function(player)
		player:set_local_animation(nil, nil, nil, nil, 0)
	end)
end

local function get_pitch_deg(player)
	return math_deg(player:get_look_vertical())
end

local players_animation_data = setmetatable({}, {
	__index = {
		init_player = function(self, player)
			self[player] = {
				time = 0,
				yaw_history = {},
				bone_rotations = {},
				bone_positions = {},
				static_rotations = {},
				static_positions = {},
				previous_animations = {},
				assigned_animations = {},
				animation_speed = nil
			}
		end,

		-- time
		get_time = function(self, player)
			return self[player].time
		end,

		increment_time = function(self, player, dtime)
			self[player].time = self:get_time(player) + dtime
		end,

		reset_time = function(self, player)
			self[player].time = 0
		end,

		-- yaw_history
		get_yaw_history = function(self, player)
			return self[player].yaw_history -- Return mutable reference
		end,

		add_yaw_to_history = function(self, player)
			local yaw = player:get_look_horizontal()
			local history = self:get_yaw_history(player)
			history[#history + 1] = yaw
		end,

		clear_yaw_history = function(self, player)
			if #self[player].yaw_history > 0 then
				self[player].yaw_history = {}
			end
		end,

		-- bone_rotations
		get_bone_rotation = function(self, player, bone)
			return self[player].bone_rotations[bone]
		end,

		set_bone_rotation = function(self, player, bone, rotation)
			self[player].bone_rotations[bone] = rotation
		end,

		-- bone_positions
		get_bone_position = function(self, player, bone)
			return self[player].bone_positions[bone]
		end,

		set_bone_position = function(self, player, bone, position)
			self[player].bone_positions[bone] = position
		end,

		-- static_rotations
		get_static_rotations = function(self, player)
			return self[player].static_rotations
		end,

		set_static_rotations = function(self, player, rotations)
			self[player].static_rotations = rotations
		end,

		-- static_positions
		get_static_positions = function(self, player)
			return self[player].static_positions
		end,

		set_static_positions = function(self, player, positions)
			self[player].static_positions = positions
		end,

		-- previous_animations
		get_previous_animations = function(self, player)
			return self[player].previous_animations
		end,

		set_previous_animations = function(self, player, animations)
			self[player].previous_animations = animations
		end,

		-- assigned_animations
		get_assigned_animations = function(self, player)
			return self[player].assigned_animations
		end,

		assign_animation = function(self, player, animation)
			self[player].assigned_animations[animation] = true
		end,

		unassign_animation = function(self, player, animation)
			self[player].assigned_animations[animation] = nil
		end,

		-- animation_speed
		get_animation_speed = function(self, player)
			return self[player].animation_speed
		end,
		set_animation_speed = function(self, player, speed)
			self[player].animation_speed = speed
		end,
	}
})

minetest.register_on_joinplayer(function(player)
	players_animation_data:init_player(player)
end)

local function rotate_bone(player, bone, rotation, position)
	local previous_rotation = players_animation_data:get_bone_rotation(player, bone)
	local previous_position = players_animation_data:get_bone_position(player, bone)

	if not previous_rotation
	or not previous_position
	or not vector_equals(rotation, previous_rotation)
	or not vector_equals(position, previous_position)
	then
		player:set_bone_position(bone, position, rotation)
		players_animation_data:set_bone_rotation(player, bone, rotation)
		players_animation_data:set_bone_position(player, bone, position)
	end
end

-- Bone alias
local BODY = "Body"
local HEAD = "Head"
local CAPE = "Cape"
local LARM = "Arm_Left"
local RARM = "Arm_Right"
local LLEG = "Leg_Left"
local RLEG = "Leg_Right"

local ANIMATIONS = {}
local ORDERED_STATIC_ANIMATIONS = {}
local ORDERED_MOVING_ANIMATIONS = {}

local function update_reference_caches()
	ORDERED_STATIC_ANIMATIONS = {}
	ORDERED_MOVING_ANIMATIONS = {}

	local ordered_static = {}
	local ordered_moving = {}
	for animation, config in pairs(ANIMATIONS) do
		if config.options.moving then
			table.insert(ordered_moving, { order=config.options.order or 0, name=animation})
		else
			table.insert(ordered_static, { order=config.options.order or 0, name=animation})
		end
	end

	table.sort(ordered_static, function (a,b) return a.order < b.order end)
	for i,animation in ipairs(ordered_static) do
		table.insert(ORDERED_STATIC_ANIMATIONS, animation.name)
	end

	table.sort(ordered_moving, function (a,b) return a.order < b.order end)
	for i,animation in ipairs(ordered_moving) do
		table.insert(ORDERED_MOVING_ANIMATIONS, animation.name)
	end
end

function playeranim.register_animation(name, options, apply)
	if type(options) ~= 'table' then options = {} end
	ANIMATIONS[name] = {
		apply=apply,
		options = options
	}
	update_reference_caches()
end
playeranim.bones = {
	BODY = BODY,
	HEAD = HEAD,
	CAPE = CAPE,
	LARM = LARM,
	RARM = RARM,
	LLEG = LLEG,
	RLEG = RLEG
}
function playeranim.assign_animation (player, animation)
	 return players_animation_data:assign_animation(player, animation)
end
function playeranim.unassign_animation (player, animation)
	 return players_animation_data:unassign_animation(player, animation)
end
function playeranim.set_animation_speed(player, speed)
	 return players_animation_data:set_animation_speed(player, speed)
end
function playeranim.set_rotate_on_sneak(newval)
	ROTATE_ON_SNEAK = newval
end

playeranim.register_animation("stand", {looking=true,facing=true})

playeranim.register_animation("lay", nil, function(player, _time)
	anim.rotations[BODY] = vector.add(anim.rotations[BODY], anim.rotations.body_lay)
	anim.positions[BODY] = vector.add(anim.positions[BODY], anim.positions.body_lay)
end)

playeranim.register_animation("sit", {looking=true}, function(player, _time, anim)
	anim.rotations[LLEG].x = anim.rotations[LLEG].x+90
	anim.rotations[RLEG].x = anim.rotations[RLEG].x+90
	anim.rotations[BODY] = vector.add(anim.rotations[BODY], anim.rotations.body_sit)
	anim.positions[BODY] = vector.add(anim.positions[BODY], anim.positions.body_sit)
end)

playeranim.register_animation("walk", {moving=true,looking=true,facing=true}, function(player, time, anim)

	local sin = math_sin(time * anim.speed * math_pi)

	anim.rotations[CAPE].x = anim.rotations[CAPE].x+(-35 * sin - 35)
	anim.rotations[LARM].x = anim.rotations[LARM].x+(-55 * sin)
	anim.rotations[LLEG].x = anim.rotations[LLEG].x+( 55 * sin)
	anim.rotations[RLEG].x = anim.rotations[RLEG].x+(-55 * sin)

	if not anim.current_animations.mine then
		anim.rotations[RARM].x = anim.rotations[RARM].x+(55 * sin)
	end
end)

playeranim.register_animation("mine", {moving=true}, function(player, time, anim)

	local cape_sin = math_sin(time * anim.speed * math_pi)
	local rarm_sin = math_sin(2 * time * anim.speed * math_pi)
	local rarm_cos = -math_cos(2 * time * anim.speed * math_pi)
	local pitch = 90 - get_pitch_deg(player)

	anim.rotations[CAPE].x = anim.rotations[CAPE].x+(-5  * cape_sin - 5)
	anim.rotations[RARM].x = anim.rotations[RARM].x+( 10 * rarm_sin + pitch)
	anim.rotations[RARM].y = anim.rotations[RARM].y+( 10 * rarm_cos)
end)

local function rotate_head(player, anim)
	local head_x_rotation = -get_pitch_deg(player)
	anim.rotations[HEAD].x = anim.rotations[HEAD].x+head_x_rotation
end

local function rotate_body(player, anim)
	local body_x_rotation = (function()
		local sneak = player:get_player_control().sneak
		return sneak and ROTATE_ON_SNEAK and BODY_X_ROTATION_SNEAK or 0
	end)()

	local body_y_rotation = (function()
		local yaw_history = players_animation_data:get_yaw_history(player)
		if #yaw_history > BODY_ROTATION_DELAY then
			local body_yaw = table_remove(yaw_history, 1)
			local player_yaw = player:get_look_horizontal()
			return math_deg(player_yaw - body_yaw)
		end
		return 0
	end)()

	anim.rotations[BODY].x = anim.rotations[BODY].x+body_x_rotation
	anim.rotations[BODY].y = anim.rotations[BODY].y+body_y_rotation
	anim.rotations[HEAD].y = anim.rotations[HEAD].y-body_y_rotation
end

local function get_animation_speed(player)
	local assigned_speed = players_animation_data:get_animation_speed(player)
	if assigned_speed then
		return assigned_speed
	end
	if player:get_player_control().sneak then
		return ANIMATION_SPEED_SNEAK
	end
	return ANIMATION_SPEED
end

local function static_animations_changed(previous_animations, current_animations)
	for animation in pairs(previous_animations) do
		if not ANIMATIONS[animation].options.moving and not current_animations[animation] then
			return true
		end
	end
	for animation in pairs(current_animations) do
		if not ANIMATIONS[animation].options.moving and not previous_animations[animation] then
			return true
		end
	end
	return false
end

local function any_animation_has_property(animations, property)
	for animation in pairs(animations) do
		if ANIMATIONS[animation] and ANIMATIONS[animation].options[property] then
			return true
		end
	end
	return false
end

local function animate_player(player, dtime)
	local animation = get_animation(player).animation

	-- Combine manually set animations and system defined animations
	local animations = table.copy(players_animation_data:get_assigned_animations(player))
	if animation == "walk_mine" then
		animations.walk = true
		animations.mine = true
	else
		animations[animation] = true
	end

	-- Set animation

	local animation_speed = get_animation_speed(player)

	local moving_animation = any_animation_has_property(animations, 'moving')
	local facing_animation = any_animation_has_property(animations, 'facing')
	local looking_animation = any_animation_has_property(animations, 'looking')

	-- Increment animation time
	if moving_animation then
		players_animation_data:increment_time(player, dtime)
	else
		players_animation_data:reset_time(player)
	end

	-- Yaw history
	if facing_animation then
		players_animation_data:add_yaw_to_history(player)
	else
		players_animation_data:clear_yaw_history(player)
	end

	local previous_animations = players_animation_data:get_previous_animations(player)
	local changes = false

	local time = players_animation_data:get_time(player)

	-- Apply any static animations to the base if they have changed, retrieve them if not
	local rotations
	local positions
	if static_animations_changed(previous_animations, animations) then
		rotations = table.copy(BONE_ROTATION.default)
		positions = table.copy(BONE_POSITION.default)
		for _,animation in ipairs(ORDERED_STATIC_ANIMATIONS) do
			if animations[animation] then
				local apply = ANIMATIONS[animation] and ANIMATIONS[animation].apply
				if apply then
					apply(player, time, {
						rotations = rotations,
						positions = positions,
						current_animations = animations,
						previous_animations = previous_animations,
						speed = animation_speed
					})
				end
			end
		end
		players_animation_data:set_static_rotations(player, table.copy(rotations))
		players_animation_data:set_static_positions(player, table.copy(positions))
		changes = true
	else
		rotations = table.copy(players_animation_data:get_static_rotations(player))
		positions = table.copy(players_animation_data:get_static_positions(player))
	end

	-- Apply any animations that are moving
	for _,animation in ipairs(ORDERED_MOVING_ANIMATIONS) do
		if animations[animation] then
			if not previous_animations[animation] then
				changes = true
			end
			local apply = ANIMATIONS[animation] and ANIMATIONS[animation].apply
			if apply then
				apply(player, time, {
					rotations = rotations,
					positions = positions,
					current_animations = animations,
					previous_animations = previous_animations,
					speed = animation_speed
				})
			end
		end
	end

	-- Head looks around
	if looking_animation then
		rotate_head(player, {
			rotations = rotations,
			positions = positions,
			current_animations = animations,
			previous_animations = previous_animations,
			speed = animation_speed
		})
	end

	-- Body follows head
	if facing_animation then
		rotate_body(player, {
			rotations = rotations,
			positions = positions,
			current_animations = animations,
			previous_animations = previous_animations,
			speed = animation_speed
		})
	end

	for name, bone in pairs(playeranim.bones) do
		rotate_bone(player, bone, rotations[bone], positions[bone])
	end
	if changes then
		players_animation_data:set_previous_animations(player, animations)
	end
end

local minetest_get_connected_players = minetest.get_connected_players
minetest.register_globalstep(function(dtime)
	for _, player in ipairs(minetest_get_connected_players()) do
		animate_player(player, dtime)
	end
end)
