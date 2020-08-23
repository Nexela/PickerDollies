local interface = require('__stdlib__/stdlib/scripts/interface')
local Event = require('__stdlib__/stdlib/event/event')
local table = require('__stdlib__/stdlib/utils/table')

interface['dolly_moved_entity_id'] = function()
    return Event.generate_event_name('dolly_moved')
end

interface['add_blacklist_name'] = function(entity_name, silent)
    global.blacklist_names = global.blacklist_names or {}
    if game.entity_prototypes[entity_name] and not global.blacklist_names[entity_name] then
        global.blacklist_names[entity_name] = true
        if not silent then
            game.print('Picker Dollies added ' .. entity_name .. ' to the blacklist.')
            log('Picker Dollies added ' .. entity_name .. ' to the blacklist.')
        end
        return true
    else
        if not silent then
            game.print('Picker Dollies could not add ' .. entity_name .. ' to the blacklist.')
            game.print('Entity name does not exist or is already blacklisted.')
            log('Picker Dollies could not add ' .. entity_name .. ' to the blacklist.')
        end
        return false
    end
end

interface['remove_blacklist_name'] = function(entity_name, silent)
    global.blacklist_names = global.blacklist_names or {}
    global.blacklist_names[entity_name] = nil
    if not silent then
        game.print('Picker Dollies removed ' .. entity_name .. ' from the blacklist.')
        log('Picker Dollies removed ' .. entity_name .. ' from the blacklist.')
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
            log('Picker Dollies: ' .. entity_name .. is .. 'blacklisted.')
        end
        return global.blacklist_names[entity_name]
    else
        local keys = table.keys(global.blacklist_names)
        if not silent then
            game.print('Picker Dollies: blacklisted names = ' .. table.concat(keys, ', '))
            log('Picker Dollies: blacklisted names = ' .. table.concat(keys, ', '))
        end
        return keys
    end
end

return interface
