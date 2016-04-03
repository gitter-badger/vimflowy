# imports
if module?
  global._ = require('lodash')
  global.Promise = require('bluebird')

  global.Modes = require('./modes.coffee')
  global.mutations = require('./mutations.coffee')
  global.constants = require('./constants.coffee')
  global.errors = require('./errors.coffee')
  global.Cursor = require('./cursor.coffee')
  global.Data = require('./data.coffee')
  global.dataStore = require('./datastore.coffee')
  global.Register = require('./register.coffee')
  global.Logger = require('./logger.coffee')
  global.EventEmitter = require('./eventEmitter.coffee')

###
a View represents the actual viewport onto the vimflowy document
It holds a Cursor, a Data object, and a Settings object
It exposes methods for manipulation of the document, and movement of the cursor
It also handles rendering of everything, including settings.

Currently, the separation between the View and Data classes is not very good.  (see data.coffee)
Ideally, view shouldn't do much more than handle cursors and rendering
###

renderLine = (lineData, options = {}) ->
  options.cursors ?= {}
  options.highlights ?= {}

  results = []

  # ideally this takes up space but is unselectable (uncopyable)
  cursorChar = ' '

  line = []

  # add cursor if at end
  if lineData.length of options.cursors
    lineData.push {char: cursorChar}

  if lineData.length == 0
    return results

  for obj, i in lineData
    info = {
      column: i
    }
    renderOptions = {}

    for property in constants.text_properties
      if obj[property]
        renderOptions[property] = true

    x = obj.char

    if obj.char == '\n'
      # tricky logic for rendering new lines within a bullet
      # (copies correctly, works when cursor is on the newline itself)
      x = ''
      info.break = true
      if i of options.cursors
        x = cursorChar + x

    if i of options.cursors
      renderOptions.cursor = true
    else if i of options.highlights
      renderOptions.highlight = true

    info.char = x
    info.renderOptions = renderOptions

    line.push info

  # collect set of words, { word: word, start: start, end: end }
  word_chars = []
  word_start = 0

  urlRegex = /^https?:\/\/[^\s]+\.[^\s]+$/

  for obj, i in lineData.concat [{char: ' '}] # to make end condition easier
    # TODO  or (utils.isPunctuation obj.char)
    # problem is URLs have dots in them...
    if (utils.isWhitespace obj.char)
      if i != word_start
        word_info = {
          word: word_chars.join('')
          start: word_start
          end: i - 1
        }
        if options.wordHook?
          line = options.wordHook line, word_info
        if urlRegex.test word_info.word
          for j in [word_info.start..word_info.end]
            line[j].renderOptions.type = 'a'
            line[j].renderOptions.href = word_info.word
      word_start = i + 1
      word_chars = []
    else
      word_chars.push(obj.char)

  if options.lineHook?
    line = options.lineHook line

  renderSpec = []
  # Normally, we collect things of the same type and render them in one div
  # If there are column-specific handlers, however, we must break up the div to handle
  # separate click events
  if options.charclick
    for x in line
      x.renderOptions.text = x.char
      if not x.renderOptions.onclick
        x.renderOptions.onclick = options.charclick.bind @, x.column
      renderSpec.push x.renderOptions
      if x.break
        renderSpec.push {type: 'div'}
  else
    acc = []
    renderOptions = {}

    flush = () ->
      if acc.length
        renderOptions.text = acc.join('')
        renderSpec.push renderOptions
        acc = []
      renderOptions = {}

    # collect line into groups to render
    for x in line
      if JSON.stringify(x.renderOptions) == JSON.stringify(renderOptions)
        acc.push(x.char)
      else
        do flush
        acc.push(x.char)
        renderOptions = x.renderOptions

      if x.break
        do flush
        renderSpec.push {type: 'div'}
    do flush

  for spec in renderSpec
    classes = spec.classes or []
    type = spec.type or 'span'
    if type == 'a'
      classes.push 'theme-text-link'

    # make sure .bold, .italic, .strikethrough, .underline correspond to the text properties
    for property in constants.text_properties
      if spec[property]
        classes.push property

    if spec.cursor
      classes.push 'theme-cursor'
    if spec.highlight
      classes.push 'theme-bg-highlight'

    divoptions = {}
    if classes.length
      divoptions.className = (classes.join ' ')
    if spec.href
      divoptions.href = spec.href
    if spec.onclick
      divoptions.onclick = spec.onclick
    if options.linemouseover
      divoptions.onmouseover = options.linemouseover

    results.push virtualDom.h type, divoptions, spec.text

  return results
window?.renderLine = renderLine

(() ->
  MODES = Modes.modes

  class View extends EventEmitter
    containerDivID = (id) ->
      return 'node-' + id

    rowDivID = (id) ->
      return 'node-' + id + '-row'

    childrenDivID = (id) ->
      return 'node-' + id + '-children'

    constructor: (data, options = {}) ->
      super

      @data = data

      @bindings = options.bindings

      @mainDiv = options.mainDiv
      @settings = options.settings
      @keybindingsDiv = options.keybindingsDiv
      @messageDiv = options.messageDiv
      @menuDiv = options.menuDiv
      @modeDiv = options.modeDiv
      @pluginsDiv = options.pluginsDiv

      @register = new Register @

      @ready = (@data.getChildren @data.viewRoot).then((children) =>
        if not children.length
          return @data.load constants.empty_data
        do Promise.resolve
      ).then(() =>
        # load children again, now that data is loaded
        @data.getChildren @data.viewRoot
      ).then((children) =>
        console.log('got children', children)
        row = children[0]
        console.log('making cursor', row)
        @cursor = new Cursor @, row, 0
        @cursor.ready
      ).then(() =>
        console.log('resetting history')
        do @reset_history
        console.log('resetting jump history')
        do @reset_jump_history
        console.log('setting mode')

        @setMode MODES.NORMAL

        if @mainDiv?
          @vtree = do @virtualRender
          @vnode = virtualDom.create @vtree
          @mainDiv.append @vnode
      )

      return @

    exit: () ->
      @emit "exit"

    ###################
    # settings related
    ###################

    showingSettings: () ->
      return @settings and (not @settings.mainDiv.hasClass('hidden'))

    hideSettings: () ->
      $('#settings-icon').addClass('fa-cog').removeClass('fa-arrow-left')
      $('#settings-text').text 'Settings'
      @modeDiv.removeClass 'hidden'
      @settings.mainDiv.addClass 'hidden'

    showSettings: () ->
      $('#settings-icon').addClass('fa-arrow-left').removeClass('fa-cog')
      $('#settings-text').text 'Back'
      @modeDiv.addClass 'hidden'
      @settings.mainDiv.removeClass 'hidden'

    selectSettingsTab: (tab) ->
      @settings.mainDiv.find('.tabs > li').removeClass('active')
      @settings.mainDiv.find('.tab-pane').removeClass('active')
      @settings.mainDiv.find(".tabs > li[data-tab=#{tab}]").addClass('active')
      @settings.mainDiv.find(".tab-pane##{tab}").addClass('active')

    settingsToggle: () ->
      if do @showingSettings
        do @hideSettings
      else
        do @showSettings

    handleSettings: (key) ->
      if key == 'esc'
        do @hideSettings
        return true
      if key.length > 1
        return false
      do @hideSettings
      return true

    #################
    # modes related
    #################

    setMode: (mode) ->
      if mode == @mode
        return

      if @mode
        (Modes.getMode @mode).exit @

      @mode = mode
      (Modes.getMode @mode).enter @

      if @modeDiv
        @modeDiv.text (Modes.getMode @mode).name
      if @bindings
        @bindings.renderModeTable mode

    toggleBindingsDiv: () ->
      @keybindingsDiv.toggleClass 'active'
      @data.store.setSetting 'showKeyBindings', @keybindingsDiv.hasClass 'active'
      if @bindings
        @bindings.renderModeTable @mode

    #################
    # show message
    #################

    showMessage: (message, options = {}) ->
      options.time ?= 5000
      Logger.logger.info "Showing message: #{message}"
      if @messageDiv
        clearTimeout @messageDivTimeout

        @messageDiv.text(message)
        if options.text_class
          @messageDiv.addClass("text-#{options.text_class}")

        @messageDivTimeout = setTimeout (() =>
          @messageDiv.text('')
          @messageDiv.removeClass()
        ), options.time

    #################
    # import/export #
    #################

    parseJson: (content) ->
      try
        root = JSON.parse(content)
      catch
        @showMessage "The uploaded file is not valid JSON", {text_class: 'error'}
        return false
      verify = (node) ->
        if node.clone
          return true
        unless node.text || node.text == '' then return false
        if node.children
          for child in node.children
            unless verify child then return false
        return true
      unless verify root
        @showMessage "The uploaded file is not in a valid vimflowy format", {text_class: 'error'}
        return false
      return root

    parsePlaintext: (content) ->
      # Step 1: parse into (int, string) pairs of indentation amounts.
      lines = []
      for line in content.split "\n"
        if line.match /^\s*".*"$/ # Flag workflowy annotations as special cases
          lines.push
            indent: (line.match whitespace)[0].length
            line: line.replace /^\s*"(.*)"$/, "$1"
            annotation: true
          continue
        whitespace = /^\s*/
        # TODO: record whether COMPLETE and strikethrough line if so?
        lines.push
            indent: (line.match whitespace)[0].length
            line: (line.replace whitespace, "").replace /^(?:-\s*)?(?:\[COMPLETE\] )?/, ""
      while lines[lines.length-1].line == '' # Strip trailing blank line(s)
        lines = lines.splice(0, lines.length-1)

      # Step 2: convert a list of (int, string, annotation?) into a forest format
      parseAllChildren = (parentIndentation, lineNumber) ->
        children = []
        if lineNumber < lines.length and lines[lineNumber].annotation # Each node can have an annotation immediately follow it
          children.push
            text: lines[lineNumber].line
          lineNumber = lineNumber + 1
        while lineNumber < lines.length and lines[lineNumber].indent > parentIndentation # For [the first line of] each child
          child =
            text: lines[lineNumber].line
          result = parseAllChildren lines[lineNumber].indent, lineNumber + 1
          lineNumber = result.lineNumber
          if result.children?
            child.children = result.children
            child.collapsed = result.children.length > 0
          children.push child
        return { children: children, lineNumber: lineNumber}
      forest = (parseAllChildren -1, 0).children
      root =
        text: ""
        children: forest
        collapsed: (forest.length > 0)
      return root

    parseContent: (content, mimetype) ->
      if mimetype in ['application/json']
        return @parseJson content
      else if mimetype in ['text/plain', 'Text']
        return @parsePlaintext content
      else
        return null

    # TODO: make this use replace_empty = true?
    importContent: (content, mimetype) ->
      root = @parseContent content, mimetype
      if not root then return false
      row = @cursor.row
      if root.text == '' && root.children # Complete export, not one node
        @addBlocks row, 0, root.children
      else
        @addBlocks row, 0, [root]
      do @save
      do @render
      return true

    exportContent: (mimetype) ->
      jsonContent = do @data.serialize
      if mimetype == 'application/json'
          delete jsonContent.viewRoot
          return JSON.stringify(jsonContent, undefined, 2)
      else if mimetype == 'text/plain'
          # Workflowy compatible plaintext export
          #   Ignores 'collapsed' and viewRoot
          indent = "  "
          exportLines = (node) ->
              if typeof(node) == 'string'
                return ["- #{node}"]
              lines = []
              lines.push "- #{node.text}"
              for child in node.children ? []
                  if child.clone
                      continue
                  for line in exportLines child
                      lines.push "#{indent}#{line}"
              return lines
          return (exportLines jsonContent).join "\n"
      else
          throw new errors.UnexpectedValue "mimetype", mimetype

    # MUTATIONS

    reset_history: () ->
      @mutations = [] # full mutation history
      @history = [{
        index: 0
      }]
      @historyIndex = 0 # index into indices

    save: () ->
      if @historyIndex != @history.length - 1
          # haven't acted, otherwise would've sliced
          return
      if @history[@historyIndex].index == @mutations.length
          # haven't acted, otherwise there would be more mutations
          return

      state = @history[@historyIndex]
      state.after = {
        cursor: do @cursor.clone
        viewRoot: @data.viewRoot
      }

      @historyIndex += 1
      @history.push {
        index: @mutations.length
      }

    restoreViewState: (state) ->
      @cursor.from state.cursor
      if @mode != MODES.INSERT
        do @cursor.backIfNeeded
      @_changeView state.viewRoot

    undo: () ->
      if @historyIndex > 0
        oldState = @history[@historyIndex]
        @historyIndex -= 1
        newState = @history[@historyIndex]

        Logger.logger.debug "UNDOING ("
        for i in [(oldState.index-1)...(newState.index-1)]
            mutation = @mutations[i]
            Logger.logger.debug "  Undoing mutation #{mutation.constructor.name}(#{mutation.str()})"
            mutation.rewind @
        Logger.logger.debug ") END UNDO"
        @restoreViewState newState.before

    redo: () ->
      if @historyIndex < @history.length - 1
        oldState = @history[@historyIndex]
        @historyIndex += 1
        newState = @history[@historyIndex]

        Logger.logger.debug "REDOING ("
        for i in [oldState.index...newState.index]
            mutation = @mutations[i]
            Logger.logger.debug "  Redoing mutation #{mutation.constructor.name}(#{mutation.str()})"
            if not mutation.validate @
                # this should not happen, since the state should be the same as before
                throw new errors.GenericError "Failed to redo mutation: #{mutation.str()}"
            mutation.remutate @
        Logger.logger.debug ") END REDO"
        @restoreViewState oldState.after

    do: (mutation) ->
      if not @history
        # NOTE: we let mutations through since some plugins may apply mutations on load
        # these mutations won't be undoable, which is desired
        Logger.logger.warn "Tried mutation #{mutation} before init!"
        mutation.mutate @
        return true

      if @historyIndex != @history.length - 1
          @history = @history.slice 0, (@historyIndex + 1)
          @mutations = @mutations.slice 0, @history[@historyIndex].index

      state = @history[@historyIndex]
      if @mutations.length == state.index
        state.before = {
          cursor: do @cursor.clone
          viewRoot: @data.viewRoot
        }

      Logger.logger.debug "Applying mutation #{mutation.constructor.name}(#{mutation.str()})"
      if not mutation.validate @
          return false
      mutation.mutate @
      @mutations.push mutation
      return true

    curLine: () ->
      @data.getLine @cursor.row

    curText: () ->
      @data.getText @cursor.row

    curLineLength: () ->
      @data.getLength @cursor.row

    reset_jump_history: () ->
      @jumpHistory = [{
        viewRoot: @data.viewRoot
        cursor_before: do @cursor.clone
      }]
      @jumpIndex = 0 # index into jump history

    addToJumpHistory: (jump_fn) ->
      jump = @jumpHistory[@jumpIndex]
      jump.cursor_after = do @cursor.clone

      @jumpHistory = @jumpHistory.slice 0, (@jumpIndex+1)

      do jump_fn

      @jumpHistory.push {
        viewRoot: @data.viewRoot
        cursor_before: do @cursor.clone
      }
      @jumpIndex += 1

    # try going to jump, return true if succeeds
    tryJump: (jump) ->
      if jump.viewRoot.id == @data.viewRoot.id
        return false # not moving, don't jump

      if not @data.isAttached jump.viewRoot.id
        return false # invalid location

      children = @data.getChildren jump.viewRoot
      if not children.length
        return false # can't root, don't jump

      @data.changeViewRoot jump.viewRoot
      @cursor.setRow children[0]

      if @data.isAttached jump.cursor_after.row.id
        # if the row is attached and under the view root, switch to it
        cursor_row = @data.youngestVisibleAncestor jump.cursor_after.row
        if cursor_row != null
          @cursor.setRow cursor_row
      return true

    jumpPrevious: () ->
      jumpIndex = @jumpIndex

      jump = @jumpHistory[jumpIndex]
      jump.cursor_after = do @cursor.clone

      while true
        if jumpIndex == 0
          return false
        jumpIndex -= 1
        oldjump = @jumpHistory[jumpIndex]
        if @tryJump oldjump
          @jumpIndex = jumpIndex
          return true

    jumpNext: () ->
      jumpIndex = @jumpIndex

      jump = @jumpHistory[jumpIndex]
      jump.cursor_after = do @cursor.clone

      while true
        if jumpIndex == @jumpHistory.length - 1
          return false
        jumpIndex += 1
        newjump = @jumpHistory[jumpIndex]
        if @tryJump newjump
          @jumpIndex = jumpIndex
          return true

    # try to change the view root to row
    # fails if there is no child
    # records in jump history
    _changeView: (row) ->
      if row.id == @data.viewRoot.id
        return true # not moving, do nothing
      if @data.hasChildren row
        @addToJumpHistory () =>
          @data.changeViewRoot row
        return true
      return false

    # try to root into newroot, updating the cursor
    reroot: (newroot = @data.root) ->
      if @_changeView newroot
        newrow = @data.youngestVisibleAncestor @cursor.row
        if newrow == null # not visible, need to reset cursor
          newrow = (@data.getChildren newroot)[0]
        @cursor.setRow newrow
        return true
      return false

    # try rerooting to row, otherwise reroot to its parent
    rootInto: (row = @cursor.row) ->
      if @reroot row
        return true
      else
        return @rootToParent row

    # set cursor to row, changing view to its parent
    rootToParent: (row = @cursor.row) ->
      parent = do row.getParent
      if @reroot parent
        @cursor.setRow row
        return true
      throw new errors.GenericError "Failed to root into #{row}"

    rootUp: () ->
      if @data.viewRoot.id != @data.root.id
        parent = do @data.viewRoot.getParent
        @reroot parent

    rootDown: () ->
      newroot = @data.oldestVisibleAncestor @cursor.row
      if @reroot newroot
        return true
      return false

    addChars: (row, col, chars, options) ->
      @do new mutations.AddChars row, col, chars, options

    addCharsAtCursor: (chars, options) ->
      @addChars @cursor.row, @cursor.col, chars, options

    addCharsAfterCursor: (chars, options) ->
      col = @cursor.col
      if col < (@data.getLength @cursor.row)
        col += 1
      @addChars @cursor.row, col, chars, options

    delChars: (row, col, nchars, options = {}) ->
      n = @data.getLength row
      deleted = []
      if (n > 0) and (nchars > 0) and (col < n)
        mutation = new mutations.DelChars row, col, nchars, options
        @do mutation
        deleted = mutation.deletedChars
        if options.yank
          @register.saveChars deleted
      return deleted

    delCharsBeforeCursor: (nchars, options) ->
      nchars = Math.min(@cursor.col, nchars)
      return @delChars @cursor.row, (@cursor.col-nchars), nchars, options

    delCharsAfterCursor: (nchars, options) ->
      return @delChars @cursor.row, @cursor.col, nchars, options

    replaceCharsAfterCursor: (char, nchars, options) ->
      deleted = @delCharsAfterCursor nchars, {cursor: {pastEnd: true}}
      chars = []
      for obj in deleted
        newobj = _.clone obj
        newobj.char = char
        chars.push newobj
      @addCharsAtCursor chars, options

    yankChars: (row, col, nchars) ->
      line = @data.getLine row
      if line.length > 0
        @register.saveChars line.slice(col, col + nchars)

    # options:
    #   - includeEnd says whether to also delete cursor2 location
    yankBetween: (cursor1, cursor2, options = {}) ->
      if not (cursor2.row.is cursor1.row)
        Logger.logger.warn "Not yet implemented"
        return

      if cursor2.col < cursor1.col
        [cursor1, cursor2] = [cursor2, cursor1]

      offset = if options.includeEnd then 1 else 0
      @yankChars cursor1.row, cursor1.col, (cursor2.col - cursor1.col + offset)

    # options:
    #   - includeEnd says whether to also delete cursor2 location
    deleteBetween: (cursor1, cursor2, options = {}) ->
      if not (cursor2.row.is cursor1.row)
        Logger.logger.warn "Not yet implemented"
        return

      if cursor2.col < cursor1.col
        [cursor1, cursor2] = [cursor2, cursor1]
      offset = if options.includeEnd then 1 else 0
      @delChars cursor1.row, cursor1.col, (cursor2.col - cursor1.col + offset), options

    # toggling text properties
    # if new_value is null, should be inferred based on old values
    toggleProperty: (property, new_value, row, col, n) ->
      deleted = @delChars row, col, n, {setCursor: 'stay'}

      if new_value == null
        all_were_true = _.every deleted.map ((obj) => return obj[property])
        new_value = not all_were_true

      chars = []
      for obj in deleted
        newobj = _.clone obj
        newobj[property] = new_value
        chars.push newobj
      @addChars row, col, chars, {setCursor: 'stay'}

    toggleRowsProperty: (property, rows) ->
      all_were_true = _.every rows.map ((row) =>
        _.every (@data.getLine row).map ((obj) => return obj[property])
      )
      new_value = not all_were_true
      for row in rows
        @toggleProperty property, new_value, row, 0, (@data.getLength row)

    toggleRowProperty: (property, row = @cursor.row) ->
      @toggleProperty property, null, row, 0, (@data.getLength row)

    toggleRowPropertyBetween: (property, cursor1, cursor2, options) ->
      if not (cursor2.row.is cursor1.row)
        Logger.logger.warn "Not yet implemented"
        return

      if cursor2.col < cursor1.col
        [cursor1, cursor2] = [cursor2, cursor1]

      offset = if options.includeEnd then 1 else 0
      @toggleProperty property, null, cursor1.row, cursor1.col, (cursor2.col - cursor1.col + offset)

    newLineBelow: () ->
      children = @data.getChildren @cursor.row
      if (not @data.collapsed @cursor.row) and children.length > 0
        @addBlocks @cursor.row, 0, [''], {setCursor: 'first'}
      else
        parent = do @cursor.row.getParent
        index = @data.indexOf @cursor.row
        @addBlocks parent, (index+1), [''], {setCursor: 'first'}

    newLineAbove: () ->
      parent = do @cursor.row.getParent
      index = @data.indexOf @cursor.row
      @addBlocks parent, index, [''], {setCursor: 'first'}

    # behavior of "enter", splitting a line
    newLineAtCursor: () ->
      mutation = new mutations.DelChars @cursor.row, 0, @cursor.col
      @do mutation
      row = @cursor.row

      do @newLineAbove
      # cursor now is at inserted row, add the characters
      @addCharsAfterCursor mutation.deletedChars
      # restore cursor
      @cursor.set row, 0, {keepProperties: true}

    joinRows: (first, second, options = {}) ->
      for child in @data.getChildren second by -1
        # NOTE: if first is collapsed, should we uncollapse?
        @moveBlock child, first, 0

      line = @data.getLine second
      if line.length and options.delimiter
        if line[0].char != options.delimiter
          line = [{char: options.delimiter}].concat line
      @delBlock second, {noNew: true, noSave: true}

      newCol = @data.getLength first
      mutation = new mutations.AddChars first, newCol, line
      @do mutation

      @cursor.set first, newCol, options.cursor

    joinAtCursor: () ->
      row = @cursor.row
      sib = @data.nextVisible row
      if sib != null
        @joinRows row, sib, {cursor: {pastEnd: true}, delimiter: ' '}

    # implements proper "backspace" behavior
    deleteAtCursor: () ->
      if @cursor.col == 0
        row = @cursor.row
        sib = @data.prevVisible row
        if sib != null
          @joinRows sib, row, {cursor: {pastEnd: true}}
      else
        @delCharsBeforeCursor 1, {cursor: {pastEnd: true}}

    delBlock: (row, options) ->
       @delBlocks row.parent, (@data.indexOf row), 1, options

    delBlocks: (parent, index, nrows, options = {}) ->
      mutation = new mutations.DetachBlocks parent, index, nrows, options
      @do mutation
      unless options.noSave
        @register.saveClonedRows mutation.deleted

    delBlocksAtCursor: (nrows, options = {}) ->
      parent = do @cursor.row.getParent
      index = @data.indexOf @cursor.row
      @delBlocks parent, index, nrows, options

    addBlocks: (parent, index = -1, serialized_rows, options = {}) ->
      mutation = new mutations.AddBlocks parent, index, serialized_rows, options
      @do mutation

    yankBlocks: (row, nrows) ->
      siblings = @data.getSiblingRange row, 0, (nrows-1)
      siblings = siblings.filter ((x) -> return x != null)
      serialized = siblings.map ((x) => return @data.serialize x)
      @register.saveSerializedRows serialized

    yankBlocksAtCursor: (nrows) ->
      @yankBlocks @cursor.row, nrows

    yankBlocksClone: (row, nrows) ->
      siblings = @data.getSiblingRange row, 0, (nrows-1)
      siblings = siblings.filter ((x) -> return x != null)
      @register.saveClonedRows (siblings.map (sibling) -> sibling.id)

    yankBlocksCloneAtCursor: (nrows) ->
      @yankBlocksClone @cursor.row, nrows

    attachBlocks: (parent, ids, index = -1, options = {}) ->
      mutation = new mutations.AttachBlocks parent, ids, index, options
      @do mutation

    moveBlock: (row, parent, index = -1, options = {}) ->
      [commonAncestor, rowAncestors, cursorAncestors] = @data.getCommonAncestor row, @cursor.row
      moved = @do new mutations.MoveBlock row, parent, index, options
      if moved
        # Move the cursor also, if it is in the moved block
        if commonAncestor.is row
          newCursorRow = @data.combineAncestry row, (x.id for x in cursorAncestors)
          @cursor._setRow newCursorRow
      return row

    indentBlocks: (row, numblocks = 1) ->
      newparent = @data.getSiblingBefore row
      unless newparent?
        @showMessage "Cannot indent without higher sibling", {text_class: 'error'}
        return null # cannot indent

      if @data.collapsed newparent
        @toggleBlock newparent

      siblings = @data.getSiblingRange row, 0, (numblocks-1)
      for sib in siblings
        @moveBlock sib, newparent, -1
      return newparent

    unindentBlocks: (row, numblocks = 1, options = {}) ->
      parent = do row.getParent
      if parent.id == @data.viewRoot.id
        @showMessage "Cannot unindent past root", {text_class: 'error'}
        return null

      siblings = @data.getSiblingRange row, 0, (numblocks-1)

      newparent = do parent.getParent
      pp_i = @data.indexOf parent

      for sib in siblings
        pp_i += 1
        @moveBlock sib, newparent, pp_i
      return newparent

    indent: (row = @cursor.row) ->
      if @data.collapsed row
        return @indentBlocks row

      sib = @data.getSiblingBefore row

      newparent = @indentBlocks row
      unless newparent?
        return
      for child in (@data.getChildren row).slice()
        @moveBlock child, sib, -1

    unindent: (row = @cursor.row) ->
      if @data.collapsed row
        return @unindentBlocks row

      if @data.hasChildren row
        @showMessage "Cannot unindent line with children", {text_class: 'error'}
        return

      parent = do row.getParent
      p_i = @data.indexOf row

      newparent = @unindentBlocks row
      unless newparent?
        return

      p_children = @data.getChildren parent
      for child in p_children.slice(p_i)
        @moveBlock child, row, -1

    swapDown: (row = @cursor.row) ->
      next = @data.nextVisible (@data.lastVisible row)
      unless next?
        return

      if (@data.hasChildren next) and (not @data.collapsed next)
        # make it the first child
        @moveBlock row, next, 0
      else
        # make it the next sibling
        parent = do next.getParent
        p_i = @data.indexOf next
        @moveBlock row, parent, (p_i+1)

    swapUp: (row = @cursor.row) ->
      prev = @data.prevVisible row
      unless prev?
        return

      # make it the previous sibling
      parent = do prev.getParent
      p_i = @data.indexOf prev
      @moveBlock row, parent, p_i

    toggleCurBlock: () ->
      @toggleBlock @cursor.row

    toggleBlock: (row) ->
      @do new mutations.ToggleBlock row

    pasteBefore: (options = {}) ->
      options.before = true
      @register.paste options

    pasteAfter: (options = {}) ->
      @register.paste options

    scrollPages: (npages) ->
      # TODO:  find out height per line, figure out number of lines to move down, scroll down corresponding height
      line_height = do $('.node-text').height
      if line_height == 0
        line_height = 21 # ugly hack... 0 happens when first line is empty, currently
      page_height = do $(document).height
      height = npages * page_height

      numlines = Math.round(height / line_height)
      numlines = Math.max(Math.min(numlines, 1000), -1000) # guard against craziness

      if numlines > 0
        for i in [1..numlines]
          do @cursor.down
      else
        for i in [-1..numlines]
          do @cursor.up

      @scrollMain (line_height * numlines)

    scrollMain: (amount) ->
       # # animate.  seems to not actually be great though
       # @mainDiv.stop().animate({
       #     scrollTop: @mainDiv[0].scrollTop + amount
       #  }, 50)
       @mainDiv.scrollTop(@mainDiv.scrollTop() + amount)

    scrollIntoView: (el) ->
      elemTop = el.getBoundingClientRect().top
      elemBottom = el.getBoundingClientRect().bottom

      margin = 50
      top_margin = margin
      bottom_margin = margin + $('#bottom-bar').height()

      if elemTop < top_margin
         # scroll up
         @scrollMain (elemTop - top_margin)
      else if elemBottom > window.innerHeight - bottom_margin
         # scroll down
         @scrollMain (elemBottom - window.innerHeight + bottom_margin)

    getVisibleRows: () ->
      rows = []
      for bullet in $.makeArray($('.bullet'))
          if not (utils.isScrolledIntoView $(bullet), @mainDiv)
              continue
          if $(bullet).hasClass 'fa-clone'
              continue
          # NOTE: can't use $(x).data
          # http://stackoverflow.com/questions/25876274/jquery-data-not-working
          ancestry = $(bullet).attr('data-ancestry')
          if not ancestry # as far as i know, this only happens because of menu mode
              continue
          row = Row.loadFromAncestry JSON.parse ancestry
          rows.push row
      return rows

    # given an anchor and cursor, figures out the right blocks to be deleting
    # returns a parent, minindex, and maxindex
    getVisualLineSelections: () ->
      [common, ancestors1, ancestors2] = @data.getCommonAncestor @cursor.row, @anchor.row
      if ancestors1.length == 0
        # anchor is underneath cursor
        parent = do common.getParent
        index = @data.indexOf @cursor.row
        return [parent, index, index]
      else if ancestors2.length == 0
        # cursor is underneath anchor
        parent = do common.getParent
        index = @data.indexOf @anchor.row
        return [parent, index, index]
      else
        index1 = @data.indexOf (ancestors1[0] ? @cursor.row)
        index2 = @data.indexOf (ancestors2[0] ? @anchor.row)
        if index2 < index1
          [index1, index2] = [index2, index1]
        return [common, index1, index2]

    ##################
    # RENDERING
    ##################

    render: (options = {}) ->
      if @menu
        do @menu.render
        return

      t = Date.now()
      vtree = @virtualRender options
      patches = virtualDom.diff @vtree, vtree
      @vnode = virtualDom.patch @vnode, patches
      @vtree = vtree
      Logger.logger.debug 'Rendering: ', !!options.handle_clicks, (Date.now()-t)

      cursorDiv = $('.theme-cursor', @mainDiv)[0]
      if cursorDiv
        @scrollIntoView cursorDiv

      return

    virtualRender: (options = {}) ->
      crumbs = []
      row = @data.viewRoot
      until row.is @data.root
        console.log('building crumbs', row)
        crumbs.push row
        row = do row.getParent
      console.log('crumbs', crumbs)

      makeCrumb = (row, text, isLast) =>
        m_options = {}
        if @mode == MODES.NORMAL and not isLast
          m_options.className = 'theme-text-link'
          m_options.onclick = () =>
            @reroot row
            do @save
            do @render
        return virtualDom.h 'span', { className: 'crumb' }, [
                 virtualDom.h 'span', m_options, [ text ]
               ]

      crumbNodes = []
      crumbNodes.push(makeCrumb @data.root, (virtualDom.h 'icon', {className: 'fa fa-home'}))
      p = do Promise.resolve
      (i for i in [crumbs.length-1..0] by -1).forEach (i) =>
        p = p.then () =>
          row = crumbs[i]
          console.log('crumb row', row)
          (@data.getText row).then (chars) =>
            text = chars.join('')
            crumbNodes.push(makeCrumb row, text, i==0)
      p.then () =>
        breadcrumbsNode = virtualDom.h 'div', {
          id: 'breadcrumbs'
        }, crumbNodes

        options.ignoreCollapse = true # since we're the root, even if we're collapsed, we should render

        options.highlight_blocks = {}
        if @lineSelect
          # mirrors logic of finishes_visual_line in keyHandler.coffee
          [parent, index1, index2] = do @getVisualLineSelections
          for child in @data.getChildRange parent, index1, index2
            options.highlight_blocks[child.id] = true

        (@virtualRenderTree @data.viewRoot, options).then (contentsChildren) =>
          contentsNode = virtualDom.h 'div', {
            id: 'treecontents'
          }, contentsChildren

          virtualDom.h 'div', {}, [breadcrumbsNode, contentsNode]

    virtualRenderTree: (parent, options = {}) ->
      if (not options.ignoreCollapse) and (@data.collapsed parent)
        return

      childrenNodes = []

      Promise.map (@data.getChildren parent), (row) =>
        rowElements = []

        if @data.isClone row.id
          cloneIcon = virtualDom.h 'i', { className: 'fa fa-clone bullet clone-icon', title: 'Cloned' }
          rowElements.push cloneIcon

        ancestry_str = JSON.stringify do row.getAncestry

        icon = 'fa-circle'
        if @data.hasChildren row
          icon = if @data.collapsed row then 'fa-plus-circle' else 'fa-minus-circle'

        bulletOpts = {
          className: 'fa ' + icon + ' bullet'
          attributes: {'data-id': row.id, 'data-ancestry': ancestry_str}
        }
        if @data.hasChildren row
          bulletOpts.style = {cursor: 'pointer'}
          bulletOpts.onclick = ((row) =>
            @toggleBlock row
            do @save
            do @render
          ).bind(@, row)

        bullet = virtualDom.h 'i', bulletOpts
        bullet = @applyHook 'renderBullet', bullet, { row: row }

        rowElements.push bullet

        elLine = virtualDom.h 'div', {
          id: rowDivID row.id
          className: 'node-text'
        }, (@virtualRenderLine row, options)
        rowElements.push elLine

        options.ignoreCollapse = false
        children = virtualDom.h 'div', {
          id: childrenDivID row.id
          className: 'node-children'
        }, (@virtualRenderTree row, options)
        rowElements.push children

        className = 'node'
        if row.id of options.highlight_blocks
          className += ' theme-bg-highlight'

        rowElements = @applyHook 'renderRowElements', rowElements, { row: row }

        childNode = virtualDom.h 'div', {
          id: containerDivID row.id
          className: className
        }, rowElements

        childNode

    virtualRenderLine: (row, options = {}) ->
      (@data.getLine row).then (lineData) =>
        cursors = {}
        highlights = {}

        if row.is @cursor.row
          cursors[@cursor.col] = true

          if @anchor and not @lineSelect
            if @anchor.row? and row.is @anchor.row
              for i in [@cursor.col..@anchor.col]
                highlights[i] = true
            else
              Logger.logger.warn "Multiline not yet implemented"

          cursors = @applyHook 'renderCursorsDict', cursors, { row: row }

        results = []

        lineoptions = {
          cursors: cursors
          highlights: highlights
        }

        if options.handle_clicks
          if @mode == MODES.NORMAL or @mode == MODES.INSERT
            lineoptions.charclick = (column) =>
              @cursor.set row, column
              # assume they might click again
              @render {handle_clicks: true}
        else if not options.no_clicks
          lineoptions.linemouseover = () =>
            @render {handle_clicks: true}

        lineoptions.wordHook = @applyHook.bind @, 'renderLineWordHook'
        lineoptions.lineHook = @applyHook.bind @, 'renderLineTextOptions'

        lineContents = renderLine lineData, lineoptions
        lineContents = @applyHook 'renderLineContents', lineContents, { row: row }
        [].push.apply results, lineContents

        infoChildren = @applyHook 'renderInfoElements', [], { row: row }
        info = virtualDom.h 'div', {
          className: 'node-info'
        }, infoChildren
        results.push info

        results = @applyHook 'renderLineElements', results, { row: row }
        return results

  # exports
  module?.exports = View
  window?.View = View
)()
