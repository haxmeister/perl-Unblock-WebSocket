use strict;
use warnings;
use JSON::PP qw(decode_json);

my $file = shift @ARGV || 'xt/autobahn/reports/servers/index.json';
my $expected_cases = shift @ARGV;

open my $fh, '<', $file
    or die "cannot open Autobahn report $file: $!\n";
local $/;
my $report = decode_json(<$fh>);
close $fh;

my %allowed = map { $_ => 1 } qw(OK NON-STRICT INFORMATIONAL);
my @failure;
my %behavior;

for my $agent (sort keys %$report) {
    my $case_count = scalar keys %{$report->{$agent}};
    print "Autobahn cases for $agent: $case_count\n";
    push @failure, [
        $agent,
        '-',
        "cases=$case_count expected=$expected_cases",
        undef,
    ] if defined($expected_cases) && $case_count != $expected_cases;

    for my $case (sort keys %{$report->{$agent}}) {
        my $result = $report->{$agent}{$case};
        my $status = $result->{behavior} || 'UNKNOWN';
        my $close_status = $result->{behaviorClose} || 'UNKNOWN';
        ++$behavior{$status};
        ++$behavior{"close:$close_status"};

        push @failure, [
            $agent, $case, "behavior=$status", $result->{reportfile},
        ] if !$allowed{$status};

        push @failure, [
            $agent, $case, "close=$close_status", $result->{reportfile},
        ] if !$allowed{$close_status};
    }
}

print "Autobahn behavior summary:\n";
print "  $_: $behavior{$_}\n" for sort keys %behavior;

if (@failure) {
    print STDERR "Autobahn conformance failures:\n";
    for my $failure (@failure) {
        my ($agent, $case, $status, $reportfile) = @$failure;
        print STDERR "  $agent case $case: $status"
            . (defined($reportfile) ? " ($reportfile)" : '') . "\n";
    }
    exit 1;
}

print defined($expected_cases)
    ? "Autobahn RFC 6455 conformance passed ($expected_cases cases per agent).\n"
    : "Autobahn RFC 6455 conformance passed.\n";
