# Stream replay-safety guide

An HTTP status code alone does not prove that a streamed operation completed.
A connection can close after output was rendered, after a provider emitted an
error event, or before a terminal marker. Blindly replaying may duplicate
visible output or charge a billable operation twice.

`SSEReplayObserver` records bounded evidence without persisting the response
body:

| Evidence | Snapshot effect | Application question |
| --- | --- | --- |
| `[DONE]` | `termination: .done` | Can the caller mark the stream complete? |
| `response.completed` | `termination: .done` | Was a Responses terminal event observed? |
| `response.incomplete` | `termination: .incomplete` | Does the provider require a follow-up? |
| `error` event | `termination: .error` | Should the caller surface a provider error? |
| Named/data event then EOF | `hasOutput: true`, `.unexpectedEOF` | Is replay unsafe without idempotency? |
| No event then EOF | `.unexpectedEOF` | Is there enough evidence to retry? |
| Frame or event bound exceeded | `.error` | Should the transport be treated as untrusted? |

The package deliberately does not answer the final retry question. Combine the
snapshot with method semantics, a stable idempotency key, visible-output state,
provider billing rules, cancellation state, and remaining time/attempt budget.
A conservative false positive prevents replay; a false negative can duplicate
output or billing.

For the wire contract, use the [WHATWG SSE specification](https://html.spec.whatwg.org/multipage/server-sent-events.html).
For provider errors, see the [OpenAI error-code guide](https://developers.openai.com/api/docs/guides/error-codes).
For retry hints, see [MDN Retry-After](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After).

## Example decision boundary

```swift
let snapshot = observer.finish()

switch snapshot.termination {
case .done:
    markCompleted()
case .unexpectedEOF where snapshot.hasOutput:
    requireApplicationLevelIdempotencyReview()
case .unexpectedEOF:
    retryOnlyIfTheOperationIsIdempotent()
case .incomplete, .error:
    surfaceProviderStateWithoutBlindReplay()
case .open:
    continueReading()
}
```

The names in this example describe caller policy; they are not functions
provided by the package. Keeping policy outside the parser lets one Swift
package work for a server, a mobile app, or a command-line client without
smuggling billing assumptions into a framing utility.
