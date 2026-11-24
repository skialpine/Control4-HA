local Queue = {}
Queue.__index = Queue
Queue.LIMIT = 4

function Queue.new(limit)
  return setmetatable({ limit = limit or Queue.LIMIT, running = 0, head = 1, tail = 0, waiting = {} }, Queue)
end

function Queue:_drain()
  if self.draining then
    return
  end
  self.draining = true
  while self.running < self.limit and self.head <= self.tail do
    local job = self.waiting[self.head]
    self.waiting[self.head] = nil
    self.head = self.head + 1
    self.running = self.running + 1
    local finished = false
    local function release()
      if not finished then
        finished = true
        self.running = self.running - 1
        self:_drain()
      end
    end
    local ok = pcall(job.run, release)
    if not ok then
      pcall(job.discard, "failed")
      release()
    end
  end
  if self.head > self.tail then
    self.head, self.tail = 1, 0
  end
  self.draining = false
end

function Queue:push(run, discard)
  self.tail = self.tail + 1
  self.waiting[self.tail] = { run = run, discard = discard }
  self:_drain()
end

function Queue:clear()
  local waiting = self.waiting
  self.waiting, self.head, self.tail = {}, 1, 0
  for _, job in pairs(waiting) do
    job.discard("retired")
  end
end

return Queue
