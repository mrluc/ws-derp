
# okay what now?
#  well ... I mean if we really want to be fast, we should at least
#  dispatch the first 2 chars for a fn table,
#  and pass the calls along as they are now ...

_ = require 'underscore'
ext = require('./extensions')
lg = puts = (s...) -> console.log s...

Module = ext.Module

class Alphabet extends Module
  @include require 'bases'
  constructor: (@byPosition)->
    @base = @byPosition.length
    @byLetter = {}
    for s, i in @byPosition.split ""
      @byLetter[s] = i
    @padChar = @to_s 0
    @replacePad = /// ^#{@padChar}+ ///
  pad: (s, len, padChar=@padChar)=>
    s = padChar + s while s.length < len
    s
  to_s: (i,padNumChars=no)=>
    s = @toAlphabet i, @byPosition
    if padNumChars then @pad(s,padNumChars) else s

  to_i: (str,padTo=no)=>
    digits = str.split ""
    str = str.replace @replacePad,"" if padTo
    [len, num] = [digits.length, 0]
    for s, i in digits
      int = @byLetter[s]
      multi = Math.pow @base, (len - i - 1)
      int = int * multi if multi > 0
      num += int
    num

class Conversions extends Module
  @include require 'bases'
  @e64 = new Alphabet [
    "1234567890"                 # 10
    "abcdefghijklmnopqrstuvwxyz" # 26
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" # 26  = 62
    "-_"
  ].join('')
  @e93 = @alphabet = new Alphabet [
    "~`!1@2#3$4%5^6&7*8(9)0"
    " _-+={[}]|:;'<,>.?/"
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  ].join('')
  {@to_s, @to_i} = @alphabet

# Compressed <-> Verbose hash keys
#   give it a hash with descriptively named keys and it'll
#   make @named and @tiny hashes referencing
#   the same values.
class CompressedKeys extends Module
  # TODO: the keys for these need to be unique across all
  #  instances.
  cnv = Conversions
  ck_i = -1
  @include _
  constructor: (@named, opts={})->
    {counterStartAt} = opts
    ck_i = counterStartAt if counterStartAt
    @tiny = {}
    sorted = @sortBy ([k,v] for k,v of @named), ([key,cb])-> key
    @tiny[cnv.to_s(ck_i += 1)] = cb for [key,cb] in sorted

  findParallelKey: (key, first, second)->
    if val = first[key]
      return key2 for key2, val2 of second when val is val2
      no
    else no

  nameForTiny: (tiny)=> @findParallelKey tiny, @tiny, @named
  tinyForName: (name)=> @findParallelKey name, @named, @tiny


class PackedCalls extends Module
  cnv = Conversions
  @unpacker = (argConsumers..., fnToCallWithArgs = puts)->
    (s)->
      args=[]
      for argFn in argConsumers
        [val, rest] = argFn s
        s = rest
        args.push val
      if !rest or rest.length is 0 or rest is ""
        fnToCallWithArgs args...
      else
        fnToCallWithArgs( args..., rest )

  # some consumers: to/from int, intarray
  @s2a = (bytes)->
    (s)->
      val = []
      for i in [0..(s.length-1)] by bytes
        val.push cnv.to_i( s[i...(i+bytes)], bytes )
      [ val, []]
  @a2s = (bytes)->
    (rest)->
      total=""
      total+= cnv.to_s( i, bytes ) for i in rest
      [ total, []]

  @s2i = (bytes)->
    (s)->
       [ cnv.to_i( s[0...bytes] ), s[bytes..] ]
  @i2s = (bytes)->
    (rest)->
      val = cnv.to_s rest.shift(), bytes
      [ val, rest ]

class TinySocketApi extends Module
  cnv = Conversions
  pad = cnv.alphabet.pad
  @include _
  dispatch_message: (s)=> @dispatch[ s?[0] ] s[1..]
  sock_has_message_listener: (sock)->
    @contains sock.$events?.message, sock.dispatch_message

  constructor: ({@serverListens, @clientListens})->
    @dispatch = {}
    @useMessages()    # faster, trickier
    #@useEvents()    # dead-easy json which I might have broken.

    @serverApi = new CompressedKeys @serverListens, startCounterAt: -1
    @clientApi = new CompressedKeys @clientListens
    @debug()

  debug: =>
    puts ["------", k, @clientApi.nameForTiny(k)] for k, v of @clientApi.tiny
    puts ["------", k, @serverApi.nameForTiny(k)] for k, v of @serverApi.tiny

  make_emitter: (sock, evt)->
    (args...)->
      sock.emit( evt, args )
  make_sender: (sock, evt)->
    (args...)->
      sock.send ( "#{pad(evt,1)}#{args[0]}" )
  make_event_listener: (sock, evt,cb)-> sock.on evt, cb
  make_message_listener: ( sock, evt, cb )=>
    sock.dispatch_table[ pad(evt,1) ] = cb

  useEvents: =>
    @sender = @make_emitter
    @receiver = @make_event_listener
  useMessages: =>
    @sender = @make_sender
    @receiver = @make_message_listener

  setEmitters: (sock, api)->
    for fname, cb of api.named
      evt = api.findParallelKey fname, api.named, api.tiny

      fn = @sender sock, evt
      fn = cb.make_encoder( fn ) if cb.has_encoder
      sock[ fname ] = fn

  setListeners: (sock, api)->
    @receiver( sock, evt, cb ) for evt, cb of api.tiny

  dispatchify: (sock)->
    tbl = sock.dispatch_table = {}
    sock.dispatch_message = (s)->
      k=s?[0]
      if tbl[ k ]
        tbl[ k ] s[1..]
      else
        console.log "COULDN'T DISPATCH: #{ k }"
    sock.on 'message', sock.dispatch_message
  setServer: (sock)=>
    @dispatchify sock
    @setEmitters sock, @clientApi
    @setListeners sock, @serverApi

  setClient: (sock)=>
    @dispatchify sock
    @setEmitters sock, @serverApi
    @setListeners sock, @clientApi

pc  = PackedCalls
cnv = Conversions

class Coders extends Module
  # todo: okay, about time for instances
  @define_coder = (triplets, fn)->
    encargs = []
    decargs = []

    for [encode, decode, bytes] in triplets
      encargs.push encode bytes
      decargs.push decode bytes

    decoder = pc.unpacker decargs..., fn

    # TODO then the emitter would use in setEmitters
    decoder.has_encoder = yes
    decoder.args_encoders = encargs
    decoder.make_encoder = (outfn=fn)->
      pc.unpacker encargs..., outfn
    decoder

  @int_list = (bytes, fn)=>
    @define_coder [[pc.a2s, pc.s2a, bytes]], fn
  @int_args = (arg_bytes..., fn)=>
    triplets = []
    for bytes in arg_bytes
      triplets.push [ pc.i2s, pc.s2i, bytes ]
    @define_coder triplets, fn

{int_list, int_args} = Coders

# todo - private; no need to use externally right?

exports.PackedCalls = PackedCalls
exports.Conversions = Conversions
exports.Alphabet = Alphabet

# public
exports.Coders = Coders
exports.TinySocketApi = TinySocketApi


# tests
#
exports.tests = multiArgs: ->
  cnv = Conversions
  pc = PackedCalls

  # NOW: multi-args
  bytes = b = 1
  fn = (a,b)->
    lg "THEY GAVED MEZ: #{a} and #{b}"
    lg "a + b == 4? #{(a+b) is 4}"
  a = cnv.to_s 1, b
  b = cnv.to_s 3, b
  arg = a+b
  unpackCall = pc.unpacker pc.s2i(b), pc.s2i(b), fn

  lg unpackCall arg

, basicArgs: ->
  cnv = Conversions
  pc = PackedCalls
  unpack = pc.unpacker pc.s2i(5), (args...)->
    lg "NO WAY. AWESOME ARGS ---> "
    lg JSON.stringify args[0]
    args[0]
  repack = pc.unpacker pc.i2s(5), (args...)->
    lg "REPACKED BRAH!!!"
    lg JSON.stringify args[0]
    args[0]
  lg unpack cnv.to_s 12345
  lg fried = repack [12345]
  lg "fried: #{fried}"
  lg refried = unpack fried

, conversions: ->
  cnv = Conversions
  fails = []
  for i in [10, 91, 200, 2000, 4123, 6540, 12000]
    s = cnv.to_s( i )
    puts "CONVERTING: #{ i } -> '#{ s }' -> ?"
    puts "conversion works: -- #{ yay = (tot=cnv.to_i( s )) is i }"
    puts "          = #{ tot }"
    fails.push i unless yay
  puts if fails.length > 0
    "FAILS: #{fails}"
  else "SUCCESSES!"

  puts "PADDING OUT A STRING:"

  puts "Padding out to 5 chars: #{cnv.alphabet.pad 'XXX', 5}"

exports.test = ->
  for name, testFn of exports.tests
    lg "RUNNING TEST: #{ name }"
    testFn()

# THOUGHTS ON TINY APIS:
# To build actual endpoint functions, need
#
# 1. Functions that return parsed vals (ints, strs)
# 2. The fn that knits them together into a call:
#    something like:
#
#  unpackCall player.do_something,
#    s2bImpulseVec(2,2)
#
#  unpackCall would give us the function that consumes
#  those portions of the string - so the return of the
#  _conversion_ fns needs to be multiple: [ val, rest ].


#-----------------
# so we want to use smaller WS messages, which are always utf-8 strings.
#
# using json in utf-8 strings is so wasteful it makes me want to cry ... but
# gzip helps with that.
#
# what it doesn't help with is the structure of the data:
#
#   FNAME ARG1:_, ARG2: _
#
# we don't need a full FNAME, and we know what order the args are in!
# So ideally we'd like a little lib that takes a hash of fnames and expected args
# and callbacks, and generates internally a much more compact mapping.
# We could also

#
#
# serverListens: [
#   consumeUserActions: cb
# ,
#   name2: cb
# ,
#   name3: cb
# ]
# clientListens: [
#   name: cb
# ]
#
# and you generate some api that listens for: '0':"somestring"
#
# and then I can unpack that in my object just fine, thank you.
# The API, the collection, and the user would all have something
# like `handlePackedMessage`
#
#
#  consumeUserActions: world.Users.handlePackedMessage
#
#
# ie, .handlePackedMessage = (msg)-> consumeMsg via passing it on.
# but for now, let's just do that basic thing: set up the integer
# map, above.