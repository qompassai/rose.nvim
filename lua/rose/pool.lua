--/qompassai/rose.nvim/lua/pool.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local Pool = {}
Pool.__index = Pool
--- @return table
function Pool:new()
  return setmetatable({ _processes = {} }, self)
end
--- @param job table
--- @param buf number|nil
function Pool:add(job, buf)
  table.insert(self._processes, { job = job, buf = buf })
end
--- @param buf number|nil
--- @return boolean
function Pool:unique_for_buffer(buf)
  if buf == nil then
    return true
  end
  for _, handle_info in self:ipairs() do
    if handle_info.buf == buf then
      return false
    end
  end
  return true
end
--- @param pid number
function Pool:remove(pid)
  for i, handle_info in self:ipairs() do
    if handle_info.job.pid == pid then
      table.remove(self._processes, i)
      return
    end
  end
end
--- @return boolean
function Pool:is_empty()
  return next(self._processes) == nil
end
function Pool:ipairs()
  return ipairs(self._processes)
end
return Pool
