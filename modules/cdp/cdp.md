# cdp

## NAME

cdp - Chrome DevTools Protocol client over plain RFC6455 websockets

## SYNOPSIS

```tcl
package require cdp

set cdp [cdp::connect ws://127.0.0.1:9333/devtools/page/XXXX]
$cdp navigate https://example.org
puts [$cdp evaluate {document.title}]
set resp [$cdp cdp Network.enable]
$cdp close
```

## DESCRIPTION

A Tcl client for driving a Chromium-family browser over the Chrome DevTools Protocol: flat JSON commands over a websocket, id-matched responses, interleaved events. It speaks minimal RFC6455 itself (masked text frames out, unmasked in) over a raw loopback socket, so it depends only on tcllib's json and base64; there is no http or TLS layer, and `wss://` is refused by design since DevTools endpoints are plain `ws://` on loopback.

The transport URL is any DevTools websocket endpoint: a page target read off `http://127.0.0.1:PORT/json` after launching the browser with `--remote-debugging-port=PORT`, or a loopback proxy that forwards CDP frames preserving the client's integer ids. `cdp::connect` with no argument reads the URL from the `CDP_WS_URL` environment variable, which suits scripts run under a harness that owns the browser.

## COMMANDS

  - `cdp::connect ?url?` - returns a connected `cdp::Client` instance; with no url, reads `CDP_WS_URL`.
  - `cdp::pumpMode on` - selects the frame-read mode for subsequently created clients. Mode 0 (default) reads blocking, for a standalone script. Mode 1 reads through nested `vwait`s so a host application's event loop keeps serving its other sockets, timers, and UI while a caller waits on a CDP round-trip; it works for callers inside a Safe Base interp, where a coroutine yield cannot cross the interp boundary.

## CLIENT METHODS

  - `$cdp cdp method ?paramsDict?` - send one CDP command, return the id-matched response dict; interleaved events are skipped.
  - `$cdp navigate url` - `Page.enable` then `Page.navigate`.
  - `$cdp evaluate jsExpr` - `Runtime.evaluate` with `returnByValue` and `awaitPromise`; returns the JS value, raises on a JS exception.
  - `$cdp cdpBuffered method ?paramsDict?` - like `cdp`, but events seen while awaiting the response are parked in the event buffer.
  - `$cdp drainEvents seconds` - park every event the browser sends for the given time; use with `Network.enable` to observe the page's own network traffic.
  - `$cdp events` / `$cdp clearEvents` - read / empty the parked events (each a dict).
  - `$cdp logCallback cmdprefix` - route every frame, both directions, through a wire-log sink; empty string clears it.
  - `$cdp close` - send a close frame and tear the socket down, waking any parked reader.

## EXAMPLE: READING A PAGE'S OWN API TRAFFIC

```tcl
package require cdp
set cdp [cdp::connect]
$cdp cdp Network.enable
$cdp navigate https://example.org/dashboard
$cdp drainEvents 5
foreach ev [$cdp events] {
    if {[dict get $ev method] eq "Network.responseReceived"} {
        puts [dict get $ev params response url]
    }
}
$cdp close
```

## REQUIREMENTS

Tcl 9, tcllib (json, json::write, base64). The browser end is anything speaking CDP: Chromium, Chrome, Edge, or headless variants.
