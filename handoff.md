# Unblock::WebSocket handoff

Last updated: 2026-10-04

## Repository

Repository: haxmeister/perl-Unblock-WebSocket

Development branch: feature/permessage-deflate

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

Unblock::WebSocket::Handshake uses Uniform::HTTP 0.05 request and response
objects.

For exact canonical Uniform objects, handshake validation uses
Uniform::HTTP::FastPath ABI 1 as a read-only bulk view. This removes repeated
header/method accessor dispatch during the opening handshake. Subclasses and
adapters are deliberately kept on the portable Uniform method contract.

WebSocket does not use FastPath trusted construction for requests or responses.
Handshake construction happens once per connection, so bypassing normal Uniform
validation there is not worth the additional trust boundary. FastPath also does
not enter the native WebSocket frame ABI; established-frame processing remains
independent of HTTP and Uniform.

Supported bootstrap forms:

- HTTP/1.1 RFC 6455 Upgrade
- HTTP/2 Extended CONNECT
- HTTP/3 Extended CONNECT

Unblock::WebSocket does not depend on Unblock::HTTP1, Unblock::HTTP2, or
Unblock::HTTP3 at runtime. The caller sends the Uniform HTTP objects through its
chosen HTTP implementation.

WebSocket frames remain private wire-protocol machinery. They do not belong in
Uniform.

## Uniform::HTTP 0.05 FastPath review

Uniform::HTTP 0.05 FastPath is useful to Unblock::WebSocket, but only at the
HTTP handshake boundary.

Decision:

- require Uniform::HTTP 0.05;
- use FastPath::view() for read-only inspection of exact canonical Request and
  Response objects;
- retain the existing portable accessor path for subclasses and adapters;
- keep normal Uniform constructors for WebSocket-generated requests/responses;
- do not use request_from_validated() or response_from_validated() here;
- do not couple the native WebSocket frame ABI to Uniform::HTTP.

This is intentionally narrower than HTTP1/HTTP2/HTTP3 FastPath use. Those
engines process Uniform messages continuously and benefit substantially from
bulk/trusted construction. WebSocket performs HTTP work only once when a
connection opens, so FastPath can remove avoidable method dispatch without
adding a second trusted construction boundary or changing established-message
performance.


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

The complete CI matrix is green on:

- Linux, Perl 5.16
- Linux, latest Perl
- macOS, latest Perl
- Windows Strawberry Perl 5.40

The current normal suite contains 18 test files and 487 tests.

The POD workflow now checks only modules that contain POD, so private internal
modules without POD no longer create false CI failures.

Current coverage includes:

- Rejected Close-frame memory lifetime remains at native baseline
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

## Regression findings

Pre-error response ordering is now treated explicitly: if the native parser
has already detected a later malformed frame but returns an earlier complete
valid event, only responses generated while delivering that retained pre-error
event may use the portable framer. They are queued before the native
protocol-error Close. Normal native traffic remains fully native, and arbitrary
post-error sends remain disallowed.

The native receive path now has an incremental native RFC 3629 validator.
Validation state is carried across continuation frames and updated for each
newly arrived unmasked payload octet, so invalid text can fail immediately even
when the offending sequence is split across frames or socket reads. Public
message delivery remains whole-message only; this does not expose fragments.

The expanded standalone regressions found and fixed two real reference-backend
issues:

- Perl Encode rejects Unicode noncharacters that RFC 3629 permits. The portable
  UTF-8 layer now validates RFC 3629 itself, permits noncharacters, and rejects
  surrogates and values above U+10FFFF.
- Invalid UTF-8 in a received Close reason was being flattened to protocol
  Close 1002 in the Perl backend. It now maps to Close 1007, matching the native
  backend and the intended protocol semantics.

## Important repository-history note

During native-core development one intermediate branch commit accidentally used
an incomplete Git tree as its base and appeared to delete untouched files. The
next branch commit rebuilt the tree from the full known-good native commit.
main was never affected. Current comparison against main has no unintended
removed files.

## Next work

Immediate:

1. audit the now-strict non-compression RFC 6455 path and freeze its regression
   baseline
2. design RFC 7692 permessage-deflate negotiation and compression state
3. implement permessage-deflate without exposing frames as public objects
4. enable Autobahn compression sections 12 and 13
5. add portable/native performance benchmarks

Then:

6. prepare Autobahn client/server harnesses for Unblock
7. run the full non-compression Autobahn suite
8. investigate and eliminate remaining NON-STRICT cases
9. design and implement RFC 7692 permessage-deflate
10. enable Autobahn compression sections
11. add performance benchmarks for reference/native public paths
12. later build the Linux::Event native adapter and compare against the old
    Linux::Event::WebSocket baseline

## Autobahn results

Server and client Autobahn results on 2026-10-04 are identical:

- 301 selected RFC 6455 cases per direction
- final non-compression result: 298 OK
- final non-compression result: 0 NON-STRICT
- 3 INFORMATIONAL
- close behavior: 298 OK / 3 INFORMATIONAL
- zero failures

This exactly matches the known Linux::Event::WebSocket baseline for the same
non-compression case selection.

The original 11 NON-STRICT cases were 3.2, 3.3, 4.1.3, 4.1.4, 4.2.3, 4.2.4,
5.15, 6.4.1, 6.4.2, 6.4.3, and 6.4.4. The pre-error response-ordering fix
converted the first seven to strict OK. Incremental native RFC 3629 validation
then converted 6.4.1 through 6.4.4 to strict OK. There are now zero NON-STRICT
results in the selected non-compression suite in either direction.

The first client Autobahn launch exposed a corrupted validation regexp in
Unblock::WebSocket::_Random. The anchors had been stored as literal A/z instead
of \A/\z during an earlier repository blob construction. This was fixed and a
real generated Sec-WebSocket-Key regression was added; the subsequent complete
client run passed all selected cases under the same acceptance criteria.

## Autobahn author harness

xt/autobahn is repository-only and excluded from the CPAN distribution.

It uses IO::Socket::INET only as author-test transport glue. The test adapter
performs HTTP/1.1 bootstrap through Unblock::WebSocket::Handshake and then
drives the public Client/Server byte API. It does not introduce a runtime
transport or event-loop dependency.

The GitHub Autobahn workflow runs the external crossbario/autobahn-testsuite
Docker image for both server and client conformance. Sections 12 and 13 remain
excluded until RFC 7692 permessage-deflate exists.

## Release status

Not release-ready yet.

Version remains 0.01.

The first release should not be considered complete until native portability,
conformance, documentation, distribution contents, and the intended extension
story have all been audited.
