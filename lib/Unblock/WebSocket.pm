package Unblock::WebSocket;

use strict;
use warnings;

our $VERSION = '0.01';
our $NATIVE_AVAILABLE = eval {
    require XSLoader;
    XSLoader::load(__PACKAGE__, $VERSION);
    1;
} ? 1 : 0;

sub native_available { $NATIVE_AVAILABLE }

1;

__END__

=head1 NAME

Unblock::WebSocket - event-loop and platform neutral WebSocket protocol engine

=head1 DESCRIPTION

Unblock::WebSocket provides WebSocket protocol handling without owning sockets,
TLS, DNS, timers, or an event loop.

Use L<Unblock::WebSocket::Handshake> for the opening HTTP handshake.

Use L<Unblock::WebSocket::Client> or L<Unblock::WebSocket::Server> after the
WebSocket stream has been established.

The distribution supports:

=over

=item * RFC 6455 framing, masking, fragmentation, Ping/Pong, Close, and UTF-8

=item * HTTP/1.1 Upgrade handshakes

=item * HTTP/2 and HTTP/3 Extended CONNECT handshakes

=item * RFC 7692 permessage-deflate

=item * a portable Perl protocol backend

=item * a private native backend for faster framing and masking

=back

The public protocol API remains bytes in and bytes out. Applications do not
need to work with WebSocket frame objects.

=head1 NATIVE BACKEND

C<native_available()> reports whether the optional XS backend loaded.

When available, normal established connections use the native backend unless a
portable-only option requires otherwise. This is an implementation detail; the
public Client and Server APIs are the same.

=head1 LICENSE

MIT License.

=cut
