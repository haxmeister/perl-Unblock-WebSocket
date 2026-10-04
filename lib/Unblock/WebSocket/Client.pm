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

This object owns WebSocket protocol state only. It does not connect a socket,
perform TLS, or run an event loop.

=cut
