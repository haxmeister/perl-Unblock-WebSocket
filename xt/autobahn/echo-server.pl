use strict;
use warnings;
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/lib";

use UnblockWebSocketAutobahn qw(
    accept_server_connection
    drive_connection
);

my $host = $ENV{AUTOBAHN_HOST} || '127.0.0.1';
my $port = defined($ENV{AUTOBAHN_PORT}) ? $ENV{AUTOBAHN_PORT} : 9001;

my $listener = IO::Socket::INET->new(
    LocalAddr => $host,
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 128,
    ReuseAddr => 1,
) or die "Autobahn listener failed: $!\n";

$listener->autoflush(1);
STDOUT->autoflush(1);
print "READY $host:" . $listener->sockport . "\n";

while (my $socket = $listener->accept) {
    eval {
        my ($ws, $tail) = accept_server_connection(
            $socket,
            permessage_deflate => 1,
            on_message => sub {
                my ($connection, $payload, $type) = @_;
                if ($type eq 'text') {
                    $connection->send_text($payload);
                }
                else {
                    $connection->send_binary($payload);
                }
            },
            on_error => sub {
                my ($connection, $error) = @_;
                warn "Autobahn server protocol error: $error\n";
            },
        );

        drive_connection($socket, $ws, $tail);
        1;
    } or warn "Autobahn server connection failed: $@";

    close $socket;
}
