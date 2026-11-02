-- RFC 4180 CSV reader for wago.tools DB2 exports. Plain Lua 5.1, run outside the game.
local M = {}

-- Splits text into records (arrays of fields). Handles quoted commas, doubled quotes,
-- multi-line quoted fields, CRLF/LF/CR line ends and a missing trailing newline.
local function parseRecords(text)
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  local records, fields, buf = {}, {}, {}
  local pos, len, line = 1, #text, 1
  local fieldStarted = false  -- the current field has content (an empty quoted field counts)
  local recordStarted = false -- the current record has any content or separator

  local function endField()
    fields[#fields + 1] = table.concat(buf)
    buf, fieldStarted = {}, false
  end
  local function endRecord()
    endField()
    if recordStarted then records[#records + 1] = { fields = fields, line = line } end -- else: blank line
    fields, recordStarted = {}, false
  end

  while pos <= len do
    local c = text:sub(pos, pos)
    if c == '"' and #buf == 0 and not fieldStarted then
      -- quoted field
      fieldStarted, recordStarted = true, true
      pos = pos + 1
      local closed = false
      while pos <= len do
        local q = text:find('"', pos, true)
        if not q then break end
        buf[#buf + 1] = text:sub(pos, q - 1)
        if text:sub(q + 1, q + 1) == '"' then
          buf[#buf + 1] = '"'
          pos = q + 2
        else
          pos = q + 1
          closed = true
          break
        end
      end
      if not closed then error("csv: unterminated quoted field near line " .. line, 0) end
      -- track line numbers consumed by the quoted field
      local consumed = table.concat(buf)
      for _ in consumed:gmatch("\n") do line = line + 1 end
    elseif c == "," then
      endField()
      recordStarted = true
      pos = pos + 1
    elseif c == "\r" or c == "\n" then
      if c == "\r" and text:sub(pos + 1, pos + 1) == "\n" then pos = pos + 1 end
      endRecord()
      line = line + 1
      pos = pos + 1
    else
      local stop = text:find('[,\r\n]', pos) or (len + 1)
      buf[#buf + 1] = text:sub(pos, stop - 1)
      fieldStarted, recordStarted = true, true
      pos = stop
    end
  end
  if recordStarted then endRecord() end
  return records
end

-- Returns header (array of column names) and rows (array of {[column] = string}).
function M.parse(text)
  local records = parseRecords(text)
  local headerRec = records[1]
  if not headerRec then return {}, {} end
  local header = headerRec.fields
  local rows = {}
  for i = 2, #records do
    local rec = records[i]
    if #rec.fields ~= #header then
      error(string.format("csv: line %d has %d fields, expected %d", rec.line, #rec.fields, #header), 0)
    end
    local row = {}
    for j, name in ipairs(header) do row[name] = rec.fields[j] end
    rows[#rows + 1] = row
  end
  return header, rows
end

function M.read(path)
  local f, err = io.open(path, "rb")
  if not f then error("csv: cannot open " .. tostring(path) .. ": " .. tostring(err), 0) end
  local text = f:read("*a")
  f:close()
  return M.parse(text)
end

-- Returns row[name], or for array columns row[name[index]] / row[name_index].
function M.col(row, name, index)
  local value, label
  if index ~= nil then
    label = name .. "[" .. index .. "]"
    value = row[label]
    if value == nil then value = row[name .. "_" .. index] end
  else
    label = name
    value = row[name]
  end
  if value == nil then
    local have = {}
    for k in pairs(row) do have[#have + 1] = k end
    table.sort(have)
    error("missing column " .. label .. "; have: " .. table.concat(have, ", "), 0)
  end
  return value
end

return M
