local DataStoreService = game:GetService("DataStoreService")

local Util = require(game.ReplicatedStorage.Packages.Util)
local Promise = require(game.ReplicatedStorage.Packages.Promise)
local Trove = require(game.ReplicatedStorage.Packages.Trove)


local databases: {[string]: Database} = {}



local DatabaseRecord = {}
DatabaseRecord.__index = DatabaseRecord

type Data = {[string]: any}

export type DatabaseRecord = {
    Player: Player,
    Loaded: RBXScriptSignal,
    GetValueChangedEvent: (self: DatabaseRecord, key: string) -> RBXScriptSignal,
    GetDatabase: () -> Database,
    Load: (self: DatabaseRecord) -> DatabaseRecord,
    Save: (self: DatabaseRecord, data: Data?) -> nil,
    IsLoaded: (self: DatabaseRecord) -> boolean,
    GetValue: (self: DatabaseRecord, key: string) -> any?,
    SetValue: (self: DatabaseRecord, key: string, value: any) -> nil,
    _valueChangedEvents: {[string]: BindableEvent},
    _loadedEvent: BindableEvent,
    _databaseName: string,
    _data: Data?
}

function DatabaseRecord._new(player: Player, database: Database): DatabaseRecord
    local self = setmetatable({
        Player = player,
        _databaseName = database.Name,
        _trove = Trove.new(),
        _valueChangedEvents = {}
    }, DatabaseRecord)

    self._loadedEvent = self._trove:Add(Instance.new("BindableEvent") :: any)
    self.Loaded = self._loadedEvent.Event

    return self :: DatabaseRecord
end
function DatabaseRecord:GetDatabase(): Database
    return databases[self._databaseName]
end

function DatabaseRecord:Destroy()
    self._trove:Clean()
end

function DatabaseRecord:Load(): DatabaseRecord
    local database = self:GetDatabase()
    local _success, data = Promise.retryWithDelay(Promise.promisify(function()
        return database._datastore:GetAsync(tostring(self.Player.UserId))
    end), database.Settings.LoadAttempts, database.Settings.SaveLoadRetryDelay):catch(function(err)
        local message = `Loading {self.Player.Name}'s record of database "{database.Name}" failed, message: {tostring(err)}`
        if database.Settings.ShouldKickOnLoadFail then
            self.Player:Kick(message)
        end
        error(message)
    end):await()

    data = data or {}

    self._data = self._data or {}
    for key, value in pairs(data) do
        self:SetValue(key, value)
    end

    self._loadedEvent:Fire(self)

    return self :: DatabaseRecord
end
function DatabaseRecord:Save(data: Data?)
    data = data or self._data
    local database = self:GetDatabase()
    return Promise.retryWithDelay(Promise.promisify(function()
        return database._datastore:SetAsync(tostring(self.Player.UserId), data, {self.Player.UserId})
    end), database.Settings.SaveAttempts, database.Settings.SaveLoadRetryDelay):catch(function(err)
        error(`Saving {self.Player.Name}'s record of database "{database.Name}" for failed, message: {tostring(err)}`)
    end)
end

function DatabaseRecord:IsLoaded(): boolean
    return self._data ~= nil
end
function DatabaseRecord:GetValue(key: string): any?
    if self._data == nil then
        return
    end
    return self._data[key]
end
function DatabaseRecord:SetValue(key: string, value: any)
    if self._data == nil then
        return
    end
    local event = self._valueChangedEvents[key]
    if event then
        event:Fire(value)
    end
    self._data[key] = value
end

function DatabaseRecord:GetValueChangedEvent(key: string): RBXScriptSignal
    local event = self._valueChangedEvents[key]
    if not event then
        event = self._trove:Add(Instance.new("BindableEvent"))
        self._valueChangedEvents[key] = event
    end
    return event.Event
end



local Database = {}
Database.__index = Database

export type DatastoreSerializable = string | number | boolean | nil | {DatastoreSerializable} | {[string]: DatastoreSerializable}

export type DatabaseSettings = {
    ShouldAutosave: boolean,
    ShouldLoadOnJoin: boolean,
    ShouldSaveOnLeave: boolean,
    ShouldKickOnLoadFail: boolean,
    AutosavePeriod: number,
    SaveLoadRetryDelay: number,
    LoadAttempts: number,
    SaveAttempts: number
}
local DEFAULT_SETTINGS: DatabaseSettings = {
    ShouldAutosave = true,
    ShouldLoadOnJoin = true,
    ShouldSaveOnLeave = true,
    ShouldKickOnLoadFail = true,
    AutosavePeriod = 600,
    SaveLoadRetryDelay = 7,
    LoadAttempts = 5,
    SaveAttempts = 8
}

export type Database = {
    Name: string,
    Destroy: () -> nil,
    CreateRecord: (self: Database, player: Player) -> nil,
    GetRecord: (self: Database, player: Player) -> DatabaseRecord?,
    GetOrCreateRecord: (self: Database, player: Player) -> DatabaseRecord,
    RemoveRecord: (self: Database, player: Player) -> nil,
    GetAllRecords: (self: Database) -> {DatabaseRecord},
    Settings: DatabaseSettings,
    RecordLoaded: RBXScriptSignal,
    _recordLoadedEvent: BindableEvent,
    _datastore: GlobalDataStore,
    _records: {[Player]: DatabaseRecord},
    _autosaveThread: thread?
}

function Database.new(name: string, settings: DatabaseSettings?): Database
    local self = setmetatable({
        Name = name,
        Settings = if settings then Util.merge(DEFAULT_SETTINGS, settings) else DEFAULT_SETTINGS,
        _records = {},
        _trove = Trove.new()
    }, Database)
    
    self._datastore = self._trove:Add(DataStoreService:GetDataStore(name) :: any)
    if self.Settings.ShouldAutosave then
        self._autosaveThread = self._trove:Add(Util.every(self.Settings.AutosavePeriod, function(_delta)
            for _player, record in pairs(self._records) do
                if record:IsLoaded() then
                    record:Save()
                end
            end
        end) :: any)
    end

    self._recordLoadedEvent = self._trove:Add(Instance.new("BindableEvent") :: any)
    self.RecordLoaded = self._recordLoadedEvent.Event

    databases[name] = self :: Database
    return self :: Database
end

function Database:CreateRecord(player: Player)
    if self._records[player] ~= nil then
        return
    end
    local record = self._trove:Add(DatabaseRecord._new(player, self :: Database))
    self._records[player] = record
    self._trove:Add(record.Loaded:Connect(function(...)
        self._recordLoadedEvent:Fire(...)
    end))
    return record
end
function Database:GetRecord(player: Player): DatabaseRecord?
    return self._records[player]
end
function Database:GetOrCreateRecord(player: Player): DatabaseRecord
    local record = self:GetRecord(player)
    if not record then
        record = self:CreateRecord(player)
    end
    return record
end
function Database:RemoveRecord(player: Player)
    local record = self._records[player]
    if record then
        record:Destroy()
        self._records[player] = nil
    end
end

function Database:GetAllRecords(): {DatabaseRecord}
    return Util.objectValues(self._records)
end

function Database:Destroy()
    self._trove:Clean()
    databases[self.Name] = nil
end

Util.forPlayers(function(player)
    for _, database in pairs(databases) do
        if database.Settings.ShouldLoadOnJoin then
            database:GetOrCreateRecord(player):Load()
        end
    end
end)
game.Players.PlayerRemoving:Connect(function(player)
    for _, database in pairs(databases) do
        if database.Settings.ShouldSaveOnLeave then
            local record = database:GetRecord(player)
            if record then
                record:Save()
            end
        end
        database:RemoveRecord(player)
    end
end)

return Database