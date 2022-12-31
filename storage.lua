local common = require("common")
local printf = common.printf

---@type table array of module filenames to load
local modules = {
  --"modules.debug",
  "modules.logger",
  "modules.inventory",
  "modules.crafting",
  "modules.grid",
  -- "modules.rednet",
  -- "modules.gui",
  "modules.tui"
}

-- A module should return a table that contains at least the following fields
---@class module
---@field id string
---@field config table<string, configspec>|nil
---@field init fun(modules:table,config:table):table

---@class configspec
---@field default any
---@field type string

---@type table loaded config information
local config = {}
---@type table array of module IDs in init order
local moduleInitOrder = {}
---@type table [id] -> module return info
local loaded = {}
for _,v in ipairs(modules) do
  ---@type module
  local mod = require(v)
  loaded[mod.id] = mod
  config[mod.id] = mod.config
  table.insert(moduleInitOrder, mod.id)
  printf("Loaded %s v%s", mod.id, mod.version)
end

local function protectedIndex(t, ...)
  local curIndex = t
  for k,v in pairs({...}) do
    curIndex = curIndex[v]
    if curIndex == nil then
      return nil
    end
  end
  return curIndex
end

local function getValue(type)
  while true do
    term.write("Please input a "..type..": ")
    local input = io.read()
    if type == "table" then
      local val = textutils.unserialise(input)
      if val then
        return val
      end
    elseif type == "number" then
      local val = tonumber(input)
      if val then
        return val
      end
    elseif type == "string" then
      if input ~= "" then
        return input
      end
    else
      error(("Invalid type %s"):format(type))
    end
  end
end

local loadedConfig = common.loadTableFromFile("config.txt") or {}
local badOptions = {}
for id, spec in pairs(config) do
  for name, info in pairs(spec) do
    config[id][name].value = protectedIndex(loadedConfig, id, name, "value") or config[id][name].default
    config[id][name].id = id
    config[id][name].name = name
    if type(config[id][name].value) ~= info.type then
      if loaded[id].setup then
        loaded[id].setup(config[id])
        assert(type(config[id][name].value) == info.type,
        ("Module %s setup failed to set %s"):format(id,name))
        -- if a module has a first time setup defined, call it
      else
        print(("Config option %s.%s is invalid"):format(id, name, info.type))
        print(config[id][name].description)
        config[id][name].value = getValue(config[id][name].type)
      end
    end
  end
end

local function saveConfig()
  common.saveTableToFile("config.txt", config, false, true)
end
saveConfig()

loaded.config = {
  interface = {
    save = saveConfig,
    ---Attempt to the given setting to the given value
    ---@param setting table
    ---@param value any
    ---@return boolean success
    set = function(setting, value)
      if type(value) == setting.type then
        setting.value = value
        return true
      end
      if setting.type == "number" and tonumber(value) then
        setting.value = tonumber(value)
        return true
      end
      if setting.type == "table" and value then
        local val = textutils.unserialise(value)
        if val then
          setting.value = val
          return true
        end
      end
      return false
    end
  }
}


---@type table array of functions to run all the modules
local moduleExecution = {}
for _,v in ipairs(moduleInitOrder) do
  local mod = loaded[v]
  if mod.init then
    local t0 = os.clock()
    -- The table returned by init will be placed into [id].interface
    loaded[mod.id].interface = mod.init(loaded, config)
    table.insert(moduleExecution, loaded[mod.id].interface.start)
    printf("Initialized %s in %.2f seconds", mod.id, os.clock() - t0)
  else
    printf("Failed to initialize %s, no init function", mod.id)
  end
end

print("Starting execution...")
parallel.waitForAny(table.unpack(moduleExecution))
