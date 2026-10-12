package Unblock::WebSocket::Client;

use strict;
use warnings;
use parent 'Unblock::WebSocket::_Engine';

sub new {
    my ($class, %option) = @_;
    return $class->_new(role => 'client', %option);
}

1;

__END__

=head1 NAME

Unblock::WebSocket::Client - established client-side WebSocket protocol engine

=head1 SYNOPSIS

    my $ws = Unblock::WebSocket::Client->new(
        on_message => sub {
            my ($ws, $payload, $type) = @_;
        },
    );

    $ws->input($bytes_from_transport);
    $ws->send_text('hello');

    while ($ws->want_write) {
        $transport->write($ws->output);
    }

=head1 DESCRIPTION

This object owns established client-side WebSocket protocol state.

It does not connect a socket, perform TLS, perform the opening HTTP handshake,
or run an event loop.

Normally it is created after
L<Unblock::WebSocket::Handshake/connection_options> has validated the HTTP
response:

    my $ws = Unblock::WebSocket::Client->new(
        %{ $handshake->connection_options },
        on_message => sub { ... },
    );

When RFC 7692 was negotiated, those options carry the permessage-deflate state
needed by the established connection.

=head1 TRANSPORT MODEL

The optional attached mode is:

    my $ws = Unblock::WebSocket::Client->new(
        transport => $host,
        on_message => sub {
            my ($ws, $message, $type) = @_;
        },
    );

The host implements C<unblock_send($bytes)>, C<unblock_finish()> and
C<unblock_abort($reason)>. Feed incoming bytes using C<input()>.
Generated output is sent to the host automatically, including delayed sends.
A false host send return means the entire buffer was accepted but the host
is congested; call C<resume_output()> after write readiness returns.

Without C<transport>, the original manual mode still uses C<input()> and
C<output()> while C<want_write()> is true. Do not call C<output()> in attached
mode. C<input_eof()> reports read-side EOF and C<transport_error($reason)>
reports a broken transport. Neither is a WebSocket Close frame.

The host owns networking and must honor Close-frame output ordering. The
WebSocket object never directly reads or writes a socket.

=cut
