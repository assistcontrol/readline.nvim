--[[

Notes
-----

A "character" is a single display character, like X or 🙂, independent of the number of bytes used to encode it or the number of screen cells used to display it.

Character indices are zero-based, which agrees with cursor-column-indices, and also agrees with the most-common convention in Vim.

A "cursor column" is a number that represents a cursor position in a line. Thus, for example, there is one more cursor column in a line than there are characters. Cursor columns are zero-based by convention in this source code. Cursor columns live in the character coordinate system, because the number of display cells used to display some characters in Vim is context-dependent.

Line numbers are defined as usual, one-based.

--]]

local readline = {}

local alphanum = 'abcdefghijklmnopqrstuvwxyz' ..
                 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' ..
                 '0123456789'

readline.alphanum = alphanum
readline.default_word_chars = alphanum
readline.word_chars = {}

local function is_whitespace(c)
  return c == ' ' or
         c == '	'
end

local function is_word_char(c, word_chars)
  if word_chars == 'NON_WHITESPACE_CHARS' then
    return not is_whitespace(c)
  else
    return string.find(word_chars, c, 1, true)
  end
end

local function command_line_mode()
  return vim.fn.mode() == 'c'
end

local BLOCK_CURSOR_MODES = {
  ['n'] = true,
  ['no'] = true,
  ['nov'] = true,
  ['noV'] = true,
  ['noCTRL-V'] = true,
  ['niI'] = true,
  ['niR'] = true,
  ['niV'] = true,
  ['nt'] = true,
  ['v'] = true,
  ['vs'] = true,
  ['V'] = true,
  ['Vs'] = true,
  ['CTRL-V'] = true,
  ['CTRL-Vs'] = true,
  ['s'] = true,
  ['S'] = true,
  ['CTRL-S'] = true,
  ['i'] = false,
  ['ic'] = false,
  ['ix'] = false,
  ['R'] = false,
  ['Rc'] = false,
  ['Rx'] = false,
  ['Rv'] = false,
  ['Rvc'] = false,
  ['Rvx'] = false,
  ['c'] = false,
  ['cv'] = false,
  ['r'] = true,
  ['rm'] = true,
  ['r?'] = true,
  ['!'] = true,
  ['t'] = true,
}

local function block_cursor_mode()
  return BLOCK_CURSOR_MODES[vim.fn.mode()]
end

local function curr_line_no()
  if command_line_mode() then
    return nil
  else
    return vim.fn.line('.')
  end
end

local function get_line(line_no)
  return vim.fn.getline(line_no)
end

local function get_char(s, char_idx)
  return vim.fn.nr2char(vim.fn.strgetchar(s, char_idx))
end

local function curr_line()
  if command_line_mode() then
    return vim.fn.getcmdline()
  else
    return get_line(curr_line_no())
  end
end

local function curr_cursor_col()
  -- Returns zero-based.
  if command_line_mode() then
    local byte_idx = vim.fn.getcmdpos() - 1 -- Zero-based.
    local line = curr_line()
    if byte_idx == vim.fn.strlen(line) then
      return vim.fn.strchars(line)
    end
    return vim.fn.charidx(line, byte_idx)
  else
    return vim.fn.charcol('.') - 1
  end
end

local function num_lines()
  if command_line_mode() then
    return nil
  else
    return vim.fn.line('$')
  end
end

local function last_cursor_col_on_curr_line()
  if block_cursor_mode() then
    return math.max(0, vim.fn.strchars(curr_line()) - 1)
  else
    return vim.fn.strchars(curr_line())
  end
end

local function cursor_col_at_end_of_leading_whitespace(line)
  local char_idx = 0
  local function char()
    return get_char(line, char_idx)
  end
  while char_idx < vim.fn.strchars(line) and is_whitespace(char()) do
    char_idx = char_idx + 1
  end
  return char_idx
end

local function cursor_col_at_start_of_trailing_whitespace(line)
  local char_idx = vim.fn.strchars(line)
  local function prev_char()
    return get_char(line, char_idx - 1)
  end
  while char_idx - 1 >= 0 and is_whitespace(prev_char()) do
    char_idx = char_idx - 1
  end
  return char_idx
end

local function get_word_chars()
  if command_line_mode() then
    return readline.default_word_chars -- Hmm, we can probably do better than this.
  end

  return vim.b.readline_word_chars
      or readline.word_chars[vim.bo.filetype]
      or readline.default_word_chars
end

local STOP_PATTERNS = {
  c = {'//'},
  javascript = {'//'},
  lua = {'--'},
  python = {'#'},
}

local function get_stop_patterns()
  return STOP_PATTERNS[vim.o.ft] or {}
end

local function new_cursor(s, char_idx, dir, word_chars)
  local early_exit
  if dir < 0 then
    early_exit = cursor_col_at_end_of_leading_whitespace(s)
  else
    early_exit = cursor_col_at_start_of_trailing_whitespace(s)
  end

  local length = vim.fn.strchars(s)
  local next_char_idx = function(j)
    return (dir == -1) and (j - 1) or j
  end
  local can_advance = function(j)
    local jp = next_char_idx(j)
    return 0 <= jp and jp < length
  end
  local consumed_word_char = false
  local consumed_non_whitespace = false
  while can_advance(char_idx) do
    local c = get_char(s, next_char_idx(char_idx))

    if (is_whitespace(c) and consumed_non_whitespace) or (not is_word_char(c, word_chars) and consumed_word_char) then
      break
    end

    char_idx = char_idx + dir

    if is_word_char(c, word_chars) then consumed_word_char = true end
    if not is_whitespace(c) then consumed_non_whitespace = true end

    if char_idx == early_exit then
      return char_idx
    end
  end
  return char_idx
end

local function forward_word_cursor(s, char_idx, word_chars)
  return new_cursor(s, char_idx, 1, word_chars)
end

local function backward_word_cursor(s, char_idx, word_chars)
  return new_cursor(s, char_idx, -1, word_chars)
end

local function build_trie_node()
  return {
    terminal = false,
    children = {},
  }
end

local function build_trie(ss)
  -- This is a byte trie, not a display character trie.
  local result = build_trie_node()
  for _, s in ipairs(ss) do
    local node = result
    for byte_idx = 1, #s do
      local c = s:sub(byte_idx, byte_idx)
      if not node.children[c] then
        node.children[c] = build_trie_node()
      end
      node = node.children[c]
    end
    node.terminal = true
  end
  return result
end

local function backward_line_stops(s, stop_patterns)
  local result = {}
  table.insert(result, 0)

  local first_stop = cursor_col_at_end_of_leading_whitespace(s)
  if first_stop > result[#result] then
    table.insert(result, first_stop)
  end

  local node = build_trie(stop_patterns)
  local byte_idx = vim.fn.byteidx(s, first_stop) + 1 -- one-based
  local hit = false

  -- XXX: Does not work if the empty string is included as a pattern, which is a stupid case anyway.
  while byte_idx <= #s do
    local next_node = node.children[s:sub(byte_idx, byte_idx)]
    if not next_node then
      break
    end

    node = next_node
    byte_idx = byte_idx + 1

    if node.terminal then
      hit = true
      break
    end
  end

  -- Now, byte_idx points past the hit, if there is one.

  if hit then
    local num_chars = vim.fn.strchars(s)
    local char_idx = vim.fn.charidx(s, byte_idx - 1) -- zero-based
    while char_idx < num_chars and is_whitespace(get_char(s, char_idx)) do
      char_idx = char_idx + 1
    end

    if char_idx > result[#result] then
      table.insert(result, char_idx)
    end
  end

  return result
end

function readline._run_tests()
  local messages = {}
  local function pl(s) table.insert(messages, {s .. '\n'}) end
  pl('Running tests')

  local function assert_ints_equal(actual, expected)
    if actual == expected then
      pl(string.format('Ok %d == %d', actual, expected))
    else
      pl(string.format('❌ Expected %d, got %d', expected, actual))
    end
  end

  do
    pl('Testing forward_word_cursor')
    assert_ints_equal(forward_word_cursor('hello', 0, alphanum), 5)
    assert_ints_equal(forward_word_cursor('a b c', 0, alphanum), 1)
    assert_ints_equal(forward_word_cursor('a b c', 1, alphanum), 3)
    assert_ints_equal(forward_word_cursor('a b c', 2, alphanum), 3)
    assert_ints_equal(forward_word_cursor('a b c', 3, alphanum), 5)
    assert_ints_equal(forward_word_cursor('a b c', 4, alphanum), 5)
    assert_ints_equal(forward_word_cursor('a b c', 5, alphanum), 5)
    assert_ints_equal(forward_word_cursor('  ', 0, alphanum), 2)
    assert_ints_equal(forward_word_cursor('  ', 1, alphanum), 2)
    assert_ints_equal(forward_word_cursor('  ', 2, alphanum), 2)
    assert_ints_equal(forward_word_cursor(' x ', 0, alphanum), 2)
    assert_ints_equal(forward_word_cursor(' x ', 1, alphanum), 2)
    assert_ints_equal(forward_word_cursor(' x ', 2, alphanum), 3)
    assert_ints_equal(forward_word_cursor(' x ', 3, alphanum), 3)
    assert_ints_equal(forward_word_cursor('xx ', 0, alphanum), 2)
    assert_ints_equal(forward_word_cursor('xx ', 1, alphanum), 2)
    assert_ints_equal(forward_word_cursor('xx ', 2, alphanum), 3)
    assert_ints_equal(forward_word_cursor('xx ', 3, alphanum), 3)
    assert_ints_equal(forward_word_cursor(' xx', 0, alphanum), 3)
    assert_ints_equal(forward_word_cursor(' xx', 1, alphanum), 3)
    assert_ints_equal(forward_word_cursor(' xx', 2, alphanum), 3)
    assert_ints_equal(forward_word_cursor(' xx', 3, alphanum), 3)
  end

  do
    pl('Testing backward_word_cursor')
    assert_ints_equal(backward_word_cursor('hello', 5, alphanum), 0)
    assert_ints_equal(backward_word_cursor('a b c', 0, alphanum), 0)
    assert_ints_equal(backward_word_cursor('a b c', 1, alphanum), 0)
    assert_ints_equal(backward_word_cursor('a b c', 2, alphanum), 0)
    assert_ints_equal(backward_word_cursor('a b c', 3, alphanum), 2)
    assert_ints_equal(backward_word_cursor('a b c', 4, alphanum), 2)
    assert_ints_equal(backward_word_cursor('a b c', 5, alphanum), 4)
    assert_ints_equal(backward_word_cursor('  ', 0, alphanum), 0)
    assert_ints_equal(backward_word_cursor('  ', 1, alphanum), 0)
    assert_ints_equal(backward_word_cursor('  ', 2, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' x ', 0, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' x ', 1, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' x ', 2, alphanum), 1)
    assert_ints_equal(backward_word_cursor(' x ', 3, alphanum), 1)
    assert_ints_equal(backward_word_cursor('xx ', 0, alphanum), 0)
    assert_ints_equal(backward_word_cursor('xx ', 1, alphanum), 0)
    assert_ints_equal(backward_word_cursor('xx ', 2, alphanum), 0)
    assert_ints_equal(backward_word_cursor('xx ', 3, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' xx', 0, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' xx', 1, alphanum), 0)
    assert_ints_equal(backward_word_cursor(' xx', 2, alphanum), 1)
    assert_ints_equal(backward_word_cursor(' xx', 3, alphanum), 1)
  end

  vim.api.nvim_echo(messages, true, {})
end

local function start_of_next_line()
  if command_line_mode() or curr_line_no() == num_lines() then
    return curr_line_no(), curr_cursor_col()
  else
    local new_line_no = curr_line_no() + 1
    local new_cursor_col = cursor_col_at_end_of_leading_whitespace(get_line(new_line_no))
    return new_line_no, new_cursor_col
  end
end

local function forward_word_location(word_chars)
  if curr_cursor_col() == last_cursor_col_on_curr_line() then
    return start_of_next_line()
  else
    return curr_line_no(), forward_word_cursor(curr_line(), curr_cursor_col(), word_chars)
  end
end

local function end_of_previous_line()
  if command_line_mode() or curr_line_no() == 1 then
    return curr_line_no(), curr_cursor_col()
  else
    local new_line_no = curr_line_no() - 1
    local new_cursor_col = cursor_col_at_start_of_trailing_whitespace(get_line(new_line_no))
    return new_line_no, new_cursor_col
  end
end

local function backward_word_location(word_chars)
  if curr_cursor_col() == 0 then
    return end_of_previous_line()
  else
    return curr_line_no(), backward_word_cursor(curr_line(), curr_cursor_col(), word_chars)
  end
end

local function feed_keys(s)
  -- The idea is that this accepts strings like '<Left><CR>xyz' and does the right thing.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, true, true), '', false)
  -- Is there really no better way of doing this?
end

local function command_line_motion(new_cursor_col, motion)
  local old_cursor_col = curr_cursor_col()
  if new_cursor_col < old_cursor_col then
    local key = (motion == 'move') and '<Left>' or '<BS>'
    feed_keys(string.rep(key, old_cursor_col - new_cursor_col))
  elseif old_cursor_col < new_cursor_col then
    local key = (motion == 'move') and '<Right>' or '<Del>'
    feed_keys(string.rep(key, new_cursor_col - old_cursor_col))
  end
end

local function move_cursor_to(line_no, cursor_col)
  if command_line_mode() then
    assert(line_no == nil)
    command_line_motion(cursor_col, 'move')
  else
    vim.fn.setcursorcharpos(line_no, cursor_col + 1)
  end
end

local function breakundo()
  -- Thanks, Bram.
  -- XXX: https://github.com/vim/vim/pull/10511
  -- XXX: https://github.com/neovim/neovim/issues/18828
  vim.o.undolevels = vim.o.undolevels
end

local function yank_to_small_delete_register(cursor_col_1, cursor_col_2)
  if cursor_col_1 == cursor_col_2 then
    return
  end

  -- Yank the contents of the current line between these two cursor columns into the small delete register. The two columns can appear in either order.
  local left = math.min(cursor_col_1, cursor_col_2)
  local right = math.max(cursor_col_1, cursor_col_2)
  local killed_text = curr_line():sub(left+1, right)
  vim.fn.setreg('-', killed_text, 'c')
end

local function kill_to(end_line_no, end_cursor_col)
  -- Kill the text to the cursor positions. The cursor positrion is zero-based. The cursor will be left in the correct place.

  local start_line_no = curr_line_no()
  local start_cursor_col = curr_cursor_col()

  if end_line_no == start_line_no and end_cursor_col == start_cursor_col then
    return
  end

  -- XXX: This sort-of assumes that we won't kill across more than two lines, etc.
  yank_to_small_delete_register(start_cursor_col,
    (end_line_no == start_line_no and end_cursor_col) or
    (end_line_no  > start_line_no and last_cursor_col_on_curr_line()) or
    (end_line_no  < start_line_no and 0))

  if command_line_mode() then
    -- XXX: Is it possible to support undo for Command-line mode kills?
    command_line_motion(end_cursor_col, 'delete')
  else
    breakundo()

    -- Kill the text.
    local start_byte_idx = vim.fn.byteidx(get_line(start_line_no), start_cursor_col)
    local end_byte_idx = vim.fn.byteidx(get_line(end_line_no), end_cursor_col)

    local ltr = start_line_no < end_line_no or (start_line_no == end_line_no and start_cursor_col < end_cursor_col)

    if ltr then
      vim.api.nvim_buf_set_text(0, start_line_no - 1, start_byte_idx, end_line_no - 1, end_byte_idx, {})
      vim.fn.setcursorcharpos(start_line_no, start_cursor_col + 1)
    else
      vim.api.nvim_buf_set_text(0, end_line_no - 1, end_byte_idx, start_line_no - 1, start_byte_idx, {})
      vim.fn.setcursorcharpos(end_line_no, end_cursor_col + 1)
    end
  end
end

local function dwim_beginning_of_line_pos(roll_to_previous_line)
  local stops = backward_line_stops(curr_line(), get_stop_patterns())
  local cursor_col = curr_cursor_col()
  for i, stop in ipairs(stops) do
    if cursor_col <= stop then
      if i == 1 then
        if roll_to_previous_line then
          return end_of_previous_line()
        else
          return curr_line_no(), stops[#stops]
        end
      else
        return curr_line_no(), stops[i - 1]
      end
    end
  end
  return curr_line_no(), stops[#stops]
end

function readline.forward_word()
  move_cursor_to(forward_word_location(get_word_chars()))
end

function readline.backward_word()
  move_cursor_to(backward_word_location(get_word_chars()))
end

function readline.end_of_line()
  move_cursor_to(curr_line_no(), last_cursor_col_on_curr_line())
end

function readline.beginning_of_line()
  move_cursor_to(curr_line_no(), 0)
end

function readline.dwim_beginning_of_line()
  move_cursor_to(dwim_beginning_of_line_pos())
end

function readline.back_to_indentation()
  move_cursor_to(curr_line_no(), cursor_col_at_end_of_leading_whitespace(curr_line()))
end

function readline.kill_word()
  kill_to(forward_word_location(get_word_chars()))
end

function readline.backward_kill_word()
  kill_to(backward_word_location(get_word_chars()))
end

function readline.unix_word_rubout()
  kill_to(backward_word_location('NON_WHITESPACE_CHARS'))
end

function readline.kill_line()
  kill_to(curr_line_no(), last_cursor_col_on_curr_line())
end

function readline.backward_kill_line()
  kill_to(curr_line_no(), 0)
end

function readline.dwim_backward_kill_line()
  kill_to(dwim_beginning_of_line_pos(true))
end

return readline
