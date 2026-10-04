use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use UnblockWebSocketAutobahn qw(
    drive_connection
    open_client_connection
);

my $base = $ENV{AUTOBAHN_URL} || 'ws://127.0.0.1:9001';
my $agent = 'UnblockWebSocket';
my $case_count;

sub run_connection {
    my ($url, %option) = @_;
    my ($socket, $ws, $tail) = open_client_connection($url, %option);
    drive_connection($socket, $ws, $tail);
    close $socket;
    return;
}

run_connection(
    "$base/getCaseCount",
    on_message => sub {
        my ($ws, $payload, $type) = @_;
        die "Autobahn case count was not decimal text\n"
            if $type ne 'text' || $payload !~ /\A[0-9]+\z/;
        $case_count = 0 + $payload;
    },
    on_error => sub {
        my ($ws, $error) = @_;
        warn "Autobahn case-count protocol error: $error\n";
    },
);

die "Autobahn did not provide a valid case count\n"
    if !defined($case_count) || $case_count < 1;

print "Autobahn client cases: $case_count\n";

for my $case (1 .. $case_count) {
    print "Running Autobahn client case $case/$case_count\n";

    run_connection(
        "$base/runCase?case=$case&agent=$agent",
        on_message => sub {
            my ($ws, $payload, $type) = @_;
            if ($type eq 'text') {
                $ws->send_text($payload);
            }
            else {
                $ws->send_binary($payload);
            }
        },
        on_error => sub {
            my ($ws, $error) = @_;
            warn "Autobahn client case $case protocol error: $error\n";
        },
    );
}

eval {
    run_connection(
        "$base/updateReports?agent=$agent",
        on_error => sub {
            my ($ws, $error) = @_;
            warn "Autobahn report-control protocol error: $error\n";
        },
    );
    1;
} or warn "Autobahn report-control connection ended: $@";

print "Autobahn client run completed.\n";
