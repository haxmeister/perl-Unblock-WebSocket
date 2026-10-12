use strict;
use warnings;
use Test::More;

BEGIN {
    plan skip_all => 'set UNBLOCK_WS_H3_CERT and UNBLOCK_WS_H3_KEY to run real QUIC/TLS tests'
        unless $ENV{UNBLOCK_WS_H3_CERT} && $ENV{UNBLOCK_WS_H3_KEY};
    eval {
        require Net::QUIC::Driver;
        require Unblock::HTTP3::Client;
        require Unblock::HTTP3::Server;
        require Unblock::WebSocket::Handshake;
        1;
    } or plan skip_all => 'Net::QUIC and Unblock::HTTP3 are optional author dependencies';
}

use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw(time);
use Unblock::WebSocket::Client;
use Unblock::WebSocket::Server;

{
    package Local::H3WebSocketBody;
    sub new {
        my ($class, $transaction) = @_;
        bless { transaction => $transaction, queue => [],
            end_pending => 0, ended => 0, aborted => [] }, $class;
    }
    sub unblock_send {
        my ($self, $bytes) = @_;
        push @{ $self->{queue} }, $bytes;
        return;
    }
    sub unblock_finish { ++$_[0]{end_pending}; return }
    sub unblock_abort {
        my ($self, $reason) = @_;
        push @{ $self->{aborted} }, $reason;
        return;
    }
    sub flush {
        my ($self) = @_;
        while (@{ $self->{queue} }) {
            my $bytes = shift @{ $self->{queue} };
            $self->{transaction}->write($bytes);
        }
        if ($self->{end_pending} && !$self->{ended}) {
            $self->{transaction}->end;
            $self->{ended} = 1;
        }
        return;
    }
}

sub udp_socket {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'udp',
    ) or die "could not bind loopback UDP: $!";
    return $socket;
}

sub send_datagram {
    my ($socket, $datagram) = @_;
    my $wire = $datagram->data;
    my $sent = send($socket, $wire, 0, $datagram->peer);
    die "UDP send failed: $!" unless defined($sent) && $sent == length($wire);
    return 1;
}

my $server_socket = udp_socket();
my $client_socket = udp_socket();
my $server_local = getsockname($server_socket);
my $client_local = getsockname($client_socket);
my ($server_deadline, $client_deadline);

my $server_driver = Net::QUIC::Driver->server(
    alpn => 'h3',
    certificate_file => $ENV{UNBLOCK_WS_H3_CERT},
    private_key_file => $ENV{UNBLOCK_WS_H3_KEY},
    send => sub { send_datagram($server_socket, $_[0]) },
    set_timeout => sub {
        my ($after) = @_;
        $server_deadline = defined $after ? time() + $after : undef;
    },
);

my $client_driver = Net::QUIC::Driver->client(
    local => $client_local, peer => $server_local,
    alpn => 'h3', server_name => 'localhost',
    ca_file => $ENV{UNBLOCK_WS_H3_CERT},
    send => sub { send_datagram($client_socket, $_[0]) },
    set_timeout => sub {
        my ($after) = @_;
        $client_deadline = defined $after ? time() + $after : undef;
    },
);

my @bridges;
my $selector = IO::Select->new($server_socket, $client_socket);
sub service_once {
    $_->flush for @bridges;
    my $now = time();
    if (defined($server_deadline) && $server_deadline <= $now) {
        $server_deadline = undef;
        $server_driver->timeout;
    }
    $now = time();
    if (defined($client_deadline) && $client_deadline <= $now) {
        $client_deadline = undef;
        $client_driver->timeout;
    }
    my $wait = 0.02;
    for my $deadline ($server_deadline, $client_deadline) {
        next unless defined $deadline;
        my $remaining = $deadline - time();
        $remaining = 0 if $remaining < 0;
        $wait = $remaining if $remaining < $wait;
    }
    for my $socket ($selector->can_read($wait)) {
        my $bytes = '';
        my $peer = recv($socket, $bytes, 65535, 0);
        die "UDP receive failed: $!" unless defined $peer;
        my $local = getsockname($socket);
        die 'UDP getsockname failed' unless defined $local;
        if (fileno($socket) == fileno($server_socket)) {
            $server_driver->receive($bytes, $local, $peer);
        } else {
            $client_driver->receive($bytes, $local, $peer);
        }
    }
    $_->flush for @bridges;
    return;
}

sub run_until {
    my ($condition, $seconds) = @_;
    my $deadline = time() + ($seconds || 10);
    while (time() < $deadline) {
        return 1 if $condition->();
        service_once();
    }
    return $condition->() ? 1 : 0;
}

$server_driver->start;
$client_driver->start;
my $client_quic = $client_driver->connection;
my $server_quic;

ok(run_until(sub {
    $server_quic ||= $server_driver->next_connection;
    $server_quic && $server_quic->ready && $client_quic->ready;
}), 'QUIC connections reach ready state with TLS 1.3');

my ($ws_server, $ws_client, $client_bridge, $server_bridge);
my (@received_server, @received_client, @errors);
my $server_h3 = Unblock::HTTP3::Server->new(
    quic => $server_quic,
    enable_extended_connect => 1,
    on_request => sub {
        my ($tx, $req) = @_;
        if ($req->target eq '/ordinary') {
            $tx->respond(status => 200, body => 'ordinary-h3');
            return;
        }
        my $hs = Unblock::WebSocket::Handshake->server_accept($req);
        $tx->respond($hs->server_response, stream_body => 1);
        $server_bridge = Local::H3WebSocketBody->new($tx);
        push @bridges, $server_bridge;
        $ws_server = Unblock::WebSocket::Server->new(
            backend => 'perl', transport => $server_bridge,
            %{ $hs->connection_options },
            on_message => sub {
                my ($ws, $message, $type) = @_;
                push @received_server, [$message, $type];
                $ws->send_text("echo:$message");
            },
        );
    },
    on_body => sub {
        my ($tx, $req, $bytes) = @_;
        $ws_server->input($bytes) if $req->target eq '/chat';
    },
    on_error => sub { push @errors, "server: $_[1]" },
);

my $client_h3 = Unblock::HTTP3::Client->new(quic => $client_quic);
$client_h3->start;
$server_h3->start;

ok(run_until(sub { $client_h3->peer_settings_received }),
    'HTTP3 settings received');
ok $client_h3->peer_extended_connect_enabled,
    'peer advertises HTTP3 Extended CONNECT';

my ($client_handshake, $request) =
    Unblock::WebSocket::Handshake->client_request(
        'wss://localhost/chat', http_version => '3',
    );
my $tx = $client_h3->request(
    $request,
    stream_body => 1,
    on_response => sub {
        my ($tx, $response) = @_;
        $client_handshake->validate_client_response($response);
        $client_bridge = Local::H3WebSocketBody->new($tx);
        push @bridges, $client_bridge;
        $ws_client = Unblock::WebSocket::Client->new(
            backend => 'perl', transport => $client_bridge,
            %{ $client_handshake->connection_options },
            on_message => sub { push @received_client, $_[1] },
        );
    },
    on_body => sub {
        my ($tx, $response, $bytes) = @_;
        $ws_client->input($bytes);
    },
    on_error => sub { push @errors, "client: $_[1]" },
);

ok(run_until(sub { $ws_server && $ws_client }),
    'HTTP3 Extended CONNECT establishes a WebSocket on one QUIC stream');

$ws_client->send_text('h3-message');
ok(run_until(sub { @received_client }),
    'WebSocket messages echo across real HTTP3 and QUIC');
is_deeply \@received_server, [['h3-message', 'text']],
    'server receives WebSocket message on intended QUIC stream';
is_deeply \@received_client, ['echo:h3-message'],
    'client receives WebSocket reply exactly once';

my ($ordinary_done, $ordinary_body) = (0, '');
$client_h3->request(
    method => 'GET', target => '/ordinary',
    scheme => 'https', authority => 'localhost',
    on_body => sub { $ordinary_body .= $_[2] },
    on_complete => sub { ++$ordinary_done },
    on_error => sub { push @errors, "ordinary: $_[1]" },
);
ok(run_until(sub { $ordinary_done }),
    'ordinary H3 transaction succeeds while WebSocket stays active');
is $ordinary_body, 'ordinary-h3', 'ordinary transaction body isolated';
ok !$tx->is_terminal, 'WebSocket transaction still active';

$ws_client->close;
ok(run_until(sub { $ws_server->close_received && $ws_client->close_received }),
    'WebSocket Close handshake completes within one QUIC stream');
is scalar @{ $server_bridge->{aborted} }, 0, 'server stream not aborted';
is scalar @{ $client_bridge->{aborted} }, 0, 'client stream not aborted';
is_deeply \@errors, [], 'HTTP3/QUIC integration reported no errors';

done_testing;
