local flib_bounding_box = require("__flib__/bounding-box")
local flib_position = require("__flib__/position")
local flib_queue = require("__flib__/queue")

--- @alias FlowDirection "input"|"output"|"input-output"
--- @alias FluidSystemID uint
--- @alias PlayerIndex uint

--- @class ConnectionData
--- @field position MapPosition
--- @field connection_index uint
--- @field fluidbox_index uint

--- @class EntityData
--- @field connections table<FluidSystemID, RenderObjectID[]>
--- @field entity LuaEntity
--- @field fluidbox LuaFluidBox
--- @field shape RenderObjectID?
--- @field pending_connections ConnectionData[]
--- @field unit_number UnitNumber
--- @class Iterator
--- @field entities table<UnitNumber, EntityData>
--- @field in_overlay boolean
--- @field player_index PlayerIndex
--- @field queue Queue<LuaEntity>
--- @field systems table<FluidSystemID, Color>

--- @param starting_entity LuaEntity
--- @param player_index PlayerIndex
--- @param in_overlay boolean
local function request(starting_entity, player_index, in_overlay)
  if not global.iterator then
    return
  end

  local iterator = global.iterator[player_index]
  if not iterator then
    --- @type Iterator
    iterator = {
      entities = {},
      in_overlay = in_overlay,
      player_index = player_index,
      queue = flib_queue.new(),
      systems = {},
    }
  end

  local entity_data = iterator.entities[
    starting_entity.unit_number --[[@as uint]]
  ]
  local to_iterate = entity_data and entity_data.connections or {}
  local fluidbox = starting_entity.fluidbox
  for i = 1, #fluidbox do
    --- @cast i uint
    local id = fluidbox.get_fluid_system_id(i)
    if not id then
      goto continue
    end

    local system = iterator.systems[id]
    if system and not to_iterate[id] then
      to_iterate[id] = {}
      goto continue
    end

    -- TODO: Handle when there's no fluid in the system
    local color = { r = 0.3, g = 0.3, b = 0.3 }
    local contents = fluidbox.get_fluid_system_contents(i)
    if contents and next(contents) then
      color = global.fluid_colors[next(contents)]
    end

    iterator.systems[id] = color

    should_iterate = true

    ::continue::
  end

  if should_iterate then
    flib_queue.push_back(iterator.queue, starting_entity)
    global.iterator[player_index] = iterator
  end
end

--- Assumes that the positions are in exact cardinals.
--- @param from MapPosition
--- @param to MapPosition
--- @return defines.direction
local function get_cardinal_direction(from, to)
  if from.y > to.y then
    return defines.direction.north
  elseif from.x < to.x then
    return defines.direction.east
  elseif from.y < to.y then
    return defines.direction.south
  else
    return defines.direction.west
  end
end

local layers = {
  arrow = "195",
  line = "194",
  underground = "193",
  entity = "192",
}

local pipe_types = {
  ["infinity-pipe"] = true,
  ["pipe-to-ground"] = true,
  ["pipe"] = true,
}

local encoded_directions = {
  [defines.direction.north] = 1,
  [defines.direction.east] = 2,
  [defines.direction.south] = 4,
  [defines.direction.west] = 8,
}

--- @type Color
local default_color = { r = 0.32, g = 0.32, b = 0.32, a = 0.4 }

--- @param iterator Iterator
--- @param entity_data EntityData
local function draw_entity(iterator, entity_data)
  local complex_type = not pipe_types[entity_data.entity.type]
  local fluidbox = entity_data.fluidbox
  if complex_type then
    local box = flib_bounding_box.resize(entity_data.entity.selection_box, -0.1)
    entity_data.shape = rendering.draw_sprite({
      sprite = "pv-entity-box",
      tint = default_color,
      x_scale = flib_bounding_box.width(box),
      y_scale = flib_bounding_box.height(box),
      render_layer = layers.entity,
      target = entity_data.entity.position,
      surface = entity_data.entity.surface_index,
      players = { iterator.player_index },
    })
  else
    local box = flib_bounding_box.ceil(entity_data.entity.selection_box)
    entity_data.shape = rendering.draw_sprite({
      sprite = "pv-pipe-connections-0",
      tint = default_color,
      x_scale = flib_bounding_box.width(box),
      y_scale = flib_bounding_box.height(box),
      render_layer = layers.line,
      target = entity_data.entity.position,
      surface = entity_data.entity.surface_index,
      players = { iterator.player_index },
    })
  end
  --- @type Color?
  local shape_color
  local highest_id = 0
  local encoded_connections = 0
  for fluidbox_index = 1, #fluidbox do
    --- @cast fluidbox_index uint
    local id = fluidbox.get_fluid_system_id(fluidbox_index)
    if not id then
      goto continue
    end
    local color = iterator.systems[id]
    if not color then
      goto continue
    end
    if id > highest_id then
      shape_color = color
      highest_id = id
    end
    local shapes = entity_data.connections[id]
    if not shapes then
      shapes = {}
      entity_data.connections[id] = shapes
    end
    local pipe_connections = fluidbox.get_pipe_connections(fluidbox_index)
    for connection_index = 1, #pipe_connections do
      --- @cast connection_index uint
      local connection = pipe_connections[connection_index]
      local direction = get_cardinal_direction(connection.position, connection.target_position)

      if not connection.target then
        goto inner_continue
      end

      local boundary_position = {
        x = connection.position.x + (connection.target_position.x - connection.position.x) / 2,
        y = connection.position.y + (connection.target_position.y - connection.position.y) / 2,
      }

      if complex_type then
        if connection.flow_direction == "input" then
          direction = (direction + 4) % 8 -- Opposite
        end
        local sprite = "pv-fluid-arrow-" .. connection.flow_direction
        if connection.flow_direction ~= "input-output" and not pipe_types[connection.target.owner.type] then
          sprite = "pv-fluid-arrow"
        end
        shapes[#shapes + 1] = rendering.draw_sprite({
          sprite = sprite,
          tint = color,
          render_layer = layers.arrow,
          orientation = direction / 8,
          target = boundary_position,
          surface = entity_data.entity.surface_index,
          players = { iterator.player_index },
        })
      else
        encoded_connections = bit32.bor(encoded_connections, encoded_directions[direction])
      end

      if connection.connection_type == "underground" then
        local found = false
        local target_entity_data = iterator.entities[
          connection.target.owner.unit_number --[[@as uint]]
        ]
        if target_entity_data then
          for i, pending in pairs(target_entity_data.pending_connections) do
            if
              pending.fluidbox_index == connection.target_fluidbox_index
              and pending.connection_index == connection.target_pipe_connection_index
            then
              found = true
              target_entity_data.pending_connections[i] = nil
              local distance = flib_position.distance(connection.position, pending.position)
              if distance > 1 then
                for i = 1, distance - 1 do
                  local target = flib_position.lerp(connection.position, pending.position, i / distance)
                  shapes[#shapes + 1] = rendering.draw_sprite({
                    sprite = "pv-underground-connection",
                    tint = color,
                    render_layer = layers.underground,
                    orientation = direction / 8,
                    target = target,
                    surface = entity_data.entity.surface_index,
                    players = { iterator.player_index },
                  })
                end
                break
              end
            end
          end
        end
        if not found then
          entity_data.pending_connections[#entity_data.pending_connections + 1] = {
            fluidbox_index = fluidbox_index,
            connection_index = connection_index,
            position = connection.position,
          }
        end
      end

      ::inner_continue::
    end

    ::continue::
  end
  if entity_data.shape and shape_color then
    rendering.set_color(entity_data.shape, shape_color)
  end
  if encoded_connections > 0 then
    rendering.set_sprite(entity_data.shape, "pv-pipe-connections-" .. encoded_connections)
  end
end

--- @param iterator Iterator
--- @param entity_data EntityData
--- @param fluid_system_id FluidSystemID?
local function clear_entity(iterator, entity_data, fluid_system_id)
  if fluid_system_id then
    for _, shape in pairs(entity_data.connections[fluid_system_id]) do
      rendering.destroy(shape)
    end
    entity_data.connections[fluid_system_id] = nil
  else
    for id, shapes in pairs(entity_data.connections) do
      for _, shape in pairs(shapes) do
        rendering.destroy(shape)
      end
      entity_data.connections[id] = nil
    end
  end
  if entity_data.shape then
    rendering.destroy(entity_data.shape)
  end
  if next(entity_data.connections) then
    draw_entity(iterator, entity_data)
    return
  end
  iterator.entities[entity_data.unit_number] = nil
end

--- @param iterator Iterator
--- @param entity LuaEntity
local function iterate_entity(iterator, entity)
  local entity_data = iterator.entities[
    entity.unit_number --[[@as uint]]
  ]
  if entity_data then
    if #entity_data.fluidbox == 1 then
      return
    end
    clear_entity(iterator, entity_data)
  end
  --- @type EntityData
  entity_data = {
    connections = {},
    entity = entity,
    fluidbox = entity.fluidbox,
    pending_connections = {},
    unit_number = entity.unit_number,
  }
  iterator.entities[entity.unit_number] = entity_data

  draw_entity(iterator, entity_data)

  if iterator.in_overlay then
    return
  end

  local fluidbox = entity.fluidbox
  for fluidbox_index = 1, #fluidbox do
    --- @cast fluidbox_index uint
    local id = fluidbox.get_fluid_system_id(fluidbox_index)
    local system = iterator.systems[id]
    if not system then
      goto continue
    end
    -- system.entities[entity.unit_number] = entity_data
    for _, neighbour_fluidbox in pairs(fluidbox.get_connections(fluidbox_index)) do
      flib_queue.push_back(iterator.queue, neighbour_fluidbox.owner)
    end

    ::continue::
  end
end

--- @param iterator Iterator
--- @param entities_per_tick integer
local function iterate(iterator, entities_per_tick)
  for _ = 1, entities_per_tick do
    local entity = flib_queue.pop_front(iterator.queue)
    if not entity then
      break
    end
    iterate_entity(iterator, entity)
  end
end

--- @param iterator Iterator
--- @param system_id FluidSystemID
local function clear(iterator, system_id)
  iterator.systems[system_id] = nil
  for _, entity_data in pairs(iterator.entities) do
    if entity_data.connections[system_id] then
      clear_entity(iterator, entity_data, system_id)
    end
  end
  if not next(iterator.systems) then
    global.iterator[iterator.player_index] = nil
  end
end

--- @param player_index PlayerIndex
local function clear_all(player_index)
  if not global.iterator then
    return
  end
  local iterator = global.iterator[player_index]
  if not iterator then
    return
  end
  for _, entity_data in pairs(iterator.entities) do
    if entity_data.shape then
      rendering.destroy(entity_data.shape)
    end
    for _, shapes in pairs(entity_data.connections) do
      for _, shape in pairs(shapes) do
        rendering.destroy(shape)
      end
    end
  end
  global.iterator[player_index] = nil
end

--- @param starting_entity LuaEntity
--- @param player_index PlayerIndex
local function request_or_clear(starting_entity, player_index)
  if not global.iterator then
    return
  end
  local iterator = global.iterator[player_index]
  if not iterator then
    request(starting_entity, player_index, false)
    return
  end
  local fluidbox = starting_entity.fluidbox
  for fluidbox_index = 1, #fluidbox do
    --- @cast fluidbox_index uint
    local id = fluidbox.get_fluid_system_id(fluidbox_index)
    if id and not iterator.systems[id] then
      request(starting_entity, player_index, false)
      return
    end
  end
  for fluidbox_index = 1, #fluidbox do
    --- @cast fluidbox_index uint
    local id = fluidbox.get_fluid_system_id(fluidbox_index)
    if id and iterator.systems[id] then
      clear(iterator, id)
    end
  end
end

local function on_tick()
  if not global.iterator then
    return
  end
  local entities_per_tick = math.ceil(30 / table_size(global.iterator))
  -- local entities_per_tick = 1
  for _, iterator in pairs(global.iterator) do
    iterate(iterator, entities_per_tick)
  end
end

--- @param e EventData.CustomInputEvent
local function on_toggle_hover(e)
  local player = game.get_player(e.player_index)
  if not player then
    return
  end
  local entity = player.selected
  if not entity then
    clear_all(e.player_index)
    return
  end
  request_or_clear(entity, e.player_index)
end

local iterator = {}

function iterator.on_init()
  --- @type table<PlayerIndex, Iterator>
  global.iterator = {}

  -- local vertices = {
  --   -- North
  --   { -line_radius, line_radius },
  --   { -line_radius, -0.5 },
  --   { line_radius, -0.5 },
  --   { line_radius, line_radius },
  --   { -line_radius, line_radius },
  --   -- East
  --   { -line_radius, -line_radius },
  --   { 0.5, -line_radius },
  --   { 0.5, line_radius },
  --   { -line_radius, line_radius },
  --   { -line_radius, -line_radius },
  --   -- South
  --   { line_radius, -line_radius },
  --   { line_radius, 0.5 },
  --   { -line_radius, 0.5 },
  --   { -line_radius, -line_radius },
  --   { line_radius, -line_radius },
  --   -- West
  --   { -line_radius, line_radius },
  --   { -0.5, line_radius },
  --   { -0.5, -line_radius },
  --   { line_radius, -line_radius },
  --   { -line_radius, line_radius },
  -- }

  -- local real_vertices = {}
  -- for i, vertex in pairs(vertices) do
  --   real_vertices[i] = { target = vertex }
  -- end

  -- -- 2 pixels; 2/32 of a tile
  -- rendering.draw_polygon({
  --   color = { b = 1, g = 1 },
  --   filled = true,
  --   target = { 0.5, 0.5 },
  --   vertices = real_vertices,
  --   surface = 1,
  -- })
end

iterator.events = {
  [defines.events.on_tick] = on_tick,
  ["pv-visualize-selected"] = on_toggle_hover,
}

iterator.clear_all = clear_all
iterator.request = request

return iterator
