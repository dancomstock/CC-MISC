local common = require("common")
local printf = common.printf

---@type table array of module filenames to load
local modules = {
  --"modules.debug",
  "modules.logger",
  "modules.inventory",
  "modules.crafting",
  "modules.grid",
  "modules.interface",
  "modules.modem"
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


---@type thread[] array of functions to run all the modules
local moduleExecution = {}
---@type table<thread,string|nil>
local moduleFilters = {}
---@type string[]
local moduleIds = {}
for _,v in ipairs(moduleInitOrder) do
  local mod = loaded[v]
  if mod.init then
    local t0 = os.clock()
    -- The table returned by init will be placed into [id].interface
    loaded[mod.id].interface = mod.init(loaded, config)
    if loaded[mod.id].interface.start then
      table.insert(moduleExecution, coroutine.create(loaded[mod.id].interface.start))
      table.insert(moduleIds, mod.id)
    end
    printf("Initialized %s in %.2f seconds", mod.id, os.clock() - t0)
  else
    printf("Failed to initialize %s, no init function", mod.id)
  end
end

---Save a crash report
---@param module string module name that crashed
---@param stacktrace string module stacktrace
---@param error string
local function saveCrashReport(module, stacktrace, error)
  local f, reason = fs.open("crash.txt","w")
  if not f then
    print("Unable to save crash report!")
    print(reason)
    return
  end
  f.write("===MISC Crash Report===\n")
  f.write(("Generated on %s\n"):format(os.date()))
  f.write(("There were %u modules loaded.\n"):format(#modules))
  for k,v in pairs(loaded) do
    if k ~= "config" then
      local icon = "-"
      if v.id == module then
        icon = "*"
      end
      f.write(("%s %s v%s\n"):format(icon,v.id,v.version))
    end
  end
  f.write("--- ERROR\n")
  f.write(error)
  f.write("\n--- STACKTRACE\n")
  f.write(stacktrace)
  f.close()
end

print("Starting execution...")
while true do
  local timerId = os.startTimer(0)
  local e = table.pack(os.pullEventRaw())
  os.cancelTimer(timerId)
  if e[1] == "terminate" then
    print("Terminated.")
    return
  end
  for i, co in ipairs(moduleExecution) do
    if not moduleFilters[co] or moduleFilters[co] == "" or moduleFilters[co] == e[1] then
      local ok, filter = coroutine.resume(co, table.unpack(e))
      if not ok then
        print("Module errored, saving crash report..")
        saveCrashReport(moduleIds[i], debug.traceback(co), filter)
        return
      end
      moduleFilters[co] = filter
    end
  end
end