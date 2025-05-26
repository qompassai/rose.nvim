--/qompassai/rose.nvim/lua/queries.lua
-- --------------------------------------------
-- Copyright (C) 2025 Qompass AI, All rights reserved
local logger = require("rose.logger")
local Queries = {}
Queries.__index = Queries
--- @return table
function Queries:new()
  return setmetatable({ _queries = {} }, self)
end
--- @param qid number
--- @param data table
function Queries:add(qid, data)
  self._queries[qid] = data
end
function Queries:pairs()
  return pairs(self._queries)
end
--- @param qid string # Query ID.
function Queries:delete(qid)
  self._queries[qid] = nil
end
--- @param qid string
--- @return table|nil
function Queries:get(qid)
  if not self._queries[qid] then
    logger.warning("Query with ID " .. tostring(qid) .. " not found.")
    return nil
  end
  return self._queries[qid]
end
--- @param N number
--- @param age number
function Queries:cleanup(N, age)
  local current_time = os.time()
  local query_count = 0
  for _ in self:pairs() do
    query_count = query_count + 1
  end
  if query_count <= N then
    return
  end
  for qid, query_data in self:pairs() do
    if current_time - query_data.timestamp > age then
      self:delete(qid)
    end
  end
end
return Queries
