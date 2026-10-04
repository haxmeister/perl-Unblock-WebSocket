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
my $TOKEN_BODY = qr/[!#\$%&'*+\-.^_`|~0-9A-Za-z]+/;
my $TOKEN_RE = qr/\A$TOKEN_BODY\z/;

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

sub _split_extension_list {
    my ($where, $value, $delimiter) = @_;
    my @part;
    my $start = 0;
    my $quoted = 0;
    my $escaped = 0;

    for my $pos (0 .. length($value) - 1) {
        my $char = substr($value, $pos, 1);

        if ($escaped) {
            $escaped = 0;
            next;
        }
        if ($quoted && $char eq '\\') {
            $escaped = 1;
            next;
        }
        if ($char eq '"') {
            $quoted = !$quoted;
            next;
        }
        next unless !$quoted && $char eq $delimiter;

        push @part, substr($value, $start, $pos - $start);
        $start = $pos + 1;
    }

    croak "$where contains an unterminated quoted string"
        if $quoted || $escaped;
    push @part, substr($value, $start);
    return @part;
}

sub _quoted_extension_value {
    my ($where, $value) = @_;
    croak "$where contains an invalid quoted parameter"
        unless length($value) >= 2
            && substr($value, 0, 1) eq '"'
            && substr($value, -1, 1) eq '"';

    my $inside = substr($value, 1, length($value) - 2);
    my $out = '';
    my $escaped = 0;

    for my $char (split //, $inside) {
        if ($escaped) {
            my $ord = ord($char);
            croak "$where contains an invalid quoted escape"
                if $ord > 0x7f;
            $out .= $char;
            $escaped = 0;
            next;
        }

        if ($char eq '\\') {
            $escaped = 1;
            next;
        }

        my $ord = ord($char);
        croak "$where contains an invalid quoted parameter byte"
            if ($ord < 0x20 && $char ne "\t") || $ord == 0x7f;
        $out .= $char;
    }

    croak "$where contains an incomplete quoted escape" if $escaped;
    return $out;
}

sub _extension_elements {
    my ($message, $view) = @_;
    my @element;

    for my $header (
        _header_values($message, 'Sec-WebSocket-Extensions', $view)
    ) {
        for my $raw (
            _split_extension_list(
                'Sec-WebSocket-Extensions',
                $header,
                ',',
            )
        ) {
            $raw = _trim($raw);
            croak 'Sec-WebSocket-Extensions contains an empty extension'
                if $raw eq '';

            my @part = _split_extension_list(
                'Sec-WebSocket-Extensions',
                $raw,
                ';',
            );
            my $name = _trim(shift @part);
            croak "Sec-WebSocket-Extensions contains invalid extension '$name'"
                unless $name =~ $TOKEN_RE;

            my @parameter;
            for my $raw_parameter (@part) {
                $raw_parameter = _trim($raw_parameter);
                croak 'Sec-WebSocket-Extensions contains an empty parameter'
                    if $raw_parameter eq '';

                my ($parameter_name, $tail) =
                    $raw_parameter =~ /\A($TOKEN_BODY)(.*)\z/;
                croak "Sec-WebSocket-Extensions contains invalid parameter '$raw_parameter'"
                    unless defined $parameter_name;

                $tail = _trim($tail);
                my ($parameter_value, $quoted);
                if ($tail ne '') {
                    croak "Sec-WebSocket-Extensions parameter '$parameter_name' is malformed"
                        unless substr($tail, 0, 1) eq '=';
                    $tail = _trim(substr($tail, 1));
                    croak "Sec-WebSocket-Extensions parameter '$parameter_name' has no value"
                        if $tail eq '';

                    if (substr($tail, 0, 1) eq '"') {
                        $parameter_value = _quoted_extension_value(
                            "Sec-WebSocket-Extensions parameter '$parameter_name'",
                            $tail,
                        );
                        $quoted = 1;
                    }
                    else {
                        croak "Sec-WebSocket-Extensions parameter '$parameter_name' has invalid value"
                            unless $tail =~ $TOKEN_RE;
                        $parameter_value = $tail;
                        $quoted = 0;
                    }
                }

                push @parameter, {
                    name   => lc($parameter_name),
                    value  => $parameter_value,
                    quoted => $quoted ? 1 : 0,
                };
            }

            push @element, {
                name       => lc($name),
                parameters => \@parameter,
            };
        }
    }

    return @element;
}

sub _pmd_parameters {
    my ($where, $element, $response) = @_;
    my %parameter;

    for my $item (@{ $element->{parameters} }) {
        my $name = $item->{name};
        croak "$where contains duplicate permessage-deflate parameter '$name'"
            if exists $parameter{$name};

        croak "$where contains unknown permessage-deflate parameter '$name'"
            unless $name eq 'server_no_context_takeover'
                || $name eq 'client_no_context_takeover'
                || $name eq 'server_max_window_bits'
                || $name eq 'client_max_window_bits';

        if ($name eq 'server_no_context_takeover'
            || $name eq 'client_no_context_takeover') {
            croak "$where parameter '$name' must not have a value"
                if defined $item->{value};
            $parameter{$name} = 1;
            next;
        }

        if (!defined $item->{value}) {
            croak "$where parameter '$name' requires a value"
                if $response || $name eq 'server_max_window_bits';
            $parameter{$name} = undef;
            next;
        }

        croak "$where parameter '$name' must not use a quoted value"
            if $item->{quoted};
        my $bits = $item->{value};
        croak "$where parameter '$name' has invalid window bits"
            unless $bits =~ /\A(?:8|9|1[0-5])\z/;
        $parameter{$name} = 0 + $bits;
    }

    return \%parameter;
}

sub _checked_pmd_option {
    my ($where, $value, $side) = @_;
    return unless defined($value) && $value;

    return {} if !ref($value) && "$value" eq '1';
    croak "$where: permessage_deflate must be true or a hash reference"
        unless ref($value) eq 'HASH';

    my %option = %$value;
    my %out;

    for my $name (qw(
        client_no_context_takeover
        server_no_context_takeover
    )) {
        next unless exists $option{$name};
        my $flag = delete $option{$name};
        croak "$where: permessage_deflate $name must be zero or one"
            if ref($flag) || "$flag" !~ /\A[01]\z/;
        $out{$name} = $flag ? 1 : 0;
    }

    for my $name (qw(server_max_window_bits client_max_window_bits)) {
        next unless exists $option{$name};
        my $bits = delete $option{$name};
        croak "$where: permessage_deflate $name must be an integer "
            . 'from 8 through 15'
            unless defined($bits) && !ref($bits)
                && "$bits" =~ /\A[0-9]+\z/
                && $bits >= 8 && $bits <= 15;
        $out{$name} = 0 + $bits;
    }

    croak "$where: unknown permessage_deflate option(s): "
        . join(', ', sort keys %option)
        if %option;

    return \%out;
}

sub _format_pmd {
    my ($parameter) = @_;
    my @part = ('permessage-deflate');

    push @part, 'server_no_context_takeover'
        if $parameter->{server_no_context_takeover};
    push @part, 'client_no_context_takeover'
        if $parameter->{client_no_context_takeover};
    push @part, 'server_max_window_bits='
        . $parameter->{server_max_window_bits}
        if exists $parameter->{server_max_window_bits};
    push @part, 'client_max_window_bits='
        . $parameter->{client_max_window_bits}
        if exists $parameter->{client_max_window_bits};

    return join('; ', @part);
}

sub _server_pmd_negotiation {
    my ($request, $view, $policy) = @_;
    return unless $policy;

    for my $element (_extension_elements($request, $view)) {
        next unless $element->{name} eq 'permessage-deflate';

        my $offer = eval {
            _pmd_parameters(
                'WebSocket permessage-deflate offer',
                $element,
                0,
            );
        };
        next unless $offer;

        my %agreed;

        if ($offer->{server_no_context_takeover}
            || $policy->{server_no_context_takeover}) {
            $agreed{server_no_context_takeover} = 1;
        }

        if (exists $offer->{server_max_window_bits}) {
            my $offered = $offer->{server_max_window_bits};
            next unless defined $offered;

            my $bits = exists($policy->{server_max_window_bits})
                ? $policy->{server_max_window_bits}
                : $offered;
            $bits = $offered if $bits > $offered;
            $agreed{server_max_window_bits} = $bits;
        }
        elsif (exists $policy->{server_max_window_bits}) {
            $agreed{server_max_window_bits} =
                $policy->{server_max_window_bits};
        }

        if ($policy->{client_no_context_takeover}) {
            $agreed{client_no_context_takeover} = 1;
        }

        if (exists($policy->{client_max_window_bits})
            && exists($offer->{client_max_window_bits})) {
            my $bits = $policy->{client_max_window_bits};
            if (defined($offer->{client_max_window_bits})
                && $bits > $offer->{client_max_window_bits}) {
                $bits = $offer->{client_max_window_bits};
            }
            $agreed{client_max_window_bits} = $bits;
        }

        return \%agreed;
    }

    return;
}

sub _client_pmd_response {
    my ($response, $view, $offer) = @_;
    my @extension = _extension_elements($response, $view);

    if (!$offer) {
        croak 'WebSocket handshake response selected an unsupported extension'
            if @extension;
        return;
    }

    return unless @extension;

    croak 'WebSocket handshake response selected multiple extensions'
        if @extension != 1;
    croak 'WebSocket handshake response selected an unsupported extension'
        unless $extension[0]{name} eq 'permessage-deflate';

    my $agreed = _pmd_parameters(
        'WebSocket permessage-deflate response',
        $extension[0],
        1,
    );

    croak 'WebSocket permessage-deflate response omitted required '
        . 'server_no_context_takeover'
        if $offer->{server_no_context_takeover}
            && !$agreed->{server_no_context_takeover};

    if (exists $offer->{server_max_window_bits}) {
        croak 'WebSocket permessage-deflate response omitted required '
            . 'server_max_window_bits'
            unless exists $agreed->{server_max_window_bits};
        croak 'WebSocket permessage-deflate response increased '
            . 'server_max_window_bits'
            if $agreed->{server_max_window_bits}
                > $offer->{server_max_window_bits};
    }

    if (exists $agreed->{client_max_window_bits}) {
        croak 'WebSocket permessage-deflate response included '
            . 'client_max_window_bits that was not offered'
            unless exists $offer->{client_max_window_bits};
        croak 'WebSocket permessage-deflate response increased '
            . 'client_max_window_bits'
            if defined($offer->{client_max_window_bits})
                && $agreed->{client_max_window_bits}
                    > $offer->{client_max_window_bits};
    }
    elsif (exists $offer->{client_max_window_bits}
        && defined $offer->{client_max_window_bits}) {
        # The offer value is a hint. If the server does not constrain the
        # client, keeping the locally preferred smaller window is still valid.
        $agreed->{client_max_window_bits} =
            $offer->{client_max_window_bits};
    }

    # A client may always choose not to take context over even if the server
    # ignores the corresponding offer hint.
    $agreed->{client_no_context_takeover} = 1
        if $offer->{client_no_context_takeover};

    return $agreed;
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
    my $pmd_offer = _checked_pmd_option(
        'client_request()',
        delete($option{permessage_deflate}),
        'client',
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
        push @ws_headers,
            [ 'Sec-WebSocket-Extensions' => _format_pmd($pmd_offer) ]
            if $pmd_offer;
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
        push @ws_headers,
            [ 'Sec-WebSocket-Extensions' => _format_pmd($pmd_offer) ]
            if $pmd_offer;
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
        permessage_deflate_offer => $pmd_offer,
        permessage_deflate       => undef,
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
    my $pmd_policy = _checked_pmd_option(
        'server_accept()',
        delete($option{permessage_deflate}),
        'server',
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

    my $pmd = _server_pmd_negotiation(
        $request,
        $view,
        $pmd_policy,
    );

    return bless {
        side                 => 'server',
        http_version         => "$version",
        key                  => $key,
        offered_subprotocols => \@offered,
        selected_subprotocol => $selected,
        permessage_deflate   => $pmd,
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
    push @headers,
        [ 'Sec-WebSocket-Extensions' =>
            _format_pmd($self->{permessage_deflate}) ]
        if $self->{permessage_deflate};

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

    $self->{permessage_deflate} = _client_pmd_response(
        $response,
        $view,
        $self->{permessage_deflate_offer},
    );

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

sub permessage_deflate {
    my ($self) = @_;
    return unless $self->{permessage_deflate};
    return { %{ $self->{permessage_deflate} } };
}

sub connection_options {
    my ($self) = @_;
    my %option;
    $option{permessage_deflate} =
        { %{ $self->{permessage_deflate} } }
        if $self->{permessage_deflate};
    return \%option;
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
