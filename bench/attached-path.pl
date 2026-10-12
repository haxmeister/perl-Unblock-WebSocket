#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(time);

use Unblock::WebSocket;
use Unblock::WebSocket::Server;

{
    package Local::BenchmarkSink;
    sub new { bless { bytes => 0, calls => 0 }, shift }
    sub unblock_send {
        my ($self, $bytes) = @_;
        $self->{bytes} += length($bytes);
        ++$self->{calls};
        return;
    }
    sub unblock_finish { return }
    sub unblock_abort { die "benchmark host aborted: $_[1]" }
}

my $iterations = shift @ARGV || 10_000;
die "iteration count must be positive\n"
    unless $iterations =~ /\A[0-9]+\z/ && $iterations > 0;

my @backend = ('perl');
push @backend, 'native' if Unblock::WebSocket->native_available;

printf "%-8s %-12s %7s %12s %12s\n",
    'backend', 'output', 'bytes', 'messages/s', 'wire MiB/s';

for my $backend (@backend) {
    for my $size (64, 1024) {
        my $payload = 'x' x $size;
        for my $mode ('manual', 'attached') {
            my $host = Local::BenchmarkSink->new;
            my $ws = Unblock::WebSocket::Server->new(
                backend => $backend,
                ($mode eq 'attached' ? (transport => $host) : ()),
            );

            my $round = sub {
                $ws->send_binary($payload);
                if ($mode eq 'manual') {
                    while ($ws->want_write) {
                        $host->unblock_send($ws->output);
                    }
                }
            };

            $round->() for 1 .. 1000; # Keep warmup outside measurement.
            $host->{bytes} = 0;
            $host->{calls} = 0;

            my $start = time();
            $round->() for 1 .. $iterations;
            my $elapsed = time() - $start;
            my $rate = $iterations / ($elapsed || 0.000001);
            my $mib = $host->{bytes} / (1024 * 1024)
                / ($elapsed || 0.000001);

            printf "%-8s %-12s %7d %12.0f %12.2f\n",
                $backend, $mode, $size, $rate, $mib;

            die 'benchmark did not send all messages'
                unless $host->{calls} == $iterations;
        }
    }
}

print "Results are same-run development measurements, not absolute baselines.\n";
