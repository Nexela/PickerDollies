-------------------------------------------------------------------------------
--[Picker Dolly]--
-------------------------------------------------------------------------------

local Event = require('__stdlib__/stdlib/event/event').set_protected_mode(true)
local Player = require('__stdlib__/stdlib/event/player').register_events(true)
local Area = require('__stdlib__/stdlib/area/area')
local Position = require('__stdlib__/stdlib/area/position')
local Direction = require('__stdlib__/stdlib/area/direction')
local table = require('__stdlib__/stdlib/utils/table')
local interface = require('interface')

--[[
Event table returned with the event
    {
        player_index = player_index, -- The index of the player who moved the entity
        moved_entity = entity, -- The entity that was moved
        start_pos = position -- The position that the entity was moved from
    }

-- In your mods on_load and on_init, create an event handler for the dolly_moved_entity_id
-- Adding the event registration in on_load and on_init you do not have to add picker as an optional dependency

if remote.interfaces["PickerDollies"] and remote.interfaces["PickerDollies"]["dolly_moved_entity_id"] then
    script.on_event(remote.call("PickerDollies", "dolly_moved_entity_id"), function_to_update_positions)
end
--]]
Event.generate_event_name('dolly_moved')

local function play_error_sound(player)
    player.play_sound {path = 'utility/cannot_build', position = player.position, volume = 1}
end

local corners = {'left_top', 'left_bottom', 'right_top', 'right_bottom'}

local function is_blacklisted(entity, cheat_mode)
    local name = entity.name

    local cheat_types = {
        ['character'] = true,
        ['unit'] = true,
        ['unit-spawner'] = true,
        ['car'] = true
    }
    local types = {
        ['item-request-proxy'] = true,
        ['rocket-silo-rocket'] = true,
        ['resource'] = true,
        ['construction-robot'] = true,
        ['logistic-robot'] = true,
        ['rocket'] = true,
        ['tile-ghost'] = true
    }
    local names = {}

    local listed = types[entity.type] or names[name] or global.blacklist_names[name]

    if cheat_mode then
        return listed
    else
        return listed or cheat_types[entity.type]
    end
    -- return cheat_mode and listed or (listed or cheat_types[entity.type])
end

local input_to_direction = {
    ['dolly-move-north'] = defines.direction.north,
    ['dolly-move-east'] = defines.direction.east,
    ['dolly-move-south'] = defines.direction.south,
    ['dolly-move-west'] = defines.direction.west
}

local oblong_combinators = {
    ['arithmetic-combinator'] = true,
    ['decider-combinator'] = true
}

local copper_wire_types = {
    ['electric-pole'] = true,
    ['power-switch'] = true
}

local function find_resources(entity, direction, distance)
    if entity.type == 'mining-drill' then
        local area = Position(entity.position)
        area = area:expand_to_area(game.entity_prototypes[entity.name].mining_drill_radius)
        area = area:translate(direction, distance)
        local resource_name = entity.mining_target and entity.mining_target.name or nil
        return entity.surface.count_entities_filtered {area = area, type = 'resource', name = resource_name}, resource_name
    end
    return 0, {'picker-dollies.generic-ore-patch'}
end

local function get_saved_entity(player, pdata, tick)
    local selected = player.selected
    if selected then
        return selected
    elseif pdata.dolly and pdata.dolly.valid and player.mod_settings['dolly-save-entity'].value then
        if tick <= (pdata.dolly_tick or 0) + defines.time.second * 5 then
            return pdata.dolly
        else
            pdata.dolly = nil
            return
        end
    end
end

local function _get_max_wire_len(entity)
    if copper_wire_types[entity.type] then
        return entity.prototype.max_wire_distance
    elseif entity.circuit_connected_entities then
        return entity.prototype.max_circuit_wire_distance
    end
end

local function move_entity(event)
    local player, pdata = Player.get(event.player_index)
    local entity = get_saved_entity(player, pdata, event.tick)

    if entity then
        local cheat_mode = player.cheat_mode

        if not (cheat_mode or player.can_reach_entity(entity)) then
            player.create_local_flying_text {text = {'cant-reach'}, position = entity.position}
            play_error_sound(player)
            return
        end

        if is_blacklisted(entity, cheat_mode) then
            player.create_local_flying_text {text = {'picker-dollies.cant-be-teleported', entity.localised_name}, position = entity.position}
            play_error_sound(player)
            return
        end

        local entity_force = entity.force
        if not (cheat_mode or entity_force == player.force) then
            player.create_local_flying_text {text = {'picker-dollies.wrong-force', entity.localised_name}, position = entity.position}
            play_error_sound(player)
            return
        end

        -- Direction to move the source
        local direction = event.direction or input_to_direction[event.input_name]
        -- Distance to move the source, defaults to 1
        local distance = event.distance or 1
        -- Where we started from in case we have to return it
        local start_pos = Position(event.start_pos or entity.position)
        -- Where we want to go too
        local target_pos = start_pos:translate(direction, distance)
        -- Target selection box location
        local target_box = Area(entity.selection_box):translate(direction, distance):corners()
        -- Wire distance for the source
        local wire_distance = _get_max_wire_len(entity)
        -- The entities direction
        local entity_direction = entity.direction
        -- Resources for mining drills
        local resource_count, resource_name = find_resources(entity, direction, distance)
        local surface = entity.surface

        -- Returns true if the wires can't reach
        local function _cant_reach(neighbours)
            return table.any(
                neighbours,
                function(neighbour)
                    if entity ~= neighbour then
                        if entity.type == 'electric-pole' and neighbour.type == 'electric-pole' then
                            local dist = Position(neighbour.position):distance(target_pos)
                            return dist > entity.prototype.max_wire_distance or dist > neighbour.prototype.max_wire_distance
                        else
                            local neighbour_box = Area(neighbour.selection_box):corners()
                            local shortest_distance = math.min(wire_distance, _get_max_wire_len(neighbour))
                            local reach = shortest_distance + 1
                            for _, target_corner in pairs(corners) do
                                for _, neighbour_corner in pairs(corners) do
                                    reach = math.min(reach, target_box[target_corner]:distance(neighbour_box[neighbour_corner]))
                                end
                            end
                            return reach > shortest_distance
                        end
                    end
                end
            )
        end

        -- Save fluid boxes here
        local fluidbox = {}
        for i = 1, #entity.fluidbox do
            fluidbox[i] = entity.fluidbox[i]
        end

        local out_of_the_way = start_pos:translate(Direction.opposite_direction(direction), event.tiles_away or 20)
        local updateable_entities = surface.find_entities_filtered {area = target_box:expand(32), force = entity_force}
        local items_on_ground = surface.find_entities_filtered {type = 'item-entity', area = target_box}
        local proxy = surface.find_entities_filtered {name = 'item-request-proxy', position = start_pos, force = entity_force}[1]

        -- Update everything after teleporting
        local function teleport_and_update(pos, raise, reason)
            if entity.last_user then
                entity.last_user = player
            end

            entity.teleport(pos)

            -- Insert fluid back here.
            for i = 1, #fluidbox do
                entity.fluidbox[i] = fluidbox[i]
            end

            -- Mine or move out of the way any items on the ground
            table.each(
                items_on_ground,
                function(item)
                    if item.valid and not player.mine_entity(item) then
                        item.teleport(surface.find_non_colliding_position('item-on-ground', entity.position, 0, .20))
                    end
                end
            )

            -- Move the proxy to the correct position
            if proxy and proxy.valid then
                proxy.teleport(entity.position)
            end

            -- Update all connections
            table.each(
                updateable_entities,
                function(updateable_entity)
                    updateable_entity.update_connections()
                end
            )

            if raise then
                script.raise_event(Event.generate_event_name('dolly_moved'), {player_index = player.index, moved_entity = entity, start_pos = start_pos})
            else
                play_error_sound(player)
                player.create_local_flying_text {text = reason, position = pos}
            end
            return raise
        end

        -- Remove the fluids because geez
        if entity.get_fluid_count() > 0 then
            entity.clear_fluid_inside()
        end

        -- Teleport the entity out of the way.
        if not entity.teleport(out_of_the_way) then
            -- Entity can't be teleported
            -- API request: can_be_teleported, This logic is really too high up the chain!
            player.create_local_flying_text {text = {'picker-dollies.cant-be-teleported', entity.localised_name}, position = entity.position}
            play_error_sound(player)
            return
        end

        if proxy and proxy.proxy_target == entity then
            proxy.teleport(entity.position)
        end

        table.each(
            items_on_ground,
            function(item)
                item.teleport(out_of_the_way)
            end
        )

        pdata.dolly = entity
        pdata.dolly_tick = event.tick

        entity.direction = entity_direction
        local ghost_name = entity.name == 'entity-ghost' and entity.ghost_name
        local params = {name = ghost_name or entity.name, position = target_pos, direction = entity_direction, force = entity_force}
        if entity.surface.can_place_entity(params) and not entity.surface.find_entity('entity-ghost', target_pos) then
            -- Entity is placeable, check for wire distances
            if entity.circuit_connected_entities then
                if copper_wire_types[entity.type] and not table.any(entity.neighbours, _cant_reach) then
                    return teleport_and_update(target_pos, true)
                elseif not copper_wire_types[entity.type] and not table.any(entity.circuit_connected_entities, _cant_reach) then
                    if entity.type == 'mining-drill' and resource_count == 0 then
                        return teleport_and_update(start_pos, false, {'picker-dollies.off-ore-patch', entity.localised_name, resource_name})
                    else
                        return teleport_and_update(target_pos, true)
                    end
                else
                    return teleport_and_update(start_pos, false, {'picker-dollies.wires-maxed'})
                end
            else -- No special cases
                return teleport_and_update(target_pos, true)
            end
        else -- Entity can't fit, restore position.
            return teleport_and_update(start_pos, false, {'picker-dollies.no-room', entity.localised_name})
        end
    end
end
Event.register({'dolly-move-north', 'dolly-move-east', 'dolly-move-south', 'dolly-move-west'}, move_entity)

local function try_rotate_combinator(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read and not player.cursor_ghost then
        local entity = get_saved_entity(player, pdata, event.tick)

        if entity and oblong_combinators[entity.name] then
            if player.cheat_mode or player.can_reach_entity(entity) then
                pdata.dolly = entity
                local diags = {
                    [defines.direction.north] = defines.direction.northeast,
                    [defines.direction.south] = defines.direction.northeast,
                    [defines.direction.west] = defines.direction.southwest,
                    [defines.direction.east] = defines.direction.southwest
                }
                event.start_pos = entity.position
                event.start_direction = entity.direction
                event.distance = .5
                entity.direction = entity.direction == 6 and 0 or entity.direction + 2
                event.direction = diags[entity.direction]
                if not move_entity(event) then
                    entity.direction = event.start_direction
                end
            end
        end
    end
end
Event.register('dolly-rotate-rectangle', try_rotate_combinator)

local function rotate_saved_dolly(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read and not player.cursor_ghost and not player.selected then
        local entity = get_saved_entity(player, pdata, event.tick)

        if entity and entity.supports_direction then
            pdata.dolly = entity
            entity.rotate {reverse = event.input_name == 'dolly-rotate-saved-reverse', by_player = player}
        end
    end
end
Event.register({'dolly-rotate-saved', 'dolly-rotate-saved-reverse'}, rotate_saved_dolly)

local function create_global_blacklist()
    global.blacklist_names = {}
end
Event.register(Event.core_events.on_init, create_global_blacklist)

local function update_blacklist()
    global.blacklist_names = global.blacklist_names or {}
    for name in pairs(global.blacklist_names) do
        if not game.entity_prototypes[name] then
            global.blacklist_names[name] = nil
        end
    end
end
Event.register(Event.core_events.on_configuration_changed, update_blacklist)

remote.add_interface(script.mod_name, interface)
