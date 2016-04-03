require 'blanket'
require 'coffee-script/register'
assert = require 'assert'
_ = require 'lodash'
fs = require 'fs'
path = require 'path'

dataStore = require '../assets/js/datastore.coffee'
Data = require '../assets/js/data.coffee'
View = require '../assets/js/view.coffee'
for file in fs.readdirSync path.resolve __dirname, '../assets/js/definitions'
  if (file.match /.*\.js$/) or (file.match /.*\.coffee$/)
    require path.join '../assets/js/definitions', file
KeyDefinitions = require '../assets/js/keyDefinitions.coffee'
KeyBindings = require '../assets/js/keyBindings.coffee'
KeyHandler = require '../assets/js/keyHandler.coffee'
Register = require '../assets/js/register.coffee'
Settings = require '../assets/js/settings.coffee'
Logger = require '../assets/js/logger.coffee'
Plugins = require '../assets/js/plugins.coffee'

# Logger.logger.setStream Logger.STREAM.QUEUE
# afterEach 'empty the queue', () ->
#   do Logger.logger.empty

class TestCase
  constructor: (serialized = [''], cb) ->
    console.log 'making store'
    @store = new dataStore.InMemory
    @data = new Data @store
    @data.ready.then () =>
      @settings =  new Settings @store

      # will have default bindings
      keyBindings = new KeyBindings (do KeyDefinitions.clone), @settings

      console.log 'here in test case 2'
      @view = new View @data, {bindings: keyBindings}
      console.log 'here in test case 3'
      @view.render = -> return

      @keyhandler = new KeyHandler @view, keyBindings
      @register = @view.register

      Plugins.resolveView @view
      for name of Plugins.plugins
        Plugins.enable name
      console.log 'here in test case 4'

      # NOTE: this is *after* resolveView because of plugins with state
      # e.g. marks needs the database to have the marks loaded
      console.log 'about to load serialized'
      @data.load serialized
      console.log 'load ed serialized'
      do @view.reset_history
      do @view.reset_jump_history
      do cb

  _expectDeepEqual: (actual, expected, message) ->
    if not _.isEqual actual, expected
      do Logger.logger.flush
      console.error "
        \nExpected:
        \n#{JSON.stringify(expected, null, 2)}
        \nBut got:
        \n#{JSON.stringify(actual, null, 2)}
      "
      throw new Error message

  _expectEqual: (actual, expected, message) ->
    if actual != expected
      do Logger.logger.flush
      console.error "
        \nExpected:
        \n#{expected}
        \nBut got:
        \n#{actual}
      "
      throw new Error message

  sendKeys: (keys) ->
    for key in keys
      @keyhandler.handleKey key
    return @

  sendKey: (key) ->
    @sendKeys [key]
    return @

  import: (content, mimetype) ->
    @view.importContent content, mimetype

  expect: (expected, cb) ->
    @keyhandler.on 'drain', () =>
      console.lo('drained!')
      serialized = @data.serialize @data.root, {pretty: true}
      @_expectDeepEqual serialized.children, expected, "Unexpected serialized content"
      do cb

  expectViewRoot: (expected) ->
    @_expectEqual @data.viewRoot.id, expected, "Unexpected view root"
    return @

  expectCursor: (row, col) ->
    @_expectEqual @view.cursor.row.id, row, "Unexpected cursor row"
    @_expectEqual @view.cursor.col, col, "Unexpected cursor col"
    return @

  expectJumpIndex: (index, historyLength = null) ->
    @_expectEqual @view.jumpIndex, index, "Unexpected jump index"
    if historyLength != null
      @_expectEqual @view.jumpHistory.length, historyLength, "Unexpected jump history length"
    return @

  expectNumMenuResults: (num_results) ->
    @_expectEqual @view.menu.results.length, num_results, "Unexpected number of results"
    return @

  setRegister: (value) ->
    @register.deserialize value
    return @

  expectRegister: (expected) ->
    current = do @register.serialize
    @_expectDeepEqual current, expected, "Unexpected register content"
    return @

  expectRegisterType: (expected) ->
    current = do @register.serialize
    @_expectDeepEqual current.type, expected, "Unexpected register type"
    return @

  expectExport: (fileExtension, expected) ->
    export_ = @view.exportContent fileExtension
    @_expectEqual export_, expected, "Unexpected export content"
    return @

module.exports = TestCase
