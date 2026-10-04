package Unblock::WebSocket;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Unblock::WebSocket - event-loop and platform neutral WebSocket protocol engine

=head1 DESCRIPTION

Unblock::WebSocket provides WebSocket protocol engines without owning sockets,
TLS, DNS, timers, or an event loop.

Use L<Unblock::WebSocket::Client> or L<Unblock::WebSocket::Server> for an
established WebSocket byte stream. Use L<Unblock::WebSocket::Handshake> to
construct and validate HTTP/1.1, HTTP/2, or HTTP/3 WebSocket handshakes using
Uniform::HTTP objects.

=head1 LICENSE

MIT License.

=cut
