_ = require 'underscore-plus'

{Disposable, CompositeDisposable} = require 'atom'
Base = require './base'
{moveCursorLeft} = require './utils'
settings = require './settings'
{CurrentSelection, Select, MoveToRelativeLine} = {}
{OperationStackError, OperatorError, OperationAbortedError} = require './errors'

class OperationStack
  constructor: (@vimState) ->
    {@editor, @editorElement} = @vimState
    CurrentSelection ?= Base.getClass('CurrentSelection')
    Select ?= Base.getClass('Select')
    MoveToRelativeLine ?= Base.getClass('MoveToRelativeLine')
    @reset()

  subscribe: (args...) ->
    @subscriptions.add args...

  composeOperation: (operation) ->
    {mode} = @vimState
    switch
      when operation.isOperator()
        if (mode is 'visual') and not operation.hasTarget() # don't want to override target
          operation = operation.setTarget(new CurrentSelection(@vimState))
      when operation.isTextObject()
        unless mode is 'operator-pending'
          operation = new Select(@vimState, target: operation)
      when operation.isMotion()
        if (mode is 'visual')
          operation = new Select(@vimState, target: operation)
    operation

  run: (klass, properties={}) ->
    try
      switch type = typeof(klass)
        when 'string', 'function'
          klass = Base.getClass(klass) if type is 'string'
          # When identical operator repeated, it set target to MoveToRelativeLine.
          #  e.g. `dd`, `cc`, `gUgU`
          klass = MoveToRelativeLine if (@peekTop()?.constructor is klass)
          operation = @composeOperation(new klass(@vimState, properties))
        when 'object' # . repeat case
          operation = klass
          # console.log operation.getName()
        else
          throw new Error('Unsupported type of operation')

      @stack.push(operation)
      @process()
    catch error
      @handleError(error)

  runRecorded: ->
    if operation = @getRecorded()
      operation.setRepeated()
      if @vimState.hasCount()
        count = @vimState.getCount()
        operation.count = count
        operation.target?.count = count # Some opeartor have no target like ctrl-a(increase).
      @run(operation)

  handleError: (error) ->
    @vimState.reset()
    unless error instanceof OperationAbortedError
      throw error

  isProcessing: ->
    @processing

  process: ->
    @processing = true
    if @stack.length > 2
      throw new Error('Operation stack must not exceeds 2 length')

    try
      @reduce()
      top = @peekTop()

      if top.isComplete()
        # console.log [top.getName(), top.target?.getName()]
        @execute(@stack.pop())
      else
        if @vimState.isMode('normal') and top.isOperator()
          @vimState.activate('operator-pending')
          @addToClassList('with-occurrence') if top.isWithOccurrence()

        # Temporary set while command is running
        if commandName = top.constructor.getCommandNameWithoutPrefix?()
          @addToClassList(commandName + "-pending")
    catch error
      switch
        when error instanceof OperatorError
          @vimState.resetNormalMode()
        when error instanceof OperationStackError
          @vimState.resetNormalMode()
        else
          throw error

  addToClassList: (className) ->
    @editorElement.classList.add(className)
    @subscribe new Disposable =>
      @editorElement.classList.remove(className)

  execute: (operation) ->
    execution = operation.execute()
    if execution instanceof Promise
      finish = => @finish(operation)
      handleError = => @handleError()
      execution
        .then(finish)
        .catch(handleError)
    else
      @finish(operation)

  cancel: ->
    if @vimState.mode not in ['visual', 'insert']
      @vimState.resetNormalMode()
    @finish()

  ensureAllSelectionsAreEmpty: (operation) ->
    unless @editor.getLastSelection().isEmpty()
      if settings.get('throwErrorOnNonEmptySelectionInNormalMode')
        throw new Error("Selection is not empty in normal-mode: #{operation.toString()}")
      else
        @editor.clearSelections()

  ensureAllCursorsAreNotAtEndOfLine: ->
    for cursor in @editor.getCursors() when cursor.isAtEndOfLine()
      # [FIXME] SCATTERED_CURSOR_ADJUSTMENT
      moveCursorLeft(cursor, {preserveGoalColumn: true})

  finish: (operation=null) ->
    @record(operation) if operation?.isRecordable()
    @vimState.emitter.emit('did-finish-operation')

    if @vimState.isMode('normal')
      @ensureAllSelectionsAreEmpty(operation)
      @ensureAllCursorsAreNotAtEndOfLine()
    if @vimState.isMode('visual')
      @vimState.modeManager.updateNarrowedState()
    @vimState.updateCursorsVisibility()
    @vimState.reset()

  peekTop: ->
    _.last(@stack)

  reduce: ->
    until @stack.length < 2
      operation = @stack.pop()
      unless @peekTop().setTarget?
        throw new OperationStackError("The top operation in operation stack is not operator!")
      @peekTop().setTarget(operation)

  reset: ->
    @stack = []
    @processing = false
    @subscriptions?.dispose()
    @subscriptions = new CompositeDisposable

  destroy: ->
    @subscriptions?.dispose()
    {@stack, @subscriptions} = {}

  isEmpty: ->
    @stack.length is 0

  record: (@recorded) ->

  getRecorded: ->
    @recorded

  setOperatorModifier: (modifier) ->
    # In operator-pending-mode, stack length is always 1 and its' operator.
    # So either of @stack[0] or @peekTop() is OK.
    if @vimState.isMode('operator-pending')
      @stack[0].setOperatorModifier(modifier)

module.exports = OperationStack
