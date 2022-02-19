-- SPDX-License-Identifier: AGPL-3.0-or-later

local plstringx = require "pl.stringx"

local _M = {}

------------------------------------------------ GNU digest tools {{{

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

-- Iterate a GNU digest tool stream, canonicalizing file names into their
-- unescaped form if necessary.  `errcb` is invoked for lines that do not match
-- and may return `false` to stop iteration.
local function iter_gnu_digest(errcb, baseiter)
  return function() return coroutine.wrap(function()
    for line in baseiter() do
      if line == nil then return nil end
      local esc, h, fn = line:match("^(\\?)(%x*) [ *](.*)$")
      if esc == nil then
        if errcb(line) == false then return nil end
      else
        coroutine.yield(h, (esc == "") and fn or unescape_gnu_digest(fn))
      end
    end
  end) end
end
_M.iter_gnu_digest = iter_gnu_digest

function _M.iter_gnu_digest_stderr(baseiter)
  local errcb = function(line)
      io.stderr:write("Bad line: ", line, "\n")
      return true -- continue iteration
    end
  return iter_gnu_digest(errcb, baseiter)
end


function _M.iter_just_paths_as_digest(dummyhash, baseiter)
  return function() return coroutine.wrap(function()
    for line in baseiter() do
      if line == nil then return nil end
      coroutine.yield(dummyhash, line)
    end
  end) end
end

----------------------------------------------------------------- }}}
---------------------------------------------- Iterator utilities {{{

-- a custom delimited string iterator, useful for nul-separated records, e.g.
-- :: (string, () -> () -!> string) -> () -> () -!> string
function _M.iter_delim(delim, baseiter)
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
      if #s.fin > 0 then
        local t = s.fin
        s.fin = {}

        -- reverse once, then drain from the "front"
        do
          local i, n = 1, #t
          while i < n do t[i], t[n] = t[n], t[i]; i = i+1; n = n-1 end
        end
        while #t > 0 do
          ix = ix + 1
          coroutine.yield(ix, table.remove(t))
        end
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
function _M.iter_read(f)
  f = f or io.input()
  return function() return function() return f:read(1024) end end
end
function _M.iter_lines(f)
  return function() return (f or io.input()):lines() end
end

-- Iterate stdin as either newline-terminated or NUL-terminated records
-- :: (boolean, file or nil) -> () -> () -!> string
function _M.iter_lines_or_nul(nul, f)
  assert(type(nul) == "boolean")
  return nul and _M.iter_just_2nd(_M.iter_delim("\0", _M.iter_read(f)))
              or _M.iter_lines(f)
end

function _M.iter_table(t)
  return function() return coroutine.wrap(function()
    for _, v in ipairs(t) do coroutine.yield(v) end
  end) end
end

----------------------------------------------------------------- }}}
--------------------------------------------- Generator utilities {{{

-- lazily generate and cache escaped version
local function _renderer_for_esc(t,k)
    local nesc
    t.f, nesc = escape_gnu_digest(t.u)
    t.e = nesc == 0 and "" or "\\"
    return t[k]
  end

-- Generate a renderer for a choice of common parameters.  In the resulting
-- template expansion,
--
--   $e expands to "\\" (resp. "") if the path was (resp. was not) escaped
--   $f expands to the optionally escaped file name (see $e)
--   $h expands to the hash
--   $u expands to the unescaped file name
--   $z expands to the appropriate record separator ("\n" or "\0")
--
function _M.renderer_for(nul, unescape, template)
  local v = { z = nul and "\0" or "\n"
            , f = unescape and function(t) return t.u end or _renderer_for_esc
            , e = unescape and "" or _renderer_for_esc
            }
  local mt = { __index =
    function(t,k)
      local x = v[k]
      return type(x) == "function" and x(t,k) or x
    end
  }
  return function(hash, path)
    return template:substitute(setmetatable({h = hash, u = path}, mt))
  end
end

function _M.mk_default_render_template()
  return (require "pl.text").Template("$e$h  $f$z")
end

----------------------------------------------------------------- }}}
------------------------------------------- Path escape utilities {{{

-- This appears to be pretty safe, even in the presence of non-ASCII bytes.
-- That's kind of great and we will use this by default whenever we generate
-- text for a shell.
function _M.posix_shell_escape(str)
  return "'" .. str:gsub("'", "'\"'\"'") .. "'"
end

-- While POSIX shells understand control characters inside single quotes, they
-- are unfriendly to read as such.  Some shells have a $'...' escape that can
-- process things like \t and \xXX.  This uses that instead, though always in
-- the \xXX form.
local function extended_shell_escape(str)
  return "'" ..
    str:gsub("['%G]", function(c)
      return c == " " and " "
          or c == "'" and "'\"'\"'"
          or ("'$'\\x%02x''"):format(c:byte())
    end) .. "'"
end
_M.extended_shell_escape = extended_shell_escape

-- Formatting for humans is... more exciting, as we expect these to end up on
-- a screen with no intermediate processing.  Astoundingly more subtle.  We
-- use posix rexlib.
function _M.mk_human_shell_escape(rexlib)
  local nonglyph = rexlib.new("[^[:graph:] ]", rexlib.REG_EXTENDED)
  local nonshell = rexlib.new("[^-%',._+:@/ [:alnum:]]", rexlib.REG_EXTENDED)

  return function(str)
    if not nonglyph:find(str) then
      -- no control characters, and...
      if not str:find("'") then
        -- no single quotes, so simple enough to just single-quote the thing
        return "'" .. str .. "'"
      elseif not nonshell:find(str) then
        -- single quote but otherwise all double-quoted shell-safe characters
        -- (notably, no double quote, dollar, backtick, or backslash, but also
        -- no non-ASCII)
        return '"' .. str .. '"'
      end
    end

    -- If none of the special cases apply, be overzealous but hopefully safe
    return extended_shell_escape(str)
  end
end

----------------------------------------------------------------- }}}

return _M
