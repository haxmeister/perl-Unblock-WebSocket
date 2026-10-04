package Unblock::WebSocket::Handshake;

use strict;
use warnings;
use Carp qw(croak);
use Digest::SHA qw(sha1);
use MIME::Base64 qw(decode_base64 encode_base64);
use URI ();
use Uniform::HTTP::FastPath 0.05 ();

use Unblock::WebSocket::_Random ();

my $GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
my $TOKEN_RE = qr/\A[!#\$%&'*+\-.^_`|~0-9A-Za-z]+\z/;

sub _trim {
    my ($value) = @_;
    $value =~ s/\A[ \t]+//;
    $value =~ s/[ \t]+\z//;
    return $value;
}

sub _fast_view {
    my ($message) = @_;
    return unless Uniform::HTTP::FastPath::can_view($message);
    return Uniform::HTTP::FastPath::view($message);
}

sub _message_value {
    my ($message, $view, $slot, $method) = @_;
    return $view ? $view->[$slot] : $message->$method();
}

sub _header_values {
    my ($message, $wanted, $view) = @_;
    my @value;

    if ($view) {
        my $headers =
            $view->[Uniform::HTTP::FastPath::SLOT_HEADERS()];
        for my $field (@$headers) {
            push @value, $field->[1]
                if lc($field->[0]) eq lc($wanted);
        }
        return @value;
    }

    for my $index (0 .. $message->header_count - 1) {
        my $name = $message->header_name($index);
        push @value, $message->header_value($index)
            if lc($name) eq lc($wanted);
    }
    return @value;
}

sub _tokens {
    my ($where, @value) = @_;
    my @token;
    for my $value (@value) {
        for my $token (split /,/, $value, -1) {
            $token = _trim($token);
            croak "$where contains an empty token" if $token eq '';
            croak "$where contains an invalid token '$token'"
                if $token !~ $TOKEN_RE;
            push @token, $token;
        }
    }
    return @token;
}

sub _singleton {
    my ($message, $name, $view) = @_;
    my @value = _header_values($message, $name, $view);
    croak "WebSocket handshake requires $name" unless @value;
    croak "WebSocket handshake contains duplicate $name" if @value > 1;
    return _trim($value[0]);
}

sub _has_token {
    my ($message, $name, $wanted, $view) = @_;
    for my $token (_tokens(
        $name,
        _header_values($message, $name, $view),
    )) {
        return 1 if lc($token) eq lc($wanted);
    }
    return 0;
}

sub _checked_subprotocols {
    my ($where, $value) = @_;
    $value ||= [];
    croak "$where: subprotocols must be an array reference"
        unless ref($value) eq 'ARRAY';
    my %seen;
    my @copy;
    for my $token (@$value) {
        croak "$where: each subprotocol must be a WebSocket token"
            if !defined($token) || ref($token) || $token !~ $TOKEN_RE;
        croak "$where: duplicate subprotocol '$token'" if $seen{$token}++;
        push @copy, "$token";
    }
    return \@copy;
}

sub _valid_key {
    my ($key) = @_;
    return 0 unless defined($key) && !ref($key);
    return 0 unless $key =~ /\A[A-Za-z0-9+\/]{22}==\z/;
    return length(decode_base64($key)) == 16 ? 1 : 0;
}

sub accept_key {
    my ($class, $key) = @_;
    croak 'accept_key(): invalid Sec-WebSocket-Key' unless _valid_key($key);
    return encode_base64(sha1($key . $GUID), '');
}

sub client_request {
    my ($class, $url, %option) = @_;
    croak 'client_request(): URL must be a non-empty scalar'
        if !defined($url) || ref($url) || $url eq '';

    my $http_version = exists($option{http_version})
        ? delete($option{http_version}) : '1.1';
    croak 'client_request(): http_version must be 1.1, 2, or 3'
        unless defined($http_version) && !ref($http_version)
            && ($http_version eq '1.1' || $http_version eq '2' || $http_version eq '3');

    my $subprotocols = _checked_subprotocols(
        'client_request()', delete($option{subprotocols}) || [],
    );
    my $origin = delete $option{origin};
    croak 'client_request(): origin must be a scalar'
        if defined($origin) && ref($origin);

    my $key_option = delete $option{key};
    croak 'client_request(): key must be a scalar'
        if defined($key_option) && ref($key_option);

    my $headers = delete($option{headers}) || [];
    croak 'client_request(): headers must be an array reference'
        unless ref($headers) eq 'ARRAY';

    croak 'client_request(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my ($scheme) = "$url" =~ /\A([A-Za-z][A-Za-z0-9+.-]*):/;
    $scheme = lc($scheme || '');
    croak 'client_request(): URL scheme must be ws or wss'
        unless $scheme eq 'ws' || $scheme eq 'wss';

    my $http_url = "$url";
    my $http_scheme = $scheme eq 'wss' ? 'https' : 'http';
    $http_url =~ s/\A[A-Za-z][A-Za-z0-9+.-]*:/$http_scheme:/;
    my $uri = URI->new($http_url);
    croak 'client_request(): URL userinfo is not supported'
        if defined($uri->userinfo) && length($uri->userinfo);

    my $host = $uri->host;
    croak 'client_request(): URL must contain a host'
        unless defined($host) && length($host);
    my $port = $uri->port;
    my $default_port = $scheme eq 'wss' ? 443 : 80;
    my $authority = $host =~ /:/ ? "[$host]" : $host;
    $authority .= ":$port" if defined($port) && $port != $default_port;

    my $target = $uri->path;
    $target = '/' unless defined($target) && length($target);
    my $query = $uri->query;
    $target .= "?$query" if defined($query) && length($query);

    my %reserved = map { $_ => 1 } qw(
        host connection upgrade origin sec-websocket-key
        sec-websocket-version sec-websocket-protocol sec-websocket-extensions
    );
    my @extra;
    for my $pair (@$headers) {
        croak 'client_request(): each header must be a [name, value] pair'
            unless ref($pair) eq 'ARRAY' && @$pair == 2;
        my ($name, $value) = @$pair;
        croak 'client_request(): header name and value must be scalars'
            if !defined($name) || ref($name) || !defined($value) || ref($value);
        croak "client_request(): WebSocket handshake owns header $name"
            if $reserved{lc $name};
        push @extra, [ "$name", "$value" ];
    }

    require Uniform::HTTP::Request;

    my ($request, $key);
    if ($http_version eq '1.1') {
        $key = defined($key_option)
            ? "$key_option"
            : encode_base64(Unblock::WebSocket::_Random->bytes(16), '');
        croak 'client_request(): key must be a valid base64-encoded 16-byte value'
            unless _valid_key($key);
        my @ws_headers = (
            [ Host                    => $authority ],
            [ Upgrade                 => 'websocket' ],
            [ Connection              => 'Upgrade' ],
            [ 'Sec-WebSocket-Key'     => $key ],
            [ 'Sec-WebSocket-Version' => '13' ],
        );
        push @ws_headers,
            [ 'Sec-WebSocket-Protocol' => join(', ', @$subprotocols) ]
            if @$subprotocols;
        push @ws_headers, [ Origin => "$origin" ] if defined $origin;
        push @ws_headers, @extra;

        $request = Uniform::HTTP::Request->new(
            method    => 'GET',
            target    => $target,
            scheme    => $scheme eq 'wss' ? 'https' : 'http',
            authority => $authority,
            version   => '1.1',
            headers   => \@ws_headers,
        );
    }
    else {
        croak 'client_request(): key is only valid for HTTP/1.1'
            if defined $key_option;
        my @ws_headers = (
            [ 'Sec-WebSocket-Version' => '13' ],
        );
        push @ws_headers,
            [ 'Sec-WebSocket-Protocol' => join(', ', @$subprotocols) ]
            if @$subprotocols;
        push @ws_headers, [ Origin => "$origin" ] if defined $origin;
        push @ws_headers, @extra;

        $request = Uniform::HTTP::Request->new(
            method    => 'CONNECT',
            protocol  => 'websocket',
            target    => $target,
            scheme    => $scheme eq 'wss' ? 'https' : 'http',
            authority => $authority,
            version   => "$http_version",
            headers   => \@ws_headers,
        );
    }

    my $self = bless {
        side                 => 'client',
        http_version         => "$http_version",
        key                  => $key,
        offered_subprotocols => [ @$subprotocols ],
        selected_subprotocol => undef,
    }, $class;

    return ($self, $request);
}

sub server_accept {
    my ($class, $request, %option) = @_;
    croak 'server_accept(): request object is required'
        unless defined($request) && ref($request);

    my $supported = _checked_subprotocols(
        'server_accept()', delete($option{subprotocols}) || [],
    );
    croak 'server_accept(): unknown option(s): ' . join(', ', sort keys %option)
        if %option;

    my $view = _fast_view($request);
    my $version = _message_value(
        $request,
        $view,
        Uniform::HTTP::FastPath::SLOT_VERSION(),
        'version',
    );
    croak 'server_accept(): request version must be known'
        unless defined $version;

    my $key;
    if ($version eq '1.1') {
        my $method = _message_value(
            $request,
            $view,
            Uniform::HTTP::FastPath::SLOT_METHOD(),
            'method',
        );
        croak 'WebSocket HTTP/1.1 handshake method must be GET'
            unless $method eq 'GET';
        croak 'WebSocket handshake Upgrade header must contain websocket'
            unless _has_token($request, 'Upgrade', 'websocket', $view);
        croak 'WebSocket handshake Connection header must contain Upgrade'
            unless _has_token($request, 'Connection', 'Upgrade', $view);
        my $ws_version =
            _singleton($request, 'Sec-WebSocket-Version', $view);
        croak 'WebSocket handshake Sec-WebSocket-Version must be 13'
            unless $ws_version eq '13';
        $key = _singleton($request, 'Sec-WebSocket-Key', $view);
        croak 'WebSocket handshake contains invalid Sec-WebSocket-Key'
            unless _valid_key($key);
    }
    elsif ($version eq '2' || $version eq '3') {
        my $method = _message_value(
            $request,
            $view,
            Uniform::HTTP::FastPath::SLOT_METHOD(),
            'method',
        );
        my $protocol = _message_value(
            $request,
            $view,
            Uniform::HTTP::FastPath::SLOT_PROTOCOL(),
            'protocol',
        );
        croak 'WebSocket Extended CONNECT method must be CONNECT'
            unless $method eq 'CONNECT';
        croak 'WebSocket Extended CONNECT :protocol must be websocket'
            unless defined($protocol) && $protocol eq 'websocket';
        my $ws_version =
            _singleton($request, 'Sec-WebSocket-Version', $view);
        croak 'WebSocket handshake Sec-WebSocket-Version must be 13'
            unless $ws_version eq '13';
        croak 'WebSocket HTTP/2 and HTTP/3 handshake must not contain Sec-WebSocket-Key'
            if _header_values($request, 'Sec-WebSocket-Key', $view);
    }
    else {
        croak "WebSocket handshake does not support HTTP version $version";
    }

    my @offered = _tokens(
        'Sec-WebSocket-Protocol',
        _header_values($request, 'Sec-WebSocket-Protocol', $view),
    );
    my %seen;
    for my $token (@offered) {
        croak "WebSocket handshake contains duplicate subprotocol '$token'"
            if $seen{$token}++;
    }

    my %supported = map { $_ => 1 } @$supported;
    my ($selected) = grep { $supported{$_} } @offered;

    return bless {
        side                 => 'server',
        http_version         => "$version",
        key                  => $key,
        offered_subprotocols => \@offered,
        selected_subprotocol => $selected,
    }, $class;
}

sub server_response {
    my ($self) = @_;
    croak 'server_response(): requires a server handshake'
        unless ref($self) && $self->{side} eq 'server';

    require Uniform::HTTP::Response;

    my @headers;
    my $status;
    my $reason;
    if ($self->{http_version} eq '1.1') {
        $status = 101;
        $reason = 'Switching Protocols';
        @headers = (
            [ Upgrade => 'websocket' ],
            [ Connection => 'Upgrade' ],
            [ 'Sec-WebSocket-Accept' => __PACKAGE__->accept_key($self->{key}) ],
        );
    }
    else {
        $status = 200;
    }

    push @headers,
        [ 'Sec-WebSocket-Protocol' => $self->{selected_subprotocol} ]
        if defined $self->{selected_subprotocol};

    return Uniform::HTTP::Response->new(
        status  => $status,
        version => $self->{http_version},
        (defined($reason) ? (reason => $reason) : ()),
        headers => \@headers,
    );
}

sub validate_client_response {
    my ($self, $response) = @_;
    croak 'validate_client_response(): requires a client handshake'
        unless ref($self) && $self->{side} eq 'client';
    croak 'validate_client_response(): response object is required'
        unless defined($response) && ref($response);

    my $view = _fast_view($response);
    my $status = _message_value(
        $response,
        $view,
        Uniform::HTTP::FastPath::SLOT_STATUS(),
        'status',
    );

    if ($self->{http_version} eq '1.1') {
        croak 'WebSocket handshake response status must be 101'
            unless $status == 101;
        croak 'WebSocket handshake response Upgrade header must contain websocket'
            unless _has_token($response, 'Upgrade', 'websocket', $view);
        croak 'WebSocket handshake response Connection header must contain Upgrade'
            unless _has_token($response, 'Connection', 'Upgrade', $view);
        my $accept =
            _singleton($response, 'Sec-WebSocket-Accept', $view);
        croak 'WebSocket handshake response has invalid Sec-WebSocket-Accept'
            unless $accept eq __PACKAGE__->accept_key($self->{key});
    }
    else {
        croak 'WebSocket Extended CONNECT response status must be 200'
            unless $status == 200;
        croak 'WebSocket HTTP/2 and HTTP/3 response must not contain Sec-WebSocket-Accept'
            if _header_values($response, 'Sec-WebSocket-Accept', $view);
    }

    croak 'WebSocket handshake response selected an unsupported extension'
        if _header_values($response, 'Sec-WebSocket-Extensions', $view);

    my @protocol =
        _header_values($response, 'Sec-WebSocket-Protocol', $view);
    croak 'WebSocket handshake response contains duplicate Sec-WebSocket-Protocol'
        if @protocol > 1;
    if (@protocol) {
        my @token = _tokens('Sec-WebSocket-Protocol', $protocol[0]);
        croak 'WebSocket handshake response must select one subprotocol'
            unless @token == 1;
        my %offered = map { $_ => 1 } @{ $self->{offered_subprotocols} };
        croak "WebSocket handshake response selected unknown subprotocol '$token[0]'"
            unless $offered{$token[0]};
        $self->{selected_subprotocol} = $token[0];
    }

    return $self;
}

sub subprotocol {
    my ($self) = @_;
    return $self->{selected_subprotocol};
}

sub http_version {
    my ($self) = @_;
    return $self->{http_version};
}

1;

__END__

=head1 NAME

Unblock::WebSocket::Handshake - WebSocket handshake helpers using Uniform::HTTP

=head1 DESCRIPTION

This module owns WebSocket-specific HTTP handshake semantics. It does not send
HTTP itself. C<client_request()> returns a Uniform::HTTP request that can be sent
by any suitable HTTP implementation.

HTTP/1.1 uses the RFC 6455 Upgrade handshake. HTTP/2 and HTTP/3 use Extended
CONNECT with C<:protocol = websocket> and a successful status of 200.

=cut
