--[[

To run the test suite, simply `dofile` this file. You may want to reload the readline module beforehand.

Every test case will (1) spawn a window, (2) populate its buffer, (3) move the cursor (of the current, live Neovim instance) into the new buffer, (4) run the given function(s), (5) confirm that the buffer and cursor update correctly, and (6) close the window if everything is ok.

--]]

local function split(s, delimiter)
  -- https://stackoverflow.com/questions/32847099/split-a-string-by-n-or-r-using-string-gmatch
  local result = {}
  local from  = 1
  local delim_from, delim_to = string.find(s, delimiter, from)
  while delim_from do
    table.insert(result, string.sub(s, from , delim_from-1))
    from  = delim_to + 1
    delim_from, delim_to = string.find(s, delimiter, from)
  end
  table.insert(result, string.sub(s, from))
  return result
end

local function create_scenario(start_contents)
  --[[
  A "scenario" is a window/buffer corresponding to a particular test case. Maybe we could find a better name than "scenario".
  --]]
  local scenario = {}

  local function get_char(s, char_idx)
    return vim.fn.nr2char(vim.fn.strgetchar(s, char_idx))
  end

  local function parse_contents(contents)
    local lines = split(contents, '\n')
    local cursor_line_no, cursor_col
    for line_no, line in ipairs(lines) do
      for char_idx = 0, vim.fn.strchars(line) - 1 do
        if get_char(line, char_idx) == '|' then
          cursor_line_no = line_no
          cursor_col = char_idx
          lines[line_no] = vim.fn.strcharpart(line, 0, char_idx) .. vim.fn.strcharpart(line, char_idx + 1, vim.fn.strchars(line))
        end
      end
    end
    assert(cursor_line_no and cursor_col)
    return cursor_line_no, cursor_col, lines
  end

  scenario.buf = vim.api.nvim_create_buf(true, true)
  assert(scenario.buf ~= 0)
  local start_cursor_line, start_cursor_col, start_lines = parse_contents(start_contents)
  vim.api.nvim_buf_set_lines(scenario.buf, 0, -1, true, start_lines)
  vim.fn.setcursorcharpos(start_cursor_line, start_cursor_col)

  vim.cmd('botright vsplit')
  scenario.win = vim.api.nvim_get_current_win()
  assert(scenario.win ~= 0)
  vim.api.nvim_win_set_buf(scenario.win, scenario.buf)

  function scenario.assert_contents_are(target_contents)
    local target_cursor_line_no, target_cursor_col, target_lines = parse_contents(target_contents)

    local _, cursor_line_no, cursor_col = unpack(vim.fn.getcursorcharpos())
    cursor_col = cursor_col - 1 -- Thanks, Vim.
    local lines = vim.api.nvim_buf_get_lines(scenario.buf, 0, -1, false)

    assert(cursor_line_no == target_cursor_line_no)
    assert(cursor_col == target_cursor_col)
    assert(#lines == #target_lines)
    for i = 1, #lines do
      assert(lines[i] == target_lines[i])
    end
  end

  function scenario.close()
    vim.api.nvim_win_close(scenario.win, false)
  end

  return scenario
end

local function test_case(start_contents, f, end_contents)
  local scenario = create_scenario(start_contents)
  f()
  scenario.assert_contents_are(end_contents)
  scenario.close()
end

local function parse_command_line_contents(contents)
  if contents:gsub('[%|%w ]*', ''):len() ~= 0 then
    -- We do this because there is no function you can use to actually fucking set the contents of the command line, so we have no choice but to feed keys, and I don't want to think about having to make that work with special characters or emojis.
    assert(false, 'Use only alphanumeric characters and spaces for command-line testing')
  end

  local pieces = split(contents, '|')
  if #pieces ~= 2 then
    assert(false, 'Use exactly one pipe | to indicate a cursor position')
  end

  local left, right = unpack(pieces)
  local cursor_col = #left

  return left..right, cursor_col
end

--[[
local function run_command_line_test_cases(start_contents, f, expected_contents)
  set_command_line(start_contents)
  f()
  local expected_text, expected_cursor_col = parse_command_line_contents(expected_contents)
  local actual_text = vim.fn.getcmdline()
  local actual_cursor_col = vim.fn.getcmdpos() - 1
  assert(actual_text == expected_text)
  assert(actual_cursor_col == expected_cursor_col)
  --feed_keys('<Esc>')
end
]]--

local rl = require('readline')

test_case([[
|hello world
]], rl.forward_word, [[
hello| world
]])

test_case([[
|x foo
]], rl.forward_word, [[
x| foo
]])

test_case([[
|+ foo
]], rl.forward_word, [[
+| foo
]])

--[[
add_command_line_test_case(
'|hello world',
rl.kill_word,
'hello| world')
--]]

test_case([[
hello| world
]], rl.backward_word, [[
|hello world
]])

--[[
command_line_test_case(
'hello| world',
rl.backward_word,
'|hello world')
--]]

print('Tests passed!')
