# WebSocket author benchmarks

These benchmarks are repository-only development tools. They are excluded from
the CPAN distribution and do not run under make test.

message-path.pl measures the established public client-to-server message path.
It includes client masking, frame production, output drain, server parsing,
optional permessage-deflate transformation, and application callback delivery.

It compares:

- Perl framing without compression;
- native bq framing without compression, when XS is available;
- Perl framing with permessage-deflate;
- native bq framing with the same shared permessage-deflate codec.

The default payload sizes are 64 B, 256 B, 1 KiB, and 16 KiB. Pass sizes on the
command line to override them. BENCH_SECONDS controls the measurement interval
per case.

Examples:

    perl -Mblib bench/message-path.pl
    BENCH_SECONDS=2 perl -Mblib bench/message-path.pl 64 1024 16384

The benchmark deliberately measures payload throughput, not compressed wire
bytes. Its purpose is to show framing/dispatch cost at the same application
workload. Hosted-runner numbers are useful for same-run relative comparisons,
not hardware-independent performance claims.
