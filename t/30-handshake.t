use strict;
use warnings;
use Test::More;

use Uniform::HTTP::Response;
use Unblock::WebSocket::Handshake;

for my $version ('1.1', '2', '3') {
    my ($client_hs, $request) = Unblock::WebSocket::Handshake->client_request(
        'wss://example.test/chat?room=1',
        http_version => $version,
        subprotocols => [ 'chat', 'superchat' ],
        ($version eq '1.1'
            ? (key => 'dGhlIHNhbXBsZSBub25jZQ==') : ()),
    );

    my $server_hs = Unblock::WebSocket::Handshake->server_accept(
        $request,
        subprotocols => [ 'superchat', 'chat' ],
    );
    my $response = $server_hs->server_response;
    $client_hs->validate_client_response($response);

    is $client_hs->subprotocol, 'chat', "$version negotiated first client-offered supported subprotocol";
    if ($version eq '1.1') {
        is $request->method, 'GET', 'HTTP/1.1 uses GET';
        is $response->status, 101, 'HTTP/1.1 uses 101';
    }
    else {
        is $request->method, 'CONNECT', "$version uses CONNECT";
        is $request->protocol, 'websocket', "$version uses extended CONNECT protocol";
        is $response->status, 200, "$version uses 200";
    }
}

done_testing;
