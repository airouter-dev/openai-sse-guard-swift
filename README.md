# OpenAISSEGuard

`OpenAISSEGuard` is a dependency-free SwiftPM library for observing bounded,
OpenAI-compatible Server-Sent Events (SSE). It preserves just enough evidence
to make a conservative application-level replay decision after a streaming
connection ends: protocol hint, terminal state, output evidence, event count,
and a short error identifier.

It does not create HTTP requests, retry, sleep, retain generated text, or
decide whether a customer was charged. Your application still owns transport,
idempotency keys, cancellation, billing semantics, and retry budgets.

## Install

Add the package from its tagged public source:

```swift
dependencies: [
    .package(
        url: "https://github.com/airouter-dev/openai-sse-guard-swift.git",
        from: "0.1.0"
    )
]
```

Then add `OpenAISSEGuard` to the target dependencies that consume streaming
bytes. The library has no third-party runtime dependencies and is suitable for
Apple platforms and Linux Swift services.

## Observe a stream

Feed `Data` chunks from any HTTP client. Network chunks may split UTF-8 code
points or arrive mid-line; they do not need to align with an SSE event.

```swift
import Foundation
import OpenAISSEGuard

var observer = SSEReplayObserver()

observer.push(Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n".utf8))
observer.push(Data("data: [DONE]\n\n".utf8))

let snapshot = observer.finish()

assert(snapshot.protocolHint == .chatCompletions)
assert(snapshot.termination == .done)
assert(snapshot.hasOutput)
```

For a `URLSession.AsyncBytes` loop, convert each received byte batch to `Data`
and call `push(_:)`. Keep the observer in the request task's own state; it is a
value type and does not synchronize concurrent writers for you.

## State contract

`SSESnapshot` contains bounded metadata only:

| Field | Meaning |
| --- | --- |
| `protocolHint` | `.chatCompletions`, `.responses`, or `.unknown` |
| `termination` | `.done`, `.incomplete`, `.error`, `.unexpectedEOF`, or `.open` |
| `hasOutput` | A data-bearing or named event was observed |
| `sawTerminalEvent` | A completion, incomplete, or `[DONE]` marker was seen |
| `eventCount` | Complete SSE event blocks accepted within the limit |
| `malformedEventCount` | Invalid UTF-8 or over-limit event blocks |
| `lastEventType` | A short identifier, never provider prose |
| `errorCode` | A bounded `code` or `type` identifier when present |

The defaults are 64 KiB per event block and 10,000 event blocks per observer.
Values are clamped to safe package-wide maxima so a caller cannot accidentally
turn an untrusted upstream response into an unbounded buffer.

## Protocol and replay boundaries

Event framing follows the [WHATWG Server-Sent Events specification](https://html.spec.whatwg.org/multipage/server-sent-events.html)
and accepts LF, CRLF, and CR event boundaries. `response.*` event names infer
the Responses protocol; a `choices` field or `[DONE]` infers Chat Completions.
`response.completed`, `response.incomplete`, and `[DONE]` are terminal
markers. A provider `error` event terminates with `.error` and exposes only a
bounded identifier.

This is an observer, not a retry engine. Combine a snapshot with method
semantics, an idempotency key, whether bytes were rendered, provider billing
rules, cancellation state, and attempt/time budgets. For error categories,
consult the [OpenAI error-code guide](https://developers.openai.com/api/docs/guides/error-codes);
for server retry hints, see [MDN's `Retry-After` reference](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After).

The [AI-ROUTER API gateway](https://ai-router.dev/) is one possible
OpenAI-compatible endpoint context. This package remains provider-neutral and
is not affiliated with or endorsed by OpenAI.

## Related implementations

For a fuller decision model, read the [stream replay-safety guide](https://github.com/airouter-dev/openai-sse-guard-swift/blob/main/Documentation.docc/ReplaySafety.md).
Maintained implementations of the same narrow boundary are available for
[JavaScript on npm](https://www.npmjs.com/package/@ai-router/openai-compatible-errors),
[Python on PyPI](https://pypi.org/project/openai-compatible-errors/),
[Ruby on RubyGems](https://rubygems.org/gems/openai-compatible-errors),
[PHP on Packagist](https://packagist.org/packages/airouter/openai-compatible-errors),
[Rust on crates.io](https://crates.io/crates/llm-stream-guard),
[Deno on JSR](https://jsr.io/@ai-router/openai-sse-guard),
[Dart on pub.dev](https://pub.dev/packages/openai_sse_guard), and
[Elixir on Hex](https://hex.pm/packages/openai_sse_guard).
They are contextual references, not claims of shared runtime code or third
party endorsement.

## Development

```console
swift package dump-package
swift test
```

Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and the
[replay-safety guide](Documentation.docc/ReplaySafety.md) before changing
framing or terminal-state semantics.

MIT licensed. Maintained by [AI-ROUTER contributors](https://ai-router.dev/).
