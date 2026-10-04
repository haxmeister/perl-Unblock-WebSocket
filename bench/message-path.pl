use strict;
use warnings;

use Time::HiRes qw(time);

use Unblock::WebSocket;
use Unblock::WebSocket::Client;
use Unblock::WebSocket::Server;

my $seconds = defined($ENV{BENCH_SECONDS}) ? $ENV{BENCH_SECONDS} : 0.75;
my @sizes = @ARGV ? @ARGV : (64, 256, 1024, 16_384);
my $batch = 32;

die "BENCH_SECONDS must be positive\n"
    unless $seconds =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/
        && $seconds > 0;

sub measure {
    my ($name, $size, $code) = @_;

    $code->() for 1 .. 128;

    my $start = time;
    my $deadline = $start + $seconds;
    my $count = 0;

    while (1) {
        $code->() for 1 .. $batch;
        $count += $batch;
        last if time >= $deadline;
    }

    my $elapsed = time - $start;
    my $rate = $count / $elapsed;
    my $mib = $rate * $size / (1024 * 1024);

    printf "%-22s %8d %14.0f %12.2f\n",
        $name, $size, $rate, $mib;
}

sub pair {
    my ($backend, $compressed, $payload) = @_;
    my $received = 0;

    my %common = (
        backend          => $backend,
        max_message_size => length($payload) + 4096,
    );
    $common{permessage_deflate} = {} if $compressed;

    my $server = Unblock::WebSocket::Server->new(
        %common,
        on_message => sub {
            my ($ws, $message, $type) = @_;
            die "benchmark payload mismatch\n"
                unless $type eq 'binary' && $message eq $payload;
            ++$received;
        },
    );

    my $client = Unblock::WebSocket::Client->new(%common);

    return sub {
        my $before = $received;
        $client->send_binary($payload);
        my $wire = $client->output;
        die "benchmark client produced no wire output\n"
            unless length $wire;
        $server->input($wire);
        die "benchmark message was not delivered exactly once\n"
            unless $received == $before + 1;
    };
}

printf "%-22s %8s %14s %12s\n",
    'path', 'bytes', 'messages/s', 'payload MiB/s';

for my $size (@sizes) {
    die "size must be a positive integer\n"
        unless defined($size) && $size =~ /\A[0-9]+\z/ && $size > 0;

    my $payload = 'x' x $size;

    measure(
        'perl',
        $size,
        pair('perl', 0, $payload),
    );

    if (Unblock::WebSocket->native_available) {
        measure(
            'native',
            $size,
            pair('native', 0, $payload),
        );
    }

    measure(
        'perl+deflate',
        $size,
        pair('perl', 1, $payload),
    );

    if (Unblock::WebSocket->native_available) {
        measure(
            'native+deflate',
            $size,
            pair('native', 1, $payload),
        );
    }
}
