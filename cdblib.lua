local plstringx = require "pl.stringx"

local _M = {}

-- Escape file name for GNU digest; returns new form and number, which is 0 if
-- string is unaltered and positive if escaping was necessary.
--
-- The GNU digest specification is incomplete and does not promise that all
-- file names with backslashes are escaped, though that seems to be true in
-- practice.  That is, while the tools appear to always generate the first of
-- these two options, the second appears to be permitted by documentation as
-- well: "\012...ef  as\\df" and "012...ef  as\df".  We follow along and always
-- escape backslashes even if there are no \r or \n characters in the rest of
-- the string.
local function escape_gnu_digest(fn)
  return fn:gsub("[\\\r\n]", {['\\']='\\\\', ['\r']='\\r', ['\n']='\\n'})
end
_M.escape_gnu_digest = escape_gnu_digest

-- The inverse transformation of escape_gnu_digest.  Applied unconditionally, so
-- please condition invocation on knowing that the line needs to be escaped.
local function unescape_gnu_digest(fn)
  return fn:gsub("\\.", {['\\\\']='\\', ['\\r']='\r', ['\\n']='\n'})
end
_M.unescape_gnu_digest = unescape_gnu_digest

function _M.iter_gnu_digest(baseiter)
  return function() return coroutine.wrap(function()
    for line in baseiter() do
      if line == nil then return nil end
      local esc, h, fn = line:match("^(\\?)(%x*) [ *](.*)$")
      if esc == nil then
        print("Bad line:", line) -- XXX
      else
        coroutine.yield(h, (esc == "") and fn or unescape_gnu_digest(fn))
      end
    end
  end) end
end

function _M.iter_just_paths_as_digest(baseiter)
  return function() return coroutine.wrap(function()
    for line in baseiter() do
      if line == nil then return nil end
      coroutine.yield("-", line)
    end
  end) end
end

-- a custom delimited string iterator, useful for nul-separated records, e.g.
-- :: (string, () -> () -!> string) -> () -> () -!> string
function _M.mk_delim_iter(delim, baseiter)
  local ix = 0
  local s = { fin = {}, incomplete = {} }

  local function proc(chunk)
    local splits = plstringx.split(chunk, delim)

    if #splits == 1 then -- zero or one delimiter
      if #splits[1] == 0 then -- one delimiter (necessarily the whole string)
        if #s.incomplete > 0 then -- and a prefix exists
          s.fin = { table.concat(s.incomplete) }
          s.incomplete = {}
        end
      else                    -- zero delimiters
        table.insert(s.incomplete, chunk)  -- grow incomplete fragment
      end
    else -- one or more delimiters
      local ni = table.remove(splits)

      table.insert(s.incomplete, splits[1])
      splits[1] = table.concat(s.incomplete)
      s.fin = splits

      s.incomplete = {}
      if #ni ~= 0 then s.incomplete[1] = ni end
    end
  end

  return function() return coroutine.wrap(function()
    for chunk in baseiter() do
      proc(chunk)
      
      -- while we have a complete delimited string, return one
      while #s.fin > 0 do
        ix = ix + 1
        coroutine.yield(ix, table.remove(s.fin))
      end
    end
  end) end
end

function _M.iter_just_2nd(baseiter)
  return function() return coroutine.wrap(function()
    for k, v in baseiter() do coroutine.yield(v) end end)
  end
end

-- :: (file or nil) -> () -> () -!> string
function _M.mk_read_iter(f)
  f = f or io.input()
  return function() return function() return f:read(1024) end end
end
function _M.mk_lines_iter(f)
  return function() return (f or io.input()):lines() end
end

-- Iterate stdin as either newline-terminated or NUL-terminated records
-- :: (boolean, file or nil) -> () -!> string
function _M.iter_lines_or_nul(nul, f)
  assert(type(nul) == "boolean")
  return nul and _M.iter_just_2nd(_M.mk_delim_iter("\0", _M.mk_read_iter(f)))
              or _M.mk_lines_iter(f)
end

function _M.renderers_for(nul, unescape)
  assert(type(nul) == "boolean")
  assert(type(unescape) == "boolean")
  local fin = nul and '\0' or '\n'
  local mangle_path = unescape
                      and function(p) return p, fin end
                      or function(p)
                           local np, nesc = escape_gnu_digest(p)
                           return (nesc == 0 and "" or "\\"), "  ", np, fin
                         end
  local mangle_full = unescape
                      and function(h, f) return "", h, "  ", f, fin end
                      or function(h, f)
                           local nf, nesc = escape_gnu_digest(f)
                           return (nesc == 0 and "" or "\\"), h, "  ", nf, fin
                         end
  return mangle_full, mangle_path
end

return _M
