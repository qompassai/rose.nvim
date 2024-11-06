local Spinner = {}
Spinner.__index = Spinner

--- Creates a new Spinner instance.
--- @param spinner_type string # The type of spinner to use.
--- @return table
function Spinner:new(spinner_type)
  local instance = setmetatable({}, self)
  instance.spinner_type = spinner_type
  instance.pattern = {
    ["dots"] = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    ["line"] = { "-", "\\", "|", "/" },
    ["star"] = { "✶", "✸", "✹", "✺", "✹", "✷" },
    ["bouncing_bar"] = {
      "[    ]",
      "[=   ]",
      "[==  ]",
      "[=== ]",
      "[ ===]",
      "[  ==]",
      "[   =]",
      "[    ]",
      "[   =]",
      "[  ==]",
      "[ ===]",
      "[====]",
      "[=== ]",
      "[==  ]",
      "[=   ]",
    },
    ["bouncing_ball"] = {
      "( ●    )",
      "(  ●   )",
      "(   ●  )",
      "(    ● )",
      "(     ●)",
      "(    ● )",
      "(   ●  )",
      "(  ●   )",
      "( ●    )",
      "(●     )",
    },
  }
  instance.interval = 80
  instance.current_frame = 1
  instance.timer = nil
  instance.message = ""
  return instance
end

--- Starts the spinner with an optional message.
--- @param message string|nil # The message to display alongside the spinner, optional.
--- @param opts table|nil # Optional configuration parameters.
function Spinner:start(message, opts)
  if self.timer then
    return
  end

  -- Allow configuration override
  opts = opts or {}
  self.message = message or ""
  self.spinner_type = opts.spinner_type or self.spinner_type
  self.interval = opts.interval or self.interval
  self.position = opts.position or "right"
  -- Add color support
  self.highlight = opts.highlight or "None"

  -- Add progress indicator
  self.progress = {
    current = 0,
    total = opts.total or 0,
    show = opts.show_progress or false
  }

  -- Create timer
  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.interval,
    vim.schedule_wrap(function()
      self.current_frame = (self.current_frame % #self.pattern[self.spinner_type]) + 1

      -- Update progress if enabled
      if self.progress.show then
        self.progress.current = math.min(self.progress.current + 1, self.progress.total)
      end

      self:draw()

      -- Call tick callback if provided
      if self.on_tick then
        self.on_tick(self.current_frame)
      end
    end)
  )

  -- Add optional callbacks
  self.on_complete = opts.on_complete
  self.on_tick = opts.on_tick
end

--- Stops the spinner and clears the display.
function Spinner:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
    self:clear()

    -- Call on_complete callback if provided
    if self.on_complete then
      self.on_complete()
    end
  end
end

--- Draws the current frame of the spinner.
function Spinner:draw()
  local spinner_frame = self.pattern[self.spinner_type][self.current_frame]
  local progress_str = ""

  if self.progress.show then
    progress_str = string.format(" [%d/%d]", self.progress.current, self.progress.total)
  end

  vim.api.nvim_echo(
    { { string.format("\r%s %s%s", spinner_frame, self.message, progress_str), self.highlight } },
    false,
    {}
  )
  vim.cmd("redraw")
end

--- Clears the spinner display.
function Spinner:clear()
  vim.cmd('echon ""') -- Clear the current line
end

return Spinner

