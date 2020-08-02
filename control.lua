-------------------------------------------------------------------------------
--[Picker Dolly]--
-------------------------------------------------------------------------------

local Event = require('__stdlib__/stdlib/event/event').set_protected_mode(true)
local Player = require('__stdlib__/stdlib/event/player').register_events(true)
local Area = require('__stdlib__/stdlib/area/area')
local Position = require('__stdlib__/stdlib/area/position')
local Direction = require('__stdlib__/stdlib/area/direction')
local interface = require('__stdlib__/stdlib/scripts/interface')
local table = require('__stdlib__/stdlib/utils/table')

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
interface['dolly_moved_entity_id'] = function()
    return Event.generate_event_name('dolly_moved')
end
interface['add_blacklist_name'] = function(entity_name, silent)
    global.blacklist_names = global.blacklist_names or {}
    if game.entity_prototypes[entity_name] and not global.blacklist_names[entity_name] then
        global.blacklist_names[entity_name] = true
        if not silent then
            game.print('Picker Dollies added ' .. entity_name .. ' to the blacklist.')
        end
        return true
    else
        if not silent then
            game.print('Picker Dollies could not add ' .. entity_name .. ' to the blacklist.')
            game.print('Entity name does not exist or is already blacklisted.')
        end
        return false
    end
end
interface['remove_blacklist_name'] = function(entity_name, silent)
    global.blacklist_names = global.blacklist_names or {}
    global.blacklist_names[entity_name] = nil
    if not silent then
        game.print('Picker Dollies removed ' .. entity_name .. ' from the blacklist.')
    end
    return true
end
interface['get_blacklist_names'] = function(entity_name, silent)
    global.blacklist_names = global.blacklist_names or {}
    if entity_name then
        local key = global.blacklist_names[entity_name]
        if not silent then
            local is = key and ' is ' or ' is not '
            game.print('Picker Dollies: ' .. entity_name .. is .. 'blacklisted.')
        end
        return global.blacklist_names[entity_name]
    else
        local keys = table.keys(global.blacklist_names)
        if not silent then
            game.print('Picker Dollies: blacklisted names = ' .. table.concat(keys, ', '))
        end
        return keys
    end
end

local function play_sound(player)
    player.play_sound{path = 'utility/cannot_build', position = player.position, volume = 1}
end

local function is_blacklisted(entity)
    local name = entity.name
    local types = {
        ['item-request-proxy'] = true,
        ['rocket-silo-rocket'] = true,
        ['player'] = true,
        ['resource'] = true,
        ['car'] = true,
        ['construction-robot'] = true,
        ['logistic-robot'] = true,
        ['rocket'] = true,
        ['tile-ghost'] = true
    }
    local names = {}
    return types[entity.type] or names[name] or global.blacklist_names[name]
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

local wire_distance_types = {
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
    if selected and selected.force == player.force then
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

local function _get_distance(entity)
    if wire_distance_types[entity.type] then
        return entity.prototype.max_wire_distance
    elseif entity.circuit_connected_entities then
        return entity.prototype.max_circuit_wire_distance
    end
end

local function move_entity(event)
    local player, pdata = Player.get(event.player_index)
    local entity = get_saved_entity(player, pdata, event.tick)

    if entity then
        if player.can_reach_entity(entity) then
            if not is_blacklisted(entity) then
                --Direction to move the source
                local direction = event.direction or input_to_direction[event.input_name]
                --Distance to move the source, defaults to 1
                local distance = event.distance or 1
                --Where we started from in case we have to return it
                local start_pos = Position(event.start_pos or entity.position)
                --Where we want to go too
                local target_pos = start_pos:translate(direction, distance)
                --Wire distance for the source
                local source_distance = _get_distance(entity)
                --The entities direction
                local entity_direction = entity.direction
                --Resources for mining drills
                local resource_count, resource_name = find_resources(entity, direction, distance)

                --returns true if the wires can't reach
                local _cant_reach = function(neighbours)
                    return table.any(
                        neighbours,
                        function(neighbour)
                            local dist = Position(neighbour.position):distance(target_pos)
                            return entity ~= neighbour and (dist > source_distance or dist > _get_distance(neighbour))
                        end
                    )
                end

                -- Save fluid boxes here
                local fluidbox = {}
                for i = 1, #entity.fluidbox do
                    fluidbox[i] = entity.fluidbox[i]
                end

                local out_of_the_way = start_pos:translate(Direction.opposite_direction(direction), event.tiles_away or 20)

                local bounding_box = Area(entity.bounding_box):non_zero()

                local updateable_entities = entity.surface.find_entities_filtered {area = bounding_box:expand(32), force = entity.force}
                local items_on_ground = entity.surface.find_entities_filtered {type = 'item-entity', area = bounding_box:translate(direction, distance)}
                local proxy = entity.surface.find_entities_filtered {name = 'item-request-proxy', position = start_pos, force = player.force}[1]

                --Update everything after teleporting
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
                                item.teleport(entity.surface.find_non_colliding_position('item-on-ground', entity.position, 0, .20))
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
                        play_sound(player)
                        player.create_local_flying_text {text = reason, position = pos}
                    end
                    return raise
                end

                -- Remove the fluids because geez
                if entity.get_fluid_count() > 0 then
                    entity.clear_fluid_inside()
                end

                -- Teleport the entity out of the way.
                if entity.teleport(out_of_the_way) then
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
                    local params = {name = ghost_name or entity.name, position = target_pos, direction = entity_direction, force = entity.force}
                    if entity.surface.can_place_entity(params) and not entity.surface.find_entity('entity-ghost', target_pos) then
                        -- Entity is placeable, check for wire distances
                        if entity.circuit_connected_entities then
                            if wire_distance_types[entity.type] and not table.any(entity.neighbours, _cant_reach) then
                                return teleport_and_update(target_pos, true)
                            elseif not wire_distance_types[entity.type] and not table.any(entity.circuit_connected_entities, _cant_reach) then
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
                else -- Entity can't be teleported
                    -- API request: can_be_teleported
                    -- This logic is really too high up the chain!
                    player.create_local_flying_text {text = {'picker-dollies.cant-be-teleported', entity.localised_name}, position = entity.position}
                    play_sound(player)
                end
            else -- Entity is blacklisted
                player.create_local_flying_text {text = {'picker-dollies.cant-be-teleported', entity.localised_name}, position = entity.position}
                play_sound(player)
            end
        else -- Entity can't be reached
            player.create_local_flying_text {text = {'cant-reach'}, position = entity.position}
            play_sound(player)
        end
    end
end
Event.register({'dolly-move-north', 'dolly-move-east', 'dolly-move-south', 'dolly-move-west'}, move_entity)

local function try_rotate_combinator(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read and not player.cursor_ghost then
        local entity = get_saved_entity(player, pdata, event.tick)

        if entity and oblong_combinators[entity.name] then
            if player.can_reach_entity(entity) then
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

--   "name": "ghost-pipette",
--   "title": "Ghost Pipette",
--   "author": "blueblue",
--   "contact": "deep.blueeee@yahoo.de",
--   "description": "Adds ghost-related functionality like pipette, rotation, selection.",
local function rotate_ghost(event)
    local player, pdata = Player.get(event.player_index)
    if not player.cursor_stack.valid_for_read and not player.cursor_ghost then
        local ghost = get_saved_entity(player, pdata, event.tick)
        if ghost and ghost.name == 'entity-ghost' then
            local left = event.input_name == 'picker-rotate-ghost-reverse'
            local prototype = game.entity_prototypes[ghost.ghost_name]
            local value = prototype.has_flag('building-direction-8-way') and 1 or 2

            if prototype.type == 'offshore-pump' then
                return
            end

            if value ~= 1 then
                local box = prototype.collision_box
                local lt = box.left_top
                local rb = box.right_bottom
                local dx = rb.x - lt.x
                local dy = rb.y - lt.y
                if dx ~= dy and dx <= 2 and dy <= 2 then
                    value = 4
                elseif dx ~= dy then
                    return
                end
            end
            ghost.direction = (ghost.direction + ((left and -value) or value)) % 8
            pdata.dolly = ghost
        end
    end
end
Event.register({'dolly-rotate-ghost', 'dolly-rotate-ghost-reverse'}, rotate_ghost)

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
