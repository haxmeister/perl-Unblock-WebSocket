# Unblock::WebSocket handoff

Last updated: 2026-10-04

## Repository

Repository: haxmeister/perl-Unblock-WebSocket

Development branch: feature/native-core

Main currently contains the initial portable protocol core. Native backend work
is being developed and tested on feature/native-core before it is merged.

Do not modify Linux::Event::WebSocket or other repositories from this project
unless explicitly authorized. They may be read as reference material.

## Goal

Unblock::WebSocket is a platform-, framework-, and event-loop-neutral WebSocket
protocol engine.

It owns WebSocket protocol behavior. It does not own sockets, DNS, TLS, HTTP
transport, listeners, timers, or an event loop.

The long-term Linux::Event integration should become a thin transport adapter
around this distribution rather than a second WebSocket implementation.

## Public protocol API

Established connections use a bytes-in / bytes-out API:

    $ws->input($bytes);

    while ($ws->want_write) {
        $transport->write($ws->output);
    }

Application operations include:

    $ws->send_text($text);
    $ws->send_binary($bytes);
    $ws->ping($payload);
    $ws->close(code => 1000, reason => 'done');

Transport EOF is explicit:

    $ws->input_eof;

Client and server roles share the same API. The role controls RFC masking
direction.

## Handshake boundary

Unblock::WebSocket::Handshake uses Uniform::HTTP 0.04 request and response
objects.

Supported bootstrap forms:

- HTTP/1.1 RFC 6455 Upgrade
- HTTP/2 Extended CONNECT
- HTTP/3 Extended CONNECT

Unblock::WebSocket does not depend on Unblock::HTTP1, Unblock::HTTP2, or
Unblock::HTTP3 at runtime. The caller sends the Uniform HTTP objects through its
chosen HTTP implementation.

WebSocket frames remain private wire-protocol machinery. They do not belong in
Uniform.

## Reference backend

The Perl frame/parser engine remains available as:

    backend => 'perl'

It is intentionally retained as an independent executable reference for
differential testing and debugging.

A deterministic random_bytes hook selects the Perl backend unless native is
explicitly requested. The native backend does not silently ignore an injected
random source.

## Native backend

The production native backend vendors bq_websocket from upstream commit:

    6c188d3f0edca38d7a8926e0d30f4c145414ba4c

The vendor README records all local protocol patches.

The native backend is selected by default when XS is available.

Secure mask randomness is provided by a private portability layer:

- Linux: getrandom(2)
- Windows: BCryptGenRandom
- macOS/BSD: arc4random_buf
- conservative fallback: /dev/urandom

The public API contains no operating-system-specific RNG behavior.

## Native adapter ABI

include/unblock_websocket_native.h defines private ABI version 1.

The ABI is designed for high-performance native transports and includes:

- opaque protocol-engine state
- borrowed input pointer and length
- explicit consumed-byte count
- completed-message event callback
- native send and close operations
- native output drain
- error and memory-use inspection
- ABI version and structure size fields

No Linux::Event type, fd, socket, epoll object, TLS object, or event-loop object
appears in the ABI.

This is the path intended to recover Linux::Event::WebSocket performance after
protocol ownership moves to Unblock.

## Performance requirement

Do not replace the existing Linux::Event::WebSocket engine merely because
feature parity is reached.

Before that replacement, benchmark:

1. current Linux::Event::WebSocket native baseline
2. standalone Unblock Perl/reference backend
3. Linux::Event using the public Unblock byte API
4. Linux::Event using the private native ABI

The native adapter should recover the existing bq-based performance within
measurement noise, or any remaining regression must be explicitly understood
and accepted.

## Protocol fixes already carried into the native backend

The vendored bq engine includes the fixes previously validated in
Linux::Event::WebSocket, plus extraction-specific fixes:

- RFC close-code range handling
- incoming Close UTF-8 validation
- one-byte Close rejection
- control payloads above 125 bytes rejected before side effects
- one Pong response per Ping
- safe Close echo ownership
- Linux-only getrandom dependency removed from bq itself
- application data-message limits remain independent of the 125-byte control
  frame limit
- valid messages queued before a later malformed frame in the same input batch
  remain observable before the protocol error

Protocol errors map to WebSocket Close behavior including 1002, 1007, and 1009.

## Current tests

The native build has reached 76 passing tests on:

- Linux, latest Perl
- Linux, Perl 5.16
- macOS, latest Perl
- Windows Strawberry Perl 5.40

Windows CI is fully green at the current checkpoint.

Linux and macOS protocol/build tests are green. Their current CI failure is only
the POD workflow treating private modules with no POD as errors. The workflow
fix is being committed next so podchecker runs only on modules that actually
contain POD.

Current coverage includes:

- framing and masking
- partial input
- 16-bit payload length
- client/server text and binary round-trip
- Unicode text
- Ping/Pong
- fragmented messages with interleaved control frames
- Close exchange
- application message limits
- Close 1009 for oversized data
- native/public backend parity
- valid-message-before-malformed-frame ordering
- HTTP/1.1, HTTP/2, and HTTP/3 handshake models

## Important repository-history note

During native-core development one intermediate branch commit accidentally used
an incomplete Git tree as its base and appeared to delete untouched files. The
next branch commit rebuilt the tree from the full known-good native commit.
main was never affected. Current comparison against main has no unintended
removed files.

## Next work

Immediate:

1. make the entire cross-platform CI matrix green
2. port standalone RFC 6455 parser vectors and UTF-8 edge cases
3. port close lifecycle cases as in-memory transport tests
4. expand malformed-frame and error-code parity tests
5. add broader handshake rejection/subprotocol tests

Then:

6. prepare Autobahn client/server harnesses for Unblock
7. run the full non-compression Autobahn suite
8. investigate and eliminate remaining NON-STRICT cases
9. design and implement RFC 7692 permessage-deflate
10. enable Autobahn compression sections
11. add performance benchmarks for reference/native public paths
12. later build the Linux::Event native adapter and compare against the old
    Linux::Event::WebSocket baseline

## Release status

Not release-ready yet.

Version remains 0.01.

The first release should not be considered complete until native portability,
conformance, documentation, distribution contents, and the intended extension
story have all been audited.
