use strict;
use warnings;
use Test::More;

use Uniform::HTTP::Request 0.05;
use Uniform::HTTP::Response 0.05;
use Unblock::WebSocket::Handshake;

sub header_values {
    my ($message, $wanted) = @_;
    my @value;
    for my $index (0 .. $message->header_count - 1) {
        push @value, $message->header_value($index)
            if lc($message->header_name($index)) eq lc($wanted);
    }
    return @value;
}

sub base_request {
    my ($extension) = @_;
    my @headers = (
        [ Host => 'example.test' ],
        [ Upgrade => 'websocket' ],
        [ Connection => 'Upgrade' ],
        [ 'Sec-WebSocket-Key' => 'dGhlIHNhbXBsZSBub25jZQ==' ],
        [ 'Sec-WebSocket-Version' => '13' ],
    );
    push @headers, [ 'Sec-WebSocket-Extensions' => $extension ]
        if defined $extension;

    return Uniform::HTTP::Request->new(
        method    => 'GET',
        target    => '/chat',
        scheme    => 'https',
        authority => 'example.test',
        version   => '1.1',
        headers   => \@headers,
    );
}

sub response_for {
    my ($client, $extension) = @_;
    my @headers = (
        [ Upgrade => 'websocket' ],
        [ Connection => 'Upgrade' ],
        [ 'Sec-WebSocket-Accept' =>
            Unblock::WebSocket::Handshake->accept_key(
                'dGhlIHNhbXBsZSBub25jZQ==',
            ),
        ],
    );
    push @headers, [ 'Sec-WebSocket-Extensions' => $extension ]
        if defined $extension;

    return Uniform::HTTP::Response->new(
        status  => 101,
        version => '1.1',
        reason  => 'Switching Protocols',
        headers => \@headers,
    );
}

for my $version ('1.1', '2', '3') {
    my ($client, $request) =
        Unblock::WebSocket::Handshake->client_request(
            'wss://example.test/chat',
            http_version       => $version,
            permessage_deflate => 1,
            ($version eq '1.1'
                ? (key => 'dGhlIHNhbXBsZSBub25jZQ==') : ()),
        );

    is_deeply(
        [ header_values($request, 'Sec-WebSocket-Extensions') ],
        [ 'permessage-deflate' ],
        "$version client offers simple permessage-deflate",
    );

    my $server = Unblock::WebSocket::Handshake->server_accept(
        $request,
        permessage_deflate => 1,
    );
    is_deeply($server->permessage_deflate, {},
        "$version server accepts simple permessage-deflate");

    my $response = $server->server_response;
    is_deeply(
        [ header_values($response, 'Sec-WebSocket-Extensions') ],
        [ 'permessage-deflate' ],
        "$version server emits negotiated extension",
    );

    $client->validate_client_response($response);
    is_deeply($client->permessage_deflate, {},
        "$version client validates negotiated extension");
    is_deeply(
        $client->connection_options,
        { permessage_deflate => {} },
        "$version handshake exports connection options",
    );
}

{
    my ($client, $request) =
        Unblock::WebSocket::Handshake->client_request(
            'wss://example.test/chat',
            http_version => '1.1',
            key          => 'dGhlIHNhbXBsZSBub25jZQ==',
            permessage_deflate => {
                server_no_context_takeover => 1,
                client_no_context_takeover => 1,
                server_max_window_bits     => 12,
            },
        );

    is_deeply(
        [ header_values($request, 'Sec-WebSocket-Extensions') ],
        [
            'permessage-deflate; server_no_context_takeover; '
            . 'client_no_context_takeover; server_max_window_bits=12'
        ],
        'client serializes directional compression offer',
    );

    my $server = Unblock::WebSocket::Handshake->server_accept(
        $request,
        permessage_deflate => {
            server_max_window_bits     => 10,
            client_no_context_takeover => 1,
        },
    );

    my $expected = {
        server_no_context_takeover => 1,
        client_no_context_takeover => 1,
        server_max_window_bits     => 10,
    };
    is_deeply($server->permessage_deflate, $expected,
        'server honors required and policy compression parameters');

    my $response = $server->server_response;
    $client->validate_client_response($response);
    is_deeply($client->permessage_deflate, $expected,
        'client accepts compatible directional response');
}

{
    my $request = base_request(
        'permessage-deflate; server_max_window_bits=8, permessage-deflate'
    );
    my $server = Unblock::WebSocket::Handshake->server_accept(
        $request,
        permessage_deflate => 1,
    );
    is_deeply($server->permessage_deflate, {},
        'server skips unsupported 8-bit compressor offer and accepts fallback');
}

{
    my $request = base_request(
        'permessage-deflate; client_max_window_bits'
    );
    my $server = Unblock::WebSocket::Handshake->server_accept(
        $request,
        permessage_deflate => {
            client_max_window_bits => 10,
        },
    );
    is_deeply(
        $server->permessage_deflate,
        { client_max_window_bits => 10 },
        'server may constrain client window when client offered the parameter',
    );
    is_deeply(
        [ header_values($server->server_response, 'Sec-WebSocket-Extensions') ],
        [ 'permessage-deflate; client_max_window_bits=10' ],
        'server serializes selected client window',
    );
}

{
    my $request = base_request(
        'permessage-deflate; server_no_context_takeover; '
        . 'server_no_context_takeover, permessage-deflate'
    );
    my $server = Unblock::WebSocket::Handshake->server_accept(
        $request,
        permessage_deflate => 1,
    );
    is_deeply($server->permessage_deflate, {},
        'server declines malformed duplicate-parameter offer and uses fallback');
}

{
    my ($client) = Unblock::WebSocket::Handshake->client_request(
        'wss://example.test/chat',
        http_version => '1.1',
        key          => 'dGhlIHNhbXBsZSBub25jZQ==',
    );
    my $ok = eval {
        $client->validate_client_response(
            response_for($client, 'permessage-deflate')
        );
        1;
    };
    ok(!$ok, 'client rejects unsolicited permessage-deflate');
    like($@, qr/unsupported extension/i,
        'unsolicited compression reports unsupported extension');
}

{
    my ($client) = Unblock::WebSocket::Handshake->client_request(
        'wss://example.test/chat',
        http_version => '1.1',
        key          => 'dGhlIHNhbXBsZSBub25jZQ==',
        permessage_deflate => {
            server_no_context_takeover => 1,
        },
    );
    my $ok = eval {
        $client->validate_client_response(
            response_for($client, 'permessage-deflate')
        );
        1;
    };
    ok(!$ok, 'client rejects response that drops required no-context request');
    like($@, qr/omitted required server_no_context_takeover/i,
        'missing required no-context parameter is explicit');
}

{
    my ($client) = Unblock::WebSocket::Handshake->client_request(
        'wss://example.test/chat',
        http_version => '1.1',
        key          => 'dGhlIHNhbXBsZSBub25jZQ==',
        permessage_deflate => {
            server_max_window_bits => 12,
        },
    );
    my $ok = eval {
        $client->validate_client_response(
            response_for(
                $client,
                'permessage-deflate; server_max_window_bits=13',
            )
        );
        1;
    };
    ok(!$ok, 'client rejects server window larger than offered maximum');
    like($@, qr/increased server_max_window_bits/i,
        'oversized server window is explicit');
}

{
    my $ok = eval {
        Unblock::WebSocket::Handshake->client_request(
            'wss://example.test/chat',
            http_version => '1.1',
            key          => 'dGhlIHNhbXBsZSBub25jZQ==',
            permessage_deflate => {
                client_max_window_bits => 15,
            },
        );
        1;
    };
    ok(!$ok,
        'client does not advertise client_max_window_bits before 8-bit support');
    like($@, qr/8-bit compressor window/i,
        'client window limitation explains zlib constraint');
}

done_testing;
