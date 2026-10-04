package Unblock::WebSocket::_UTF8;

use strict;
use warnings;
use Carp qw(croak);
use Encode ();

sub decode {
    my ($class, $bytes) = @_;
    croak 'decode(): bytes must be a defined scalar'
        if !defined($bytes) || ref($bytes);
    return Encode::decode('UTF-8', $bytes, Encode::FB_CROAK());
}

sub encode {
    my ($class, $text) = @_;
    croak 'encode(): text must be a defined scalar'
        if !defined($text) || ref($text);
    return Encode::encode('UTF-8', $text, Encode::FB_CROAK());
}

sub valid_bytes {
    my ($class, $bytes) = @_;
    return 0 if !defined($bytes) || ref($bytes);
    return eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()); 1 } ? 1 : 0;
}

1;
