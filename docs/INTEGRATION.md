# Transport integration

Unblock::WebSocket is an established WebSocket protocol engine. The caller
performs HTTP handshake validation before creating Client or Server. The
WebSocket object does not own sockets, TLS, timers, event loops, or HTTP.

There are two output modes. Choose one per WebSocket object.

## Attached output (recommended for ordinary host integrations)

    my $ws = Unblock::WebSocket::Server->new(
        transport => $stream,
        on_message => sub {
            my ($ws, $message, $type) = @_;
            $ws->send_text("echo:$message");
        },
    );

The host stream implements three methods:

    unblock_send($bytes)
    unblock_finish()
    unblock_abort($reason)

The host still feeds input:

    $ws->input($bytes);
    $ws->input_eof;               # clean read-side EOF
    $ws->transport_error($reason); # broken socket or TLS transport

It never calls output() in attached mode. Output from send_text(),
send_binary(), ping(), Close frames, automatic Pong, errors and later
application callbacks is handed to unblock_send() automatically.

### Whole-buffer ownership

unblock_send() must accept every byte of the given buffer into its own
ordered write queue or throw an exception. Socket writes can be partial
internally, but the host retains any unwritten bytes.

A true return means accepted and able to take more. An undefined return means
accepted, with no backpressure information. A defined false return means
accepted completely, but the host is now congested.

The engine will not call unblock_send() again until:

    $ws->resume_output;

The host calls that when its own queue can accept more. Bytes already accepted
are never replayed. Exceptions cause immediate transport abort.

The attached transport is held weakly. The framework must keep it alive as
long as the established connection needs to operate.

Do not call input(), output(), or resume_output() recursively from
unblock_send(). Do not send new WebSocket messages from unblock_send().
Application callbacks may send normally. The engine avoids recursively
entering the host's write method while delivering those callbacks.

### Producer backpressure

send_text(), send_binary(), and ping() accept the message even when their
return value is false. False means the producer should stop sending new
messages until on_drain runs.

There are two different reasons:

- the WebSocket output queue reached high_water, or
- the host returned false from unblock_send().

on_drain is a producer notification, not a socket-writable event. It runs
after host congestion clears (resume_output()) and the protocol queue is at
or below low_water. The host must manage its socket's write readiness itself.

### Close handling

close() queues a WebSocket Close frame and begins the protocol handshake.
It does NOT immediately close the host. The peer's Close reply must arrive
before a normal finish (or the host may impose its own timeout and call
abort()).

After the peer Close is received, unblock_finish() is called once the
WebSocket engine has handed all pending output to the host. The host must
drain its own queue before shutting down the transport. If the host is
congested, resume_output() is still required.

transport_error() is an immediate failure and calls unblock_abort() once.
Unexpected EOF before a peer Close is also abnormal in attached mode and
aborts. Both paths report on_error and, if no Close was received, on_close
with an undefined code and an explanatory reason.

## Manual output (unchanged)

Without transport => ..., the existing low-level API remains available:

    $ws->input($bytes);
    while ($ws->want_write) {
        $host->write($ws->output);
    }

    $ws->input_eof;

output($maximum), output_size(), want_read(), want_write(), and want_end()
retain their manual-mode meanings. The native backend and borrowed-buffer
native ABI remain separate and unchanged.

Calling output() when attached is an error; manual code must not compete
with unblock_send() for ownership of the same bytes.

## HTTP/1.1 Upgrade

Use Unblock::WebSocket::Handshake to validate the Uniform::HTTP request and
construct the 101 response.

With a current Unblock::HTTP1 Server, the on_switch callback occurs after
the attached HTTP host has accepted the 101 response bytes. The HTTP1 engine
stops parsing HTTP, and take_remainder() returns the exact bytes already
received beyond the handshake. Feed that remainder into the new WebSocket
engine; never feed it back to HTTP.

Use the SAME ordered host write queue after switching. The 101 response must
remain ahead of all WebSocket frames. The original HTTP connection becomes
the WebSocket connection.

The optional real engine regression is t/35-http1-handoff.t. It sends a
WebSocket frame immediately after the HTTP request in the same input buffer.

## HTTP/2 Extended CONNECT

An HTTP/2 WebSocket is one streaming HTTP/2 Transaction, not the entire
HTTP/2 connection. The peer must advertise enable_connect_protocol.

The WebSocket Handshake makes a CONNECT request with protocol => 'websocket'.
The successful response has status 200. Use stream_body => 1 on the
request and response. Each HTTP/2 DATA body chunk becomes a call to
WebSocket input(). Send outgoing WebSocket bytes through Transaction->write()
and finish that particular body with Transaction->end() after WebSocket Close.

An HTTP2 transaction-body adapter can implement the three unblock_*
operations. If it is called from an HTTP/2 parser callback, queue WebSocket
output for transfer after that callback returns. Do not recursively drive
nghttp2 from its own callback. The rest of the HTTP/2 connection remains
usable for other transactions.

The optional real engine regression is t/36-http2-handoff.t.

## HTTP/3 Extended CONNECT

An HTTP/3 WebSocket likewise occupies only one QUIC bidirectional stream.
Use a client and server with enable_extended_connect as appropriate and
check the peer's corresponding setting. Successful Extended CONNECT uses a
200 response, with a streaming request and response body.

The QUIC driver retains ownership of UDP, TLS 1.3, stream flow control, and
timers. Transfer each body chunk to WebSocket input(). Transfer WebSocket
output to the relevant HTTP3 Transaction->write(), not to the whole QUIC
connection. A Close handshake ends that transaction's body, not other QUIC
streams.

An H3 body adapter must translate stream congestion into a false
unblock_send() result only AFTER complete buffer acceptance and arrange
resume_output() from its write-resumption signal. If a transaction cannot
accept the whole buffer at once, the adapter must queue it itself before
reporting acceptance.

The Handshake class validates the H3 opening form, but a live H3/QUIC
end-to-end test requires a real Net::QUIC connection, driver and TLS
certificate fixtures; it is not implied by the handshake unit tests.

No Unblock::HTTP1, ::HTTP2, ::HTTP3 or Net::QUIC distribution is a mandatory
WebSocket runtime dependency. Integration regressions run when their optional
engines are installed.

## Further reading

See the public POD for Client, Server, Handshake and the main
Unblock::WebSocket module. The repository also contains test/bench tools and
docs/ARCHITECTURE.md.
