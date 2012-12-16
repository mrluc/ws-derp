ws-derp - Derp Up Your Socket.IO
===

Socket.IO is awesome - it makes Websockets practical
and clean, and Just Works so you don't have to work 
around browser bugs. It's as for WebSockets, now, 
as jQuery would have been in 2002.

With Socket.IO `on`/`emit`, you're probably used to frames like this:

    5:::{"name":"myFn","args":[[{"id":1,"x":2,"y":3}]]}

That's quite polite, but a lot of characters. Enter `ws-derp.`

`ws-derp` will help you derp up your `message`/`send` channel, which
you probably aren't using if you do `on`/`emit`. You can hand
it an api (for instance, for sending arrays of numbers), and your
sockets on both server and client will understand how to
create frames that look more like this:

    3:::1`6~-Y`Z~

Smaller!

(See [below](#buffalo) for notes on why you might do something like this --
TL;DR: websockets are a wild west, which is why we have Socket.IO;
gzipped frames are still evolving; binary encoding libs don't 
yet offer fallbacks like Socket.IO does; custom encoding like 
this is more work but can be a foolproof way of getting 
guaranteed-small frame sizes).

* [Installation](#installation)
* [Usage](#usage)
* [Pieces](#pieces)

### Installation

    npm install ws-derp

### Usage

    {TinySocketApi, Coders} = require 'ws-derp'
    {int_args, int_list} = Coders
    
    ts = new TinySocketApi
      serverListens:
        clientNumberAnnouncement: int_args 2, (val...)->
          console.log " TWO-BYTE NUMBER! OMG OMG #{ val }"
      clientListens:
        serverNumberList: int_list 2, (s...)->
          console.log " LIST OF NUMS! OMG OMG #{ s }"
    
    ...
    # get a socket.io socket somewhere
    ...
    
    # take the server role on this socket
    # on the client it would be: `ts.setClient( socket )`
    ts.setServer( socket )
    
    # now our listeners are hooked up, and the socket has
    # been extended with the send method:
    socket.serverNumberList [1234,2345,3456]

You would want to share the definition of the api - the hash passed
to `TinySocketApi` - between client and server (I assume you're
using something like Browserify).

You could customize the callbacks, but it'd be important that
the keys of the `clientListens` and `serverListens` hashes, and
the Coders that determine the type of the args, be the same.

### What Goes Over The Wire?

In the example above, probably `3::~6++)>7`

* the long function names are turned into the base-93
  encoding of their alphabetic order, so `serverNumberList`
  becomes `~`
* the array gets e93-encoded and turns into `6++)>7`
* Socket.IO adds `3:::` which means it's a raw message,
  as distinct from a connect, disconnect, emit, or other 
  Socket.IO frame type.

### Encoders/Decoders

`int_args` and `int_list` are defined in class `Coders` via:

    int_list = (bytes, fn) ->
      Coders.define_coder [[pc.a2s, pc.s2a, bytes]], fn
      
Where pc.a2s and s2a are function-creating-functions that
take a number of bytes/chars/places and return a function for consuming
that many from a sequence (string, array) and return 
a `[parsedValue, restOfSequence]` pair.

### PackedCalls

The functions are called via `PackedCalls.unpacker`.

    PackedCalls.unpacker [someArgsConsumer, otherArgsConsumer], fn
    
Which creates a function that will convert its arguments using the 
argument consumers before passing them to the callback.

`PackedCalls` contains a few consumers defined at the class
level, and they're used above: `s2a, a2s, s2i, i2s`, which are
for converting arrays and integers to strings and back.

### Basic Conversion Functions

We have an `Alphabet` class built on the `bases` module, adding
the ability to convert in both directions. The `Conversions` 
class has `to_i` and `to_s` methods based on a 93-character alphabet.

    {Conversions} = require 'ws-derp'
    {alphabet, to_i, to_s} = Conversions


<span id="buffalo">
#### Every Part of the Websocket Buffalo

The Websockets standard is UTF-8, and people often use it to 
send JSON. Socket.io uses JSON by default when you use `.on()` 
or `.emit()`, so that

    socket.emit 'myFn', [{id:1,x:2,y:3}]

    # creates websocket frames like:

    5:::{"name":"myFn","args":[[{"id":1,"x":2,"y":3}]]}

That's not optimal, but it's not trying to be optimal in that
sense, and doesn't need to be - the benefit of  
open-socket-versus-polling is so great that optimizing the actual frames would be 
a waste of time for almost anyone, especially since 
frames are going to be gzipped in the future.

And in fact for more general single-page-app projects, you're
probably already using something like backbone.js that sends hashes
back and forth, and you can drop websockets in as a transport and get a nice 
speed boost.

But for some kinds of real-time, like multiplayer games, it makes
sense to have one channel that's really optimized for the core
updates, like entity positions each tick.

You could just use `.send()` from the websockets standard, which
socket.io also provides, and send a delimited separated sequence
of updates -- for instance, two x/y pairs might be:

    3:::myFn[1234,89352,123,392]

That's a lot smaller. You need to provide your own dispatch table - 
your own implementation of the `"name":"myFn"` part of the 
socket.io approach. A little logic, no big.

But there are still two sources of inefficiency:

1. The function name. `myFn` is 4 bytes long. Seems short, but
   how many functions are there in your API brah?? `Math.pow(58, 4)` 
   functions??
   
2. The contents are base-10 numbers written in a base-255
   medium: utf-8.
   
   In practice we can only use from base-58
   to base-93, and utf-8 is actually only base-128 for our 
   purposes, but any of that would be 
   quite an improvement on base-10!
   
   gzip would whittle down the improvement with larger message
   bodies, but the nature of websocket frames is that they'll
   likely be smallish and frequent.
   
So that's what I played around with first! There are some classes
sketched out around this that I'll probably extract out into 
a little library before continuing on with my merry
muckery.

`TinySocketApi` (built on `CompressedKeys`) takes care 
of the first point, and then a host of conversion, 
rpc and other little helpers (`CompilingApiCall`,
`Coder`,`PackedCalls`,`Conversions`,`Alphabet` - I know, I know) take 
care of the second. `TinySocketApi` also handles binding 
of sockets for the server and the client.

None of this is necessary - gzipped frames are probably fine -
but it's been fun - and now we can send some ints via

    socket.gameState [parseInt(pos.x), parseInt(pos.y), 92*92, 92*93]

And the message produced will be

    3:::1`6~-Y`Z~

Instead of, for instance:

    3:::'gameState',106,24,8464,8556

It's comforting to know the exact size of the messages 
we send. We can start reasoning on what's possible, and make informed
tradeoffs re: number of messages and their weight and number of clients.
