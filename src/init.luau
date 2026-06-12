--!strict
local DataStoreService = game:GetService("DataStoreService")

type Session<T> = {
	data: T,
	lock: {
		serverId: string,
		time: number,
	}?
}

type Store<T> = {
	_name: string,
	_template: T,
	_store: DataStore,
	_sessions: { [string]: Session<T> },

	loadSession: (store: Store<T>, player: Player) -> Session<T>,
	closeSession: (store: Store<T>, player: Player) -> (),
	getSession: (store: Store<T>, player: Player) -> Session<T>?,
}

local MAX_LOCK_RETRIES = 5
local MAX_RETRIES = 5
local AUTOSAVE_INTERVAL = 60
local LOCK_TIMEOUT = 120

local function getUserIdKey(player: Player)
	return tostring(player.UserId)
end

local function dataStoreRetry<T>(fn: () -> T): T
	for i = 1, MAX_RETRIES do
		task.wait(i)
		local sucess, result = pcall(fn)
		if sucess then
			return result
		end
	end
	error("DataStore operation failed after " .. MAX_RETRIES .. " retries.")
end

local function deepCopy<T>(original: T): T
	if type(original) ~= "table" then
		return original
	end
	local copy = {}
	for key, value in original do
		if type(value) == "table" then
			copy[key] = deepCopy(value)
		else
			copy[key] = value
		end
	end
	return copy :: any
end

local function reconcile<T>(target: any, template: any)
	for key, value in pairs(template) do
		if target[key] == nil then
			if type(value) == "table" then
				target[key] = {}
				reconcile(target[key], value)
			else
				target[key] = value
			end
		elseif type(target[key]) == "table" and type(value) == "table" then
			reconcile(target[key], value)
		end
	end
end


local function saveSessionByKey<T>(store: Store<T>, key: string, releaseLock: boolean)
	local session = store._sessions[key]
	if not session then return end

	dataStoreRetry(function()
		return store._store:UpdateAsync(key, function()
			if releaseLock then
				session.lock = nil
			else
				session.lock = {
					serverId = game.JobId,
					time = os.time()
				}
			end
			return session
		end)
	end)
end

local function loadSession<T>(store: Store<T>, player: Player): Session<T>
	local key = getUserIdKey(player)

	if store._sessions[key] then
		return store._sessions[key]
	end

	local session: Session<T>? = nil
	local lockRetries = 0
	
	while true do
		if not player.Parent then error("Player left during loading") end

		local lockFailed = false

		session = dataStoreRetry(function()
			return store._store:UpdateAsync(key, function(oldData: any)
				local currentSession: Session<T> = oldData or {
					data = deepCopy(store._template),
					lock = nil
				}

				if currentSession.lock and currentSession.lock.serverId ~= game.JobId then
					if os.time() - currentSession.lock.time > LOCK_TIMEOUT then
						currentSession.lock = { serverId = game.JobId, time = os.time() }
						return currentSession
					end

					lockFailed = true
					return currentSession 
				end
				currentSession.lock = { serverId = game.JobId, time = os.time() }
				return currentSession
			end)
		end) :: any

		if lockFailed then
			session = nil
			lockRetries += 1
			if lockRetries >= MAX_LOCK_RETRIES then
				error("Session is locked by another server and max retries reached.")
			end
		end

		if session then 
			break
		end

		task.wait(2)
	end

	local finalSession = session :: Session<T>

	reconcile(finalSession.data, store._template)

	store._sessions[key] = finalSession

	return finalSession 
end

local function closeSession<T>(store: Store<T>, player: Player)
	local key = getUserIdKey(player)
	if store._sessions[key] then
		pcall(function()
			saveSessionByKey(store, key, true)
		end)
		store._sessions[key] = nil
	end
end

local function getSession<T>(store: Store<T>, player: Player): Session<T>?
	local key = getUserIdKey(player)
	return store._sessions[key]
end

local function createStore<T>(name: string, template: T) : Store<T>
	local store = {
		_name = name,
		_template = template,
		_store = DataStoreService:GetDataStore(name),
		_sessions = {},
		loadSession = loadSession,
		closeSession = closeSession,
		getSession = getSession
	} :: Store<T>

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for key, _ in store._sessions do
				pcall(function()
					saveSessionByKey(store, key, false)
				end)
			end
		end
	end)

	return store 
end

return {
	createStore = createStore
}