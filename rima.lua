--
-- rima.lua
--

--
-- Task manager for imap collector.
-- Task's key is a user email address.
-- Rima can manage some tasks with the same key.
-- Tasks with identical keys will be groupped and managed as one bunch of tasks.
--
-- Producers can adds tasks by rima_put() calls.
-- Consumer request a bunch of tasks (with common key) by calling rima_get().
-- When Rima gives a task to worker it locks the key until worker calls rima_done(key).
-- Rima does not return task with already locked keys.
--

math.randomseed(box.time())

--
-- Put task to the queue.
--
function rima_put(key, data)
	box.auto_increment(0, key, data)
end

function rima_put_prio(key, data)
	box.auto_increment(0, key, data)
	box.replace(2, key)
end

local function get_random_key()
	for i = 1,100 do
		local v = box.space[0].index[0]:random(math.random(4294967296))
		if v == nil then return nil end -- no tuples in index
		local key = v[1]
		local exists = box.select(1, 0, key)
		if exists == nil then return key end
	end
	return nil
end

local function get_prio_key()
	local index = box.space[2].index[0]

	for _, v in index.idx.next, index.idx do
		local key = v[0]
		local exists = box.select(1, 0, key)
		if exists == nil and box.delete(2, key) ~= nil then return key end
	end

	return nil
end

local function rima_get_impl()
	local key = get_prio_key()
	if key == nil then key = get_random_key() end
	if key == nil then return true, nil, nil end

	local time = os.time()
	local status, _ = pcall(box.insert, 1, key, time)
	if not status then return false, nil, nil end

	local result = {}

	local tuples = { box.select_limit(0, 1, 0, 1000, key) }
	for _, tuple in pairs(tuples) do
		tuple = box.delete(0, tuple[0])
		if tuple ~= nil then table.insert(result, tuple[2]) end
	end

	return true, key, result
end

--
-- Request tasks from the queue.
--
function rima_get()
	for i = 1,100 do
		local status, key, result = rima_get_impl()
		if status then
			if result == nil then return end
			return key, unpack(result)
		end
	end
end

--
-- Notify manager that tasks for that key was completed.
-- Rima unlocks key and next rima_get() may returns tasks with such key.
--
function rima_done(key)
	box.delete(1, key)
end

--
-- Run expiration of tuples
--

local function is_expired(args, tuple)
	if tuple == nil or #tuple <= args.fieldno then
		return nil
	end
	local field = tuple[args.fieldno]
	local current_time = os.time()
	local tuple_expire_time = box.unpack('i', field) + args.expiration_time
	return current_time >= tuple_expire_time
end

local function delete_expired(spaceno, args, tuple)
	box.delete(spaceno, tuple[0])
end

dofile('expirationd.lua')

expirationd.run_task('expire_locks', 1, is_expired, delete_expired, {fieldno = 1, expiration_time = 30*60})
