# Contributing

Please keep the package transport-neutral and bounded. Changes to parser
framing, terminal detection, or metadata retention require a focused XCTest
case for split chunks, CR/LF variants, and the intended replay-safety outcome.

Run `swift package dump-package` and `swift test` before submitting a change.
Do not add generated response text, provider error prose, credentials, or
network retry policy to the observer state.
