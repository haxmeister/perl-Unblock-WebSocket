# Autobahn author test

This directory is repository-only validation for Unblock::WebSocket. It is not
part of the CPAN distribution and is not a runtime dependency.

The adapter intentionally uses blocking IO::Socket::INET sockets. That is only
test transport glue. Unblock::WebSocket still owns no socket, event loop, TLS,
or HTTP transport.

For server conformance, echo-server.pl accepts a TCP connection, performs the
HTTP/1.1 WebSocket bootstrap through Unblock::WebSocket::Handshake, and feeds
the resulting stream to Unblock::WebSocket::Server.

For client conformance, client-driver.pl connects to the Autobahn fuzzing
server, performs the same public handshake path, and drives
Unblock::WebSocket::Client through each case.

The external crossbario/autobahn-testsuite Docker image is a black-box peer.
No Autobahn or Python code is linked into or shipped with Unblock::WebSocket.

Sections 12 and 13 remain excluded until RFC 7692 permessage-deflate is
implemented. All other RFC 6455 cases are expected to run for both client and
server validation.

check-report.pl allows OK, NON-STRICT, and INFORMATIONAL while development is in
progress. Actual release review should record the exact NON-STRICT cases and
drive them down rather than treating the aggregate pass as sufficient.
