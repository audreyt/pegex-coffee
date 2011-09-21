DEBUG = false

class Parser
  constructor:
    ( @receiver     = new Receiver
    , @throwOnError = true
    , @partial      = false
    , @wrap         = @receiver.wrap
    , @input        = ""
    , @buffer       = ""
    , @position     = 0
    , @debug        = DEBUG
    ) ->

  parse: (@input, startRule) ->
    throw "Usage: parse(input, [startRule]" unless @input
    throw "No 'grammar', can't parse" unless @grammar
    throw "No 'receiver', can't parse" unless @receiver

    @input = Input.new(@input).open() if typeof @input is 'string'
    @buffer = @input.read()
    @grammar = eval("new #{@grammar}") if typeof @grammar is 'string'
    @receiver = eval("new #{@receiver}") if typeof @receiver is 'string'

    startRule ||= (
      @grammar.tree['+top'] or
      (if @grammar.tree.TOP then 'TOP' else null)
    )

    throw "No starting rule for Pegex::Parser::parse" unless startRule

    @receiver.parser = @
    # TODO: require('weakref').weaken(@receiver.parser)

    # Do the parse
    match = @match(startRule)
    return unless match

    # Parse was successful!
    @input.close()
    return @receiver.data ? match

  match: (rule) ->
    @receiver.initialize?(rule)

    match = @matchNext('.ref': rule)
    if not match or @position < @buffer.length
      @throwError("Parse document failed for some reason")
      return;  # In case @throwOnError is off

    match = match[0]
    match = @receiver.finalize?(match, rule)
    unless match
      match = {}
      match[rule] = []
    if rule is 'TOP'
      match = match.TOP || match
    return match

  matchNext: (next) ->
    return @matchNextWithSep(next) if next['.sep']

    quantity = next['+qty'] || 1
    assertion = $next['+asr'] || false

    for key in ["ref", "rgx", "all", "any", "err"]
      rule = next[".#{key}"]
      continue unless rule
      kind = key
    throw "Cannot find a key: #{next}" unless kind

    [match, position, count, method] = [
      [], @position, 0, "match_#{kind}"
    ]

    while ret = @[method](rule, next)
      position = @position unless assertion
      $count++
      match.push.apply(match, ret)
      break if /^[1?]$/.test(quantity)

    if /^[+*]$/.test(quantity)
      match = [match]
      @position = position

    result = if count or /^[?*]$/.test(quantity) then true else false
    result = not result if assertion is -1

    @position = position if (not result) or assertion

    match = [] if next['-skip']
    return (if result then match else false)

  matchNextWithSep = (next) ->
    quantity = next['+qty'] || '1'
    for key in ["ref", "rgx", "all", "any", "err"]
      rule = next[".#{key}"]
      continue unless rule
      kind = key
    throw "Cannot find a key: #{next}" unless kind

    separator = next['.sep']
    for key in ["ref", "rgx", "all", "any", "err"]
      sepRule = separator[".#{key}"]
      continue unless sepRule
      sepKind = key
    throw "Cannot find a separator key: #{separator}" unless sepKind

    [match, position, count, sepCount, method, sepMethod] = [
      [], @position, 0, 0, "match_#{kind}", "match_#{sepKind}"
    ]

    while ret = @[method](rule, next)
      position = @position
      count++
      match.push.apply(match, ret)
      ret = @[sepMethod](sepRule, separator)
      break unless ret
      match.push.apply(match, ret)
      $sep_count++

    return (if quantity is '?' then [match] else false) unless count

    @position = position if count is sepCount

    match = [] if next['-skip']
    return [match]

  match_ref = (ref, parent) ->
    rule = @grammar.tree[ref]
    throw "\n\n*** No grammar support for '#{ref}'\n\n" unless rule

    trace = (not rule['+asr'] and @debug and @trace)
    trace?("try_#{ref}")

    match = @matchNext(rule)
    if not match
      trace?("not_#{ref}")
      return false

    # Call receiver callbacks
    trace?("got_#{ref}")
    if not rule['+asr'] and not parent['-skip']
      callback = "got_#{ref}"
      if sub = @receiver[callback]
        match = [ sub.call(@receiver, match[0]) ]
      else if (if @wrap then (not parent['-pass']) else parent['-wrap'])
        if match.length
          matched = match[0]
          match = {}
          match[ref] = matched
          match = [match]
        else
          match = []
    return match

  match_rgx = (regexp, parent) ->
    unless regexp.hasOwnProperty('lastIndex')
      @regexpCache[regexp] ||= new RegExp(regexp, 'g')
      regexp = @regexpCache[regexp]

    start = regexp.lastIndex = @position
    if start >= @buffer.length and @terminater++ > 1000
      throw "Your grammar seems to not terminate at end of stream"

    captures = regexp.exec(@buffer)
    finish = regexp.lastIndex

    numCaptures = captures.length - 1
    match = (captures[i] for i in [1..numCaptures])
    match = [ match ] if numCaptures > 1
    @position = finish

  match_all = (list, parent) ->
    pos = @position
    set = []
    len = 0
    for elem in list
      if match = @matchNext(elem)
        continue if elem['+asr'] or elem['-skip']
        set.push.apply(set, ret)
        len++
      else
        @position = $pos
        return false
    set = [ set ] if len > 1
    return set

  match_any = (list) ->
    for elem in list
      if match = @matchNext(elem)
        return match
    return false

  match_err = (error) ->
    @throwError error

  trace = (action) ->
    indent = /^try_/.test(action)
    @indent ||= 0
    @indent-- unless indent
    out = ''
    out += ' ' for [1..@indent]
    @indent++ if indent
    snippet = @buffer.substr(@position)
    snippet = snippet.substr(0, 30) + "..." if snippet.length > 30
    snippet = snippet.replace(/\n/g, "\\n")
    out += action
    out += ' ' for [action.length..30]
    out += if indent then " >#{snippet}<\n" else "\n"
    console.log out

  throwError = (msg) ->
    line = @buffer.substr(0, @position).match(/\n/g).length + 1
    column = @position - @buffer.lastIndexOf("\n", @position)
    context = @buffer.substr(@position, 50).replace(/\n/g, "\\n")
    position = @position;
    error = """
Error parsing Pegex document:
  msg: #{msg}
  line: #{line}
  column: #{column}
  context: "#{context}"
  position: #{position}
    """
    throw error if @throwOnError
    console.log error
    return false

###

This is the Pegex module that provides the parsing engine runtime. It has a
parse() method that applies a grammar to a text that supposedly matches
that grammar. It also calls the callback methods of its Receiver object.

Generally this module is not used directly, but is called upon via a
Grammar object.

###
