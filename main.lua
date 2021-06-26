local uv = require "uv"
local process = require "process".globalProcess()
local los = require "los"

local format = string.format
local loadstring = loadstring or load

-- Add saphire to preload to allow require "saphire" in scripts.
local saphire = {}
package.preload["saphire"] = function () return saphire end

saphire.rebuild = false -- Force the rebuild of all recipes.

-- Workers used while building.
saphire.workers = {}

-- Queued and finished coroutines.
saphire.routines = {}

-- Targets for building.
saphire.targets = {}

-- Messages
saphire.messages = {}

-- Store the cwd of each routine.
saphire.routines_cwd = {}

local ring = { "|", "/", "-", "\\"  }
local ring_tick = 0
local display_tick = 0

--[[
  Display current saphire status.
]]
function saphire.display()
  -- Some kind of display.
  ring_tick = (ring_tick + 1) % #ring

  io.write(format("\x1B[0m%s Building %s\n", ring[ring_tick + 1], ring[ring_tick + 1]))

  for i,w in ipairs(saphire.workers) do
    io.write(format(
      "\x1B[2KW%02u: \x1B[34m%s\x1B[36m%s\x1B[1;30m%s\x1B[0m\n", i,
      (w and w.name and format("(%s) ", w.name)) or "",
      w and (w.display or w.command) or "\x1B[33minactive",
      (w and w.directory and format(" (in %s)", w.directory)) or "")
    )
  end

  --for i,msg in ipairs(saphire.messages) do
  --  print(msg)
  --end

  io.write(format("\x1B[%dF\x1B[G", #saphire.workers + 1))
  io.stdout:flush()
end

--[[
  Coroutine that generate tasks from saphire.routines.
  Uses a Depth-First-Search algorithm.
]]
local function next_task()
  repeat
    local active = false
    local blocked = true

    for i,routine in ipairs(saphire.routines) do
      while routine do
        if coroutine.status(routine) == "dead" then
          saphire.routines[i] = false
          saphire.routines_cwd[routine] = nil
          break
        else
          do
            local dir = saphire.routines_cwd[routine] or saphire.rootdir
            local status, err = uv.chdir(dir)
            if not status then
              error(format("Unexpected chdir failure during building : %s on %s", dir, err))
            end
          end

          local status, t = coroutine.resume(routine)
          if status then
            active = true
            if t then
              blocked = false
              coroutine.yield(t)
            else
              -- Coroutine blocked
              break
            end
          else
            if t then
              saphire.messages[#saphire.messages + 1] = format("\x1B[31merr: %s\x1B[0m", t)
            end
          end
        end
      end
    end

    if blocked then
      coroutine.yield()
    end
  until active == false

  -- No more routines to run
  return
end

--[[
  Run saphire with a function as main routine, this function
  is not reentrant and must not be called recursively.

  TODO: Reentrant saphire ?
]]
function saphire.run(f)
  local start_time = os.time()

  saphire.routines[1] = coroutine.create(f)
  saphire.next_task_coroutine = coroutine.create(next_task)

  -- Timer to force display update.
  local timer = uv.new_timer()
  timer:start(0, 1000 / saphire.display_tick_rate, function ()
    coroutine.resume(saphire.coroutine)
  end)

  repeat
    local active = false

    for i,w in ipairs(saphire.workers) do
      if not w then
        -- Worker is available.
        local status, t = coroutine.resume(saphire.next_task_coroutine)
        if status and t then
          if saphire.no_vt then
            print(t.command)
          end

          saphire.workers[i] = assert(saphire.start_task(t, i), "Failed to start task")
        end
      end

      if saphire.workers[i] then
        active = true
      end
    end

    if active then
      if not saphire.no_vt then
        saphire.display()
      end
      coroutine.yield()
    end
  until not active

  timer:stop()
  timer:close()

  -- TODO: Improve display ? Failure count/graph ?
  local duration = os.difftime(os.time(), start_time)

  if #saphire.messages > 0 then
    if saphire.no_vt then
      print(format("Completed building, check messages (%gs)", duration))
    else
      io.write(format("\x1B[%dB", #saphire.workers + 1))
      print(format("\x1B[33mCompleted building, check messages (%gs)\x1B[0m", duration))
    end

    for i,msg in ipairs(saphire.messages) do
      print(msg)
    end
  else
    if saphire.no_vt then
      print(format("Completed successfully (%gs)", duration))
    else
      io.write(format("\x1B[%dB", #saphire.workers + 1))
      print(format("\x1B[32mCompleted successfully (%gs)\x1B[0m", duration))
    end
  end
end

-- Start a new task.
function saphire.start_task(task, wid)
  if saphire.dryrun then
    local timer = uv.new_timer()
    uv.timer_start(timer, 0, 0, function ()
      timer:close()

      task.completed = true
      saphire.workers[wid] = false

      coroutine.resume(saphire.coroutine)
    end)
    
    task.completed = false
    return task
  end

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local close_callback = function (code)
    saphire.workers[wid] = false
    task.handle:close()
    stdout:close()
    stderr:close()

    if code ~= 0 then
      saphire.messages[#saphire.messages + 1] = format("\x1B[31mtask failed: %s\x1B[0m", task.command)
    end

    if task.stdout then
      saphire.messages[#saphire.messages + 1] = format("\x1B[36mstdout (%s)\x1B[0m\n%s", task.command, task.stdout)
    end

    if task.stderr then
      saphire.messages[#saphire.messages + 1] = format("\x1B[1;31mstderr (%s)\x1B[0m\n%s", task.command, task.stderr)
    end

    -- Wake up main coroutine.
    coroutine.resume(saphire.coroutine)
  end

  local handle, pid

  if los.type() == "win32" then
    handle, pid = uv.spawn("cmd", {
      cwd = task.directory,
      hide = true,
      args = { "/s", "/c", '"' .. task.command .. '"' },
      verbatim = true,
      stdio = { nil, stdout, stderr }
    }, close_callback)
  else
    handle, pid = uv.spawn("sh", {
      cwd = task.directory,
      args = { "-c", task.command },
      stdio = { nil, stdout, stderr }
    }, close_callback)
  end

  if handle == nil then
    return
  end

  uv.read_start(stdout, function(err, data)
    assert(not err, err)
    if data then
      task.stdout = (task.stdout or "") .. data
    end
  end)

  uv.read_start(stderr, function(err, data)
    assert(not err, err)
    if data then
      task.stderr = (task.stderr or "") .. data
    end
  end)

  task.handle = handle
  task.pid = pid
  
  task.completed = false
  return task
end

-- Helper functions
function saphire.do_single(task, wait)
  if type(task) == "string" then
    task = { command = task }
  end

  if type(task) == "function" then
    local co = coroutine.create(task)

    repeat
      local status, t = coroutine.resume(co, task)
      if status and (t ~= nil) then
        coroutine.yield(t)
      end
    until t == nil
  else
    if not task.directory then
      task.directory = uv.cwd()
    end

    coroutine.yield(task)

    while wait and not task.completed do
      coroutine.yield() -- task isn't completed
    end
  end
end

function saphire.do_multi(tasks, wait)
  local heap

  if type(tasks) == "function" then
    heap = {}

    local heap_size = 0
    for t in tasks do
      heap[heap_size+1] = t
    end
  else
    heap = tasks
  end

  for i,task in ipairs(heap) do
    if type(task) == "function" then
      heap[i] = coroutine.create(task)
      saphire.routines[#saphire.routines + 1] = heap[i]

      -- Inherit cwd from current routine.
      saphire.routines_cwd[heap[i]] = saphire.routines_cwd[coroutine.running()]
    else
      task.directory = uv.cwd()
      coroutine.yield(task)
    end
  end

  local completed = false

  while wait and not completed do
    completed = true

    for i,task in ipairs(heap) do
      if type(task) == "thread" then
        if coroutine.status(task) ~= "dead" then
          completed = false
          break
        end
      elseif type(task) == "table" then
        if not task.completed then
          completed = false
          break
        end
      end
    end

    coroutine.yield()
  end
end

function saphire.do_recipe(recipe, target, task, wait)
  if type(recipe) == "string" then
    recipe = { recipe }
  end

  if type(target) == "string" then
    target = { target }
  end

  -- Compare timestamp and return true if a is newer than b.
  local function is_newer(a, b)
    return a.sec > b.sec or (a.sec == b.sec and a.nsec >= b.nsec)
  end

  if not saphire.rebuild then
    -- These timestamps will be replaced in recipe and target loops.
    local oldest_target = { nsec = math.huge, sec = math.huge }
    local newest_recipe = { nsec = 0, sec = 0 }

    for i,path in ipairs(recipe) do
      local st = assert(uv.fs_stat(path), "Missing recipe " .. path)
      if is_newer(st.mtime, newest_recipe) then
        newest_recipe = st.mtime
      end
    end

    local missing_target = false
    for i,path in ipairs(target) do
      local st = uv.fs_stat(path)

      if st then
        if is_newer(oldest_target, st.mtime) then
          oldest_target = st.mtime
        end
      else
        missing_target = true
        break
      end
    end

    if not missing_target and not is_newer(newest_recipe, oldest_target) then
      -- Nothing to do
      return
    end
  end

  if type(task) == "function" then
    task()
  else
    saphire.do_single(task, wait)
  end
end

-- Build a subdirectory with a Saphirefile.lua (can be overriden with saphirefile parameter).
function saphire.do_subdir(path, wait, saphirefile)
  local cwd = uv.cwd()
  local func, err

  -- Use saphirefile path if provided.
  if saphirefile then
    func, err = loadfile(saphirefile)
    if not func then
      error(err)
    end
  end

  -- Go to subdir path
  do
    local status, err = uv.chdir(path)
    if not status then
      error(format("Can't chdir to subdirectory '%s' (%s)", path, err))
    end
  end

  -- Cwd has be changed to subdir path at this point, we can
  -- do loadfile "Saphirefile" to load the Saphirefile of the subdir.
  if not func then
    func, err = loadfile "Saphirefile.lua"
    if not func then
      print(err)
      error(err)
    end
  end

  local co = coroutine.create(func)

  saphire.routines[#saphire.routines+1] = co
  saphire.routines_cwd[co] = uv.cwd() -- subdir cwd

  while wait and coroutine.status(co) ~= "dead" do
    coroutine.yield()
  end

  -- Go back to cwd
  uv.chdir(cwd)
end

-- Useful functional utilities

-- Map a table with a function.
function saphire.map(t, func, ...)
  local t_new = {}

  for k,v in pairs(t) do
    t_new[k] = func(v, ...)
  end

  return t_new
end

-- Merge multiple tables into one.
function saphire.merge(...)
  local t_new = {}
  local t_new_n = 0

  for _,t in ipairs { ... } do
    for _,v in ipairs(t) do
      t_new[t_new_n + 1] = v
      t_new_n = t_new_n + 1
    end
  end

  return t_new
end

local function show_help(message)
  io.write([[
Saphire parallel build system
https://github.com/TSnake41/Saphire

Usage:
  luajit saphire [--no-vt] [--workers=n] [--...] [target1] ... [targetN]
  ./saphire [--no-vt] [--workers=n] [--...] [target1] ... [targetN]

  no-vt: Disable advanced VT100-based display.
  workers: Override worker count.
  display-tick-rate: Change the number of tick needed to refresh the display.
  rebuild: Force the rebuild of all recipes.
  file: Force the Saphirefile.lua to use
  dryrun: Only simulate tasks, don't do any task.

]] .. message .. "\n")
end

function saphire.main(arg)
  local worker_count = #uv.cpu_info()
  local saphirefile = "Saphirefile.lua"
  local help = false

  for i,argument in ipairs(arg) do
    if argument:sub(1, 2) == "--" then
      if argument == "--no-vt" then
        saphire.no_vt = true
      end

      if argument:match "%-%-workers=" then
        worker_count = tonumber(argument:match "--workers=(%d+)")
      end

      if argument:match "%-%-display-tick-rate=" then
        saphire.display_tick_rate = tonumber(argument:match "%-%-display-tick=(%d+)")
      end

      if argument:match "%-%-file=" then
        saphirefile = argument:match "%-%-file=(.+)"
      end

      if argument == "--help" then
        help = true
      end

      if argument == "--rebuild" then
        saphire.rebuild = true
      end

      if argument == "--dryrun" then
        saphire.dryrun = true
      end
    else
      saphire.targets[argument] = true
    end
  end

  if help then
    show_help ""
  else
    local f = io.open(saphirefile, "r")
    if not f then
      show_help "Saphirefile.lua not found"
      return
    end

    for i=1,worker_count do
      saphire.workers[i] = false
    end

    saphire.display_tick_rate = saphire.display_tick_rate or 1
    saphire.rootdir = uv.cwd() -- default directory

    saphire.run(function ()
      local func, err = loadstring(f:read "*a", "Saphirefile.lua")
      -- HACK: Fix require
      getfenv(func).require = require

      f:close()

      if func then
        func()
      else
        print(err)
      end
    end)
  end
end

if process.argv then
  saphire.coroutine = coroutine.create(saphire.main)
  local status, err = coroutine.resume(saphire.coroutine, process.argv)

  if status then
    uv.run()
  else
    print(err)
  end
end
