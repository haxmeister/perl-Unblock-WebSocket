package Unblock::WebSocket::Server;

use strict;
use warnings;
use parent 'Unblock::WebSocket::_Engine';

sub new {
    my ($class, %option) = @_;
    return $class->_new(role => 'server', %option);
}

1;

__END__

=head1 NAME

Unblock::WebSocket::Server - established server-side WebSocket protocol engine

=head1 SYNOPSIS

    my $ws = Unblock::WebSocket::Server->new(
        on_message => sub {
            my ($ws, $payload, $type) = @_;
        },
    );

    $ws->input($bytes_from_transport);

    while ($ws->want_write) {
        $transport->write($ws->output);
    }

=head1 DESCRIPTION

This object owns established server-side WebSocket protocol state.

It does not own a listener, socket, TLS connection, HTTP server, timer, or event
loop.

Normally it is created after
L<Unblock::WebSocket::Handshake/server_accept> validates the opening request:

    my $ws = Unblock::WebSocket::Server->new(
        %{ $handshake->connection_options },
        on_message => sub { ... },
    );

When RFC 7692 was negotiated, those options carry the permessage-deflate state
needed by the established connection.

=head1 TRANSPORT MODEL

An attached host can handle output automatically:

    my $ws = Unblock::WebSocket::Server->new(
        transport => $host,
        on_message => sub {
            my ($ws, $message, $type) = @_;
            $ws->send_text($message);
        },
    );

The host supplies C<unblock_send($bytes)>, C<unblock_finish()> and
C<unblock_abort($reason)>. It feeds incoming bytes with C<input()>.
All generated output, including output from later application callbacks, is
handed to C<unblock_send()>. The host accepts the whole buffer or throws. A
false result signals congestion after acceptance; call C<resume_output()>
when the host is ready again.

Without C<transport>, manual input/output remains supported: call C<output()>
while C<want_write()> is true. C<output()> cannot be used with an attached
transport. C<input_eof()> means read-side EOF, while
C<transport_error($reason)> means a broken transport and immediate abort.

The host owns networking and must drain already accepted bytes before a
graceful finish. C<close()> starts the WebSocket Close handshake, not immediate
socket teardown.

=cut
