package Unblock::WebSocket::_Random;

use strict;
use warnings;
use Carp qw(croak);

sub bytes {
    my ($class, $length) = @_;
    croak 'bytes(): length must be a positive integer'
        unless defined($length) && !ref($length)
            && $length =~ /\A[0-9]+\z/ && $length > 0;

    require Crypt::URandom;
    return Crypt::URandom::urandom($length);
}

sub mask_key {
    my ($class) = @_;
    return $class->bytes(4);
}

1;
