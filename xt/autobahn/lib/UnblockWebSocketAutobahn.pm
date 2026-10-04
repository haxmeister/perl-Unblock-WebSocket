package UnblockWebSocketAutobahn;

use strict;
use warnings;
use Exporter 'import';
use IO::Select;
use IO::Socket::INET;
use URI ();

use Uniform::HTTP::Request;
use Uniform::HTTP::Response;
use Unblock::WebSocket::Client;
use Unblock::WebSocket::Handshake;
use Unblock::WebSocket::Server;

our @EXPORT_OK = qw(
    accept_server_connection
    drive_connection
    open_client_connection
);

sub _write_all {
    my ($socket, $bytes) = @_;
    my $offset = 0;

    while ($offset < length($bytes)) {
        my $written = syswrite(
            $socket,
            $bytes,
            length($bytes) - $offset,
            $offset,
        );
        die "Autobahn socket write failed: $!\n"
            unless defined $written;
        die "Autobahn socket write returned zero\n"
            if $written == 0;
        $offset += $written;
    }

    return;
}

sub _read_http_head {
    my ($socket) = @_;
    my $buffer = '';
    my $select = IO::Select->new($socket);

    while (1) {
        my $marker = index($buffer, "\r\n\r\n");
        if ($marker >= 0) {
            my $head = substr($buffer, 0, $marker, '');
            substr($buffer, 0, 4, '');
            return ($head, $buffer);
        }

        die "Autobahn HTTP handshake exceeded 64 KiB\n"
            if length($buffer) > 64 * 1024;
        die "Autobahn HTTP handshake timed out\n"
            unless $select->can_read(15);

        my $chunk = '';
        my $read = sysread($socket, $chunk, 16 * 1024);
        die "Autobahn socket read failed during handshake: $!\n"
            unless defined $read;
        die "Autobahn peer closed during HTTP handshake\n"
            if $read == 0;
        $buffer .= $chunk;
    }
}

sub _parse_headers {
    my (@line) = @_;
    my @header;

    for my $line (@line) {
        die "Autobahn HTTP header continuation is not supported\n"
            if $line =~ /^[ \t]/;
        my ($name, $value) = $line =~ /\A([^:]+):[ \t]*(.*)\z/;
        die "Autobahn HTTP header is malformed: $line\n"
            unless defined $name;
        push @header, [ $name, $value ];
    }

    return \@header;
}

sub _parse_request {
    my ($head) = @_;
    my @line = split /\r\n/, $head, -1;
    my $start = shift @line;
    my ($method, $target, $version) =
        $start =~ /\A([^ ]+) ([^ ]+) HTTP\/(1\.1)\z/;
    die "Autobahn HTTP request line is malformed: $start\n"
        unless defined $method;

    my $headers = _parse_headers(@line);
    my ($host) = map { $_->[1] }
        grep { lc($_->[0]) eq 'host' } @$headers;

    return Uniform::HTTP::Request->new(
        method    => $method,
        target    => $target,
        scheme    => 'http',
        authority => defined($host) ? $host : '',
        version   => $version,
        headers   => $headers,
    );
}

sub _parse_response {
    my ($head) = @_;
    my @line = split /\r\n/, $head, -1;
    my $start = shift @line;
    my ($version, $status, $reason) =
        $start =~ /\AHTTP\/(1\.1) ([0-9]{3})(?: (.*))?\z/;
    die "Autobahn HTTP response line is malformed: $start\n"
        unless defined $status;

    return Uniform::HTTP::Response->new(
        status  => 0 + $status,
        version => $version,
        (defined($reason) ? (reason => $reason) : ()),
        headers => _parse_headers(@line),
    );
}

sub _serialize_request {
    my ($request) = @_;
    my $wire = $request->method . ' ' . $request->target
        . ' HTTP/' . $request->version . "\r\n";

    for my $index (0 .. $request->header_count - 1) {
        $wire .= $request->header_name($index) . ': '
            . $request->header_value($index) . "\r\n";
    }

    return $wire . "\r\n";
}

sub _serialize_response {
    my ($response) = @_;
    my $reason = $response->reason;
    $reason = '' unless defined $reason;
    my $wire = 'HTTP/' . $response->version . ' '
        . $response->status . ($reason ne '' ? " $reason" : '') . "\r\n";

    for my $index (0 .. $response->header_count - 1) {
        $wire .= $response->header_name($index) . ': '
            . $response->header_value($index) . "\r\n";
    }

    return $wire . "\r\n";
}

sub _socket_target {
    my ($url) = @_;
    my $http = "$url";
    $http =~ s/\Aws:/http:/;
    my $uri = URI->new($http);

    my $host = $uri->host;
    die "Autobahn URL has no host: $url\n"
        unless defined($host) && length($host);
    my $port = $uri->port;
    $port = 80 unless defined $port;

    return ($host, $port);
}

sub open_client_connection {
    my ($url, %option) = @_;

    my $pmd = delete $option{permessage_deflate};
    my %handshake_option = (
        http_version => '1.1',
    );
    $handshake_option{permessage_deflate} = $pmd
        if defined $pmd;

    my ($handshake, $request) =
        Unblock::WebSocket::Handshake->client_request(
            $url,
            %handshake_option,
        );

    my ($host, $port) = _socket_target($url);
    my $socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "Autobahn client connect to $host:$port failed: $!\n";

    _write_all($socket, _serialize_request($request));
    my ($head, $tail) = _read_http_head($socket);
    my $response = _parse_response($head);
    $handshake->validate_client_response($response);

    my $ws = Unblock::WebSocket::Client->new(
        %{ $handshake->connection_options },
        %option,
    );
    return ($socket, $ws, $tail);
}

sub accept_server_connection {
    my ($socket, %option) = @_;

    my $pmd = delete $option{permessage_deflate};
    my ($head, $tail) = _read_http_head($socket);
    my $request = _parse_request($head);

    my %handshake_option;
    $handshake_option{permessage_deflate} = $pmd
        if defined $pmd;

    my $handshake =
        Unblock::WebSocket::Handshake->server_accept(
            $request,
            %handshake_option,
        );
    my $response = $handshake->server_response;
    _write_all($socket, _serialize_response($response));

    my $ws = Unblock::WebSocket::Server->new(
        %{ $handshake->connection_options },
        %option,
    );
    return ($ws, $tail);
}

sub _drain_output {
    my ($socket, $ws) = @_;

    while ($ws->want_write) {
        my $bytes = $ws->output(64 * 1024);
        _write_all($socket, $bytes);
    }

    return;
}

sub drive_connection {
    my ($socket, $ws, $tail) = @_;
    my $select = IO::Select->new($socket);

    if (defined($tail) && length($tail)) {
        $ws->input($tail);
        _drain_output($socket, $ws);
    }

    while (!$ws->is_closed) {
        _drain_output($socket, $ws);
        last if $ws->want_end && !$ws->want_write;

        die "Autobahn WebSocket connection timed out\n"
            unless $select->can_read(30);

        my $buffer = '';
        my $read = sysread($socket, $buffer, 64 * 1024);
        die "Autobahn socket read failed: $!\n"
            unless defined $read;

        if ($read == 0) {
            $ws->input_eof;
            last;
        }

        $ws->input($buffer);
    }

    _drain_output($socket, $ws);
    return;
}

1;
