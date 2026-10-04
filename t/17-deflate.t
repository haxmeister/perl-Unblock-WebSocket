use strict;
use warnings;
use Test::More;

use Unblock::WebSocket::_Deflate;

my $codec = Unblock::WebSocket::_Deflate->new(
    role             => 'client',
    config           => {},
    max_message_size => 1024,
);

my $hello = $codec->compress('Hello');
is(
    unpack('H*', $hello),
    'f248cdc9c90700',
    'raw permessage-deflate output matches RFC 7692 Hello example',
);
is($codec->decompress($hello), 'Hello',
    'RFC example payload decompresses');

my $context = Unblock::WebSocket::_Deflate->new(
    role             => 'client',
    config           => {},
    max_message_size => 1024,
);
my $first = $context->compress('HelloHelloHello');
my $second = $context->compress('HelloHelloHello');
cmp_ok(length($second), '<', length($first),
    'context takeover reuses compression history');

my $no_context = Unblock::WebSocket::_Deflate->new(
    role => 'client',
    config => {
        client_no_context_takeover => 1,
    },
    max_message_size => 1024,
);
my $fresh1 = $no_context->compress('HelloHelloHello');
my $fresh2 = $no_context->compress('HelloHelloHello');
is($fresh2, $fresh1,
    'client_no_context_takeover starts each message with empty history');

my $sender = Unblock::WebSocket::_Deflate->new(
    role             => 'client',
    config           => {},
    max_message_size => 4096,
);
my $bomb = $sender->compress('A' x 1000);
my $limited = Unblock::WebSocket::_Deflate->new(
    role             => 'server',
    config           => {},
    max_message_size => 32,
);

my $ok = eval { $limited->decompress($bomb); 1 };
ok(!$ok, 'decompressed message limit rejects compression bomb');
like($@, qr/exceeds configured limit/i,
    'compression bomb reports configured message limit');

$ok = eval {
    Unblock::WebSocket::_Deflate->new(
        role => 'client',
        config => {
            client_max_window_bits => 8,
        },
        max_message_size => 1024,
    );
    1;
};
ok(!$ok, 'unsupported 8-bit compressor window is rejected');
like($@, qr/window must be between 9 and 15/i,
    '8-bit compressor window reports portable zlib limitation');

done_testing;
