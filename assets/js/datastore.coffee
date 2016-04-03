if module?
  global._ = require('lodash')
  global.errors = require('./errors.coffee')
  global.Logger = require('./logger.coffee')

###
DataStore abstracts the data layer, so that it can be swapped out.
There are many methods the each type of DataStore should implement to satisfy the API.
However, in the case of a key-value store, one can simply implement `get` and `set` methods.
NOTE: it is assumed that all gets can be asynchronous, but that
sets then allow immediate retrieval!  Thus it is required that you maintain an
in-memory cache
###
((exports) ->
  class DataStore
    constructor: (prefix='') ->
      @_schemaVersion_ = 1

      @prefix = "#{prefix}save"

      @_lineKey_ = (row) -> "#{@prefix}:#{row}:line"
      @_parentKey_ = (row) -> "#{@prefix}:#{row}:parent"
      @_childrenKey_ = (row) -> "#{@prefix}:#{row}:children"
      @_collapsedKey_ = (row) -> "#{@prefix}:#{row}:collapsed"

      @_pluginDataKey_ = (plugin, key) -> "#{@prefix}:plugin:#{plugin}:data:#{key}"
      @_pluginDataVersionKey_ = (plugin) -> "#{@prefix}:plugin:#{plugin}:version"

      # no prefix, meaning it's global
      @_settingKey_ = (setting) -> "settings:#{setting}"

      @_lastSaveKey_ = "#{@prefix}:lastSave"
      @_lastViewrootKey_ = "#{@prefix}:lastviewroot2"
      @_macrosKey_ = "#{@prefix}:macros"
      @_IDKey_ = "#{@prefix}:lastID"
      @_schemaVersionKey_ = "#{@prefix}:schemaVersion"
      do @validateSchemaVersion

    get: (key, default_value=null) ->
        throw new errors.NotImplemented

    set: (key, value) ->
        throw new errors.NotImplemented

    # get and set values for a given row
    getLine: (row) ->
      (@get (@_lineKey_ row), []).then (val) =>
        Promise.resolve _.cloneDeep val
    setLine: (row, line) ->
      @set (@_lineKey_ row), line

    getParents: (row) ->
      parents = @get (@_parentKey_ row), []
      if typeof parents == 'number'
        parents = [ parents ]
      parents
    setParents: (row, parents) ->
      @set (@_parentKey_ row), parents

    getChildren: (row) ->
      (@get (@_childrenKey_ row), []).then (val) =>
        Promise.resolve _.cloneDeep val
    setChildren: (row, children) ->
      @set (@_childrenKey_ row), children

    getCollapsed: (row) ->
      @get (@_collapsedKey_ row)
    setCollapsed: (row, collapsed) ->
      @set (@_collapsedKey_ row), collapsed

    # get mapping of macro_key -> macro
    getMacros: () ->
      @get @_macrosKey_, {}

    # set mapping of macro_key -> macro
    setMacros: (macros) ->
      @set @_macrosKey_, macros

    # get global settings (data not specific to a document)
    getSetting: (setting) ->
      @get (@_settingKey_ setting)
    setSetting: (setting, value) ->
      @set (@_settingKey_ setting), value

    # get last view (for page reload)
    setLastViewRoot: (ancestry) ->
      @set @_lastViewrootKey_, ancestry
    getLastViewRoot: () ->
      console.log('getting last view root')
      @get @_lastViewrootKey_, []

    setSchemaVersion: (version) ->
      @set @_schemaVersionKey_, version
    getSchemaVersion: () ->
      @get @_schemaVersionKey_, 1

    setPluginDataVersion: (plugin, version) ->
      @set (@_pluginDataVersionKey_ plugin), version
    getPluginDataVersion: (plugin) ->
      @get (@_pluginDataVersionKey_ plugin)
    setPluginData: (plugin, key, data) ->
      @set (@_pluginDataKey_ plugin, key), data
    getPluginData: (plugin, key, default_value=null) ->
      (@get (@_pluginDataKey_ plugin, key), default_value).then (val) =>
        Promise.resolve _.cloneDeep val

    # get next row ID
    getId: () -> # Suggest to override this for efficiency
      throw new errors.NotImplemented

    getNew: () ->
      (do @getId).then (id) ->
        @setLine id, []
        @setChildren id, []
        Promise.resolve id

    validateSchemaVersion: () ->
      storedVersion = do @getSchemaVersion
      if not storedVersion? and (@getChildren 0).length == 0
        @setSchemaVersion @_schemaVersion_
        return
      else if storedVersion > @_schemaVersion_
        throw new errors.SchemaVersion "The stored data was made with a newer version of vimflowy. Please upgrade vimflowy to use this format."
      else if storedVersion < @_schemaVersion_
        throw new errors.SchemaVersion "The stored data was made with an older version of vimflowy, and no migration paths exist. Please report this as a bug."
      else if storedVersion == @_schemaVersion_
        return

  class InMemory extends DataStore
    constructor: () ->
      @cache = {}
      super ''

    get: (key, default_value = null) ->
      val = default_value
      if key of @cache
        val = @cache[key]
      Promise.resolve val

    set: (key, value) ->
      @cache[key] = value
      do Promise.resolve

    getId: () ->
      (@get @_IDKey_, 1).then (id) =>
        @set @_IDKey_, (id + 1)
        Promise.resolve id

  class LocalStorageLazy extends DataStore
    constructor: (prefix='') ->
      @cache = {}
      super prefix
      @lastSave = do Date.now

    get: (key, default_value=null) ->
      if not (key of @cache)
        @cache[key] = @_getLocalStorage_ key, default_value
      Promise.resolve @cache[key]

    set: (key, value) ->
      @cache[key] = value
      @_setLocalStorage_ key, value
      do Promise.resolve

    _setLocalStorage_: (key, value, options={}) ->
      if (do @getLastSave) > @lastSave
        alert '
          This document has been modified (in another tab) since opening it in this tab.
          Please refresh to continue!
        '
        throw new errors.DataPoisoned 'Last save disagrees with cache'

      unless options.doesNotAffectLastSave
        @lastSave = Date.now()
        localStorage.setItem @_lastSaveKey_, @lastSave

      Logger.logger.debug 'setting local storage', key, value
      localStorage.setItem key, JSON.stringify value

    _getLocalStorage_: (key, default_value) ->
      Logger.logger.debug 'getting from local storage', key, default_value
      stored = localStorage.getItem key
      if stored == null
        Logger.logger.debug 'got nothing, defaulting to', default_value
        return default_value
      try
        val = JSON.parse stored
        Logger.logger.debug 'got ', val
        return val
      catch
        Logger.logger.debug 'parse failure:', stored
        return default_value

    # determine last time saved (for multiple tab detection)
    # doesn't cache!
    getLastSave: () ->
      @_getLocalStorage_ @_lastSaveKey_, 0

    setSchemaVersion: (version) ->
      @_setLocalStorage_ @_schemaVersionKey_, version, { doesNotAffectLastSave: true }

    getId: () ->
      (@_getLocalStorage_ @_IDKey_, 1).then (id) =>
        @_setLocalStorage_ @_IDKey_, (id + 1)
        Promise.resolve id

  exports.InMemory = InMemory
  exports.LocalStorageLazy = LocalStorageLazy
  # TODO: exports.ChromeStorageLazy = ChromeStorageLazy
)(if typeof exports isnt 'undefined' then exports else window.dataStore = {})
