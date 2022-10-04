local char = string.char
local max = math.max
local min = math.min
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

local buf_get_name = vim.api.nvim_buf_get_name
local buf_get_option = vim.api.nvim_buf_get_option
local bufwinnr = vim.fn.bufwinnr
local command = vim.api.nvim_command
local getchar = vim.fn.getchar
local notify = vim.notify
local set_current_buf = vim.api.nvim_set_current_buf
local get_current_buf = require('bufferline.utils').get_current_buf

-- TODO: remove `vim.fs and` after 0.8 release
local normalize = vim.fs and vim.fs.normalize

--- @type bbye
local bbye = require('bufferline.bbye')

--- @type bufferline.JumpMode
local JumpMode = require('bufferline.jump_mode')

--- @type bufferline.render
local render = require('bufferline.render')

--- @type bufferline.state
local state = require('bufferline.state')

--- @type bufferline.utils
local utils = require('bufferline.utils')

--- Shows an error that `bufnr` was not among the `state.buffers`
--- @param bufnr integer
local function notify_buffer_not_found(bufnr)
  notify(
    'Current buffer (' .. bufnr .. ") not found in bufferline.nvim's list of buffers: " .. vim.inspect(state.buffers),
    vim.log.levels.ERROR,
    { title = 'barbar.nvim' }
  )
end

--- Forwards some `order_func` after ensuring that all buffers sorted in the order of pinned first.
--- @param order_func fun(bufnr_a: integer, bufnr_b: integer) accepts `(integer, integer)` params.
--- @return fun(bufnr_a: integer, bufnr_b: integer)
local function with_pin_order(order_func)
  return function(a, b)
    local a_pinned = state.is_pinned(a)
    local b_pinned = state.is_pinned(b)

    if a_pinned and not b_pinned then
      return true
    elseif b_pinned and not a_pinned then
      return false
    else
      return order_func(a, b)
    end
  end
end

--- @class bufferline.api
local api = {}

--- Close all open buffers, except the current one.
function api.close_all_but_current()
  local current_bufnr = get_current_buf()

  for _, bufnr in ipairs(state.buffers) do
    if bufnr ~= current_bufnr then
      bbye.bdelete(false, bufnr)
    end
  end
end

--- Close all open buffers, except pinned ones.
function api.close_all_but_pinned()
  for _, bufnr in ipairs(state.buffers) do
    if not state.is_pinned(bufnr) then
      bbye.bdelete(false, bufnr)
    end
  end
end

--- Close all open buffers, except pinned ones or the current one.
function api.close_all_but_current_or_pinned()
  local current_bufnr = get_current_buf()

  for _, bufnr in ipairs(state.buffers) do
    if not state.is_pinned(bufnr) and bufnr ~= current_bufnr then
      bbye.bdelete(false, bufnr)
    end
  end
end

--- Close all buffers which are visually left of the current buffer.
function api.close_buffers_left()
  local idx = utils.index_of(state.buffers, get_current_buf())
  if idx == nil or idx == 1 then
    return
  end

  for i = idx - 1, 1, -1 do
    bbye.bdelete(false, state.buffers[i])
  end
end

--- Close all buffers which are visually right of the current buffer.
function api.close_buffers_right()
  local idx = utils.index_of(state.buffers, get_current_buf())
  if idx == nil then
    return
  end

  for i = #state.buffers, idx + 1, -1 do
    bbye.bdelete(false, state.buffers[i])
  end
end

--- Set the current buffer to the `number`
--- @param index integer
function api.goto_buffer(index)
  render.get_updated_buffers()

  if index < 0 then
    index = #state.buffers - index + 1
  else
    index = math.max(1, math.min(index, #state.buffers))
  end

  set_current_buf(state.buffers[index])
end

--- Go to the buffer a certain number of buffers away from the current buffer.
--- Use a positive number to go "right", and a negative one to go "left".
--- @param steps integer
function api.goto_buffer_relative(steps)
  render.get_updated_buffers()

  local current = render.set_current_win_listed_buffer()

  local idx = utils.index_of(state.buffers, current)

  if idx == nil then
    print("Couldn't find buffer " .. current .. ' in the list: ' .. vim.inspect(state.buffers))
    return
  else
    idx = (idx + steps - 1) % #state.buffers + 1
  end

  set_current_buf(state.buffers[idx])
end

--- Move a buffer.
--- @param from_idx integer the buffer's original index.
--- @param to_idx integer the buffer's new index.
local function move_buffer(from_idx, to_idx)
  to_idx = max(1, min(#state.buffers, to_idx))
  if to_idx == from_idx then
    return
  end

  local bufnr = state.buffers[from_idx]

  table_remove(state.buffers, from_idx)
  table_insert(state.buffers, to_idx, bufnr)
  state.sort_pins_to_left()
end

--- Move the current buffer to the index specified.
--- @param idx integer
function api.move_current_buffer_to(idx)
  if idx == -1 then
    idx = #state.buffers
  end

  local current_bufnr = get_current_buf()
  local from_idx = utils.index_of(state.buffers, current_bufnr)

  if from_idx == nil then
    notify_buffer_not_found(current_bufnr)
    return
  end

  move_buffer(from_idx, idx)
end

--- Move the current buffer a certain number of times over.
--- @param steps integer
function api.move_current_buffer(steps)
  local current_bufnr = get_current_buf()
  local idx = utils.index_of(state.buffers, current_bufnr)

  if idx == nil then
    notify_buffer_not_found(current_bufnr)
    return
  end

  move_buffer(idx, idx + steps)
end

--- Order the buffers by their buffer number.
function api.order_by_buffer_number()
  table_sort(state.buffers, function(a, b)
    return a < b
  end)
end

--- Order the buffers by their parent directory.
function api.order_by_directory()
  table_sort(
    state.buffers,
    with_pin_order(function(a, b)
      local name_of_a = buf_get_name(a)
      local name_of_b = buf_get_name(b)
      local a_less_than_b = name_of_b < name_of_a

      -- TODO: remove this block after 0.8 releases
      if not normalize then
        local a_is_relative = utils.is_relative_path(name_of_a)
        if a_is_relative and utils.is_relative_path(name_of_b) then
          return a_less_than_b
        end

        return a_is_relative
      end

      local level_of_a = #vim.split(normalize(name_of_a), '/')
      local level_of_b = #vim.split(normalize(name_of_b), '/')

      if level_of_a ~= level_of_b then
        return level_of_a < level_of_b
      end

      return a_less_than_b
    end)
  )
end

--- Order the buffers by filetype.
function api.order_by_language()
  table_sort(
    state.buffers,
    with_pin_order(function(a, b)
      return buf_get_option(a, 'filetype') < buf_get_option(b, 'filetype')
    end)
  )
end

--- Order the buffers by their respective window number.
function api.order_by_window_number()
  table_sort(
    state.buffers,
    with_pin_order(function(a, b)
      return bufwinnr(buf_get_name(a)) < bufwinnr(buf_get_name(b))
    end)
  )
end

--- Activate the buffer pick mode.
function api.pick_buffer()
  if JumpMode.reinitialize then
    JumpMode.initialize_indexes()
  end

  local ok, byte = pcall(getchar)
  if ok then
    local letter = char(byte)

    if letter ~= '' then
      if JumpMode.buffer_by_letter[letter] ~= nil then
        set_current_buf(JumpMode.buffer_by_letter[letter])
      else
        notify("Couldn't find buffer", vim.log.levels.WARN, { title = 'barbar.nvim' })
      end
    end
  else
    notify('Invalid input', vim.log.levels.WARN, { title = 'barbar.nvim' })
  end
end

--- Offset the rendering of the bufferline
--- @param width integer the amount to offset
--- @param text? string text to put in the offset
--- @param hl? string
function api.set_offset(width, text, hl)
  state.offset = width > 0 and { hl = hl, text = text, width = width } or { hl = nil, text = nil, width = 0 }
end

--- Toggle the `bufnr`'s "pin" state, visually.
--- @param bufnr? integer
function api.toggle_pin(bufnr)
  state.toggle_pin(bufnr or 0)
  command('redrawstatus')
end

return api
