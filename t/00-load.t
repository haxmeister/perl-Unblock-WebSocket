use strict;
use warnings;
use Test::More;

use_ok 'Unblock::WebSocket';
use_ok 'Unblock::WebSocket::Client';
use_ok 'Unblock::WebSocket::Server';
use_ok 'Unblock::WebSocket::_Frame';

is $Unblock::WebSocket::VERSION, '0.01', 'version is 0.01';

done_testing;
