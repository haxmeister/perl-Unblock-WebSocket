# Performance plan

Unblock::WebSocket is portable, but portability is not permission to add an
unavoidable Perl copy at every transport boundary.

## Baseline

Linux::Event::WebSocket already has a native bq_websocket implementation with
real application-path measurements. Those results are the extraction baseline,
not disposable historical data.

The comparison suite for Unblock should retain equivalent cases for:

- small text messages (64 and 256 bytes);
- 1 KiB messages;
- 16 KiB messages;
- binary traffic;
- mixed Unicode text;
- 20, 100, 500, and 1000 connections where applicable;
- broadcast fan-out;
- request windows of 1, 4, and 16.

## Three integration levels

### Portable Perl path

    transport bytes -> input() -> protocol engine
    output() -> transport write

This is the stable public contract and the correctness baseline.

### Efficient framework adapter

Framework adapters can minimize copying and drain output in useful chunks while
still using the public Perl API.

### Native adapter

XS-capable transports can drive the same native engine through the private
versioned adapter ABI:

    borrowed native input buffer
        -> native WebSocket parser
        -> completed message callback

Raw input does not need to become a temporary Perl scalar.

Native output similarly should be available as a borrowed buffer or through a
host output submission callback so an adapter can avoid:

    native frame buffer -> Perl SV -> native transport buffer

## Required measurements

Development should record at least four checkpoints:

1. current Linux::Event::WebSocket native baseline;
2. standalone Unblock portable engine;
3. Linux::Event adapter using the portable byte API;
4. Linux::Event adapter using the private native ABI.

The difference between checkpoints 3 and 4 measures recoverable adapter cost.
The difference between checkpoints 1 and 4 measures whether extraction changed
the optimized architecture.

## Optimization rule

Do not optimize by leaking Linux::Event objects into Unblock::WebSocket.
Optimize the generic native boundary instead. If another XS transport can use
the same facility, it belongs in Unblock. If it requires Linux::Event Stream
state, it belongs in the Linux::Event adapter.
