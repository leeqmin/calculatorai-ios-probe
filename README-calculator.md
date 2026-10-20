# 공학용 계산기 — native iPhone/iPad app

New actual calculator, separate from the old synthetic CalculatorProbe. Own newly authored files are MIT licensed (LICENSE-calculator). Bundled KaTeX retains its own MIT license in KaTeX-vendor.zip/katex/LICENSE. No credentials or device identifiers belong in this repository.

### 1.0.4 connection recovery hardening

No calculator, rendering, gestures, OAuth endpoint/scope/client registration, bundle ID, Keychain service/key or billing changes. ConnectionRecovery.swift classifies bounded HTTP status/code/parameter/request ID and fixed response shape, never server descriptions or raw bodies. Sign-in renewal, model lookup and inference keep separate phases; the latest connection error and latest question failure survive a successful model refresh. Explicitly invalid refresh credentials are cleared while client registration/model choice are kept for user-initiated sign-in. Temporary failures, invalid-client errors and ambiguous authorization failures preserve credentials and do not start login loops or background retries.

Model loading coalesces concurrent callers. Existing valid model selections stay unchanged; new accounts and removed/rejected selections require an explicit choice. Definitive machine-readable model rejections refresh GET /models once but never resend inference or select a replacement automatically. Other errors do not trigger catalog reloads. No paid or alternate endpoint fallback is introduced. Empty/malformed catalogs produce a distinct connection diagnostic rather than masquerading as a successful model lookup.

ConnectionChecks.swift exists only in DEBUG: memory-only account storage and an isolated URLProtocol intercepting every URL exercise the actual token renewal, model lookup, answer parser, cancellation and account switching paths. Synthetic checks cover rotation, simultaneous model loads, preserved selections, terminal versus transient renewal errors, model removal, HTTP/SSE errors, malformed catalogs, and no inference retries. They do not establish future server compatibility or live-account success on the user's iPhone.

### 1.0.3 display and question input

User confirmed real answers on 1.0.2. This update leaves authentication, inference and credentials unchanged. All main-display states reuse the same offline renderer; bare numbers (including zero) use KaTeX just like delimited AI math. Normal calculation, typed decimals, scientific notation, fit-to-size and error text remain supported.

In AI mode, number/operator/function buttons edit the current question instead of calculating. Functions insert parentheses with the caret inside; selected text can be wrapped. The keyboard's caret/selection and committed Korean text are synchronized before keypad changes. CE clears the question, backspace deletes the selection or one whole grapheme, memory/angle controls remain inactive, and pending requests block edits. Only keyboard Send submits typed input; equals never sends. Double equals and C are unchanged. The hidden settings sequence restores both the earlier question/caret/answer and calculator state. Arbitrary typed text plus keypad math appear together in a 9pt one-line preview, head-truncated to show the tail. The sent question stays visible with the final answer; starting an edit resets the main display to zero. Clipboard is still read only on explicit idle AI long-press, never in diagnostics or tests.

### 1.0.2 response-format follow-up

The user-reported 1.0.1 diagnostic showed HTTP200, unknown/missing MIME and a non-JSON error classification. This does not prove inference succeeded or that no body arrived: the old diagnostic counter excluded the non-SSE error branch. Version1.0.2 distinguishes missing/known-other MIME, counts all received body bytes and reports only a fixed body-shape label (SSE/JSON/HTML/gzip/binary/other-text/empty). A successful HTTP response with valid SSE framing is parsed even when its MIME header is absent or mislabeled. Only the existing validated response.completed can produce an answer; HTML, error text, JSON-only output, non-2xx and partial streams cannot masquerade as success. Additional private URLProtocol fixtures cover these exact paths. No raw body, header values outside the finite MIME list, private messages or authentication secrets are logged.

Inference uses a per-request URLSessionDataDelegate exchange (bounded to1024 queued chunks/8MB) for explicit delivery/cancellation. CFNetwork may itself buffer a small missing-MIME body for MIME sniffing. The network open-stream fixture includes a valid SSE heartbeat to get past that OS buffer; a separate tiny headerless in-memory stream requires completion without producer EOF. Small headerless closed network responses are also covered. Cancellation closes only that exchange. Cookie/cache/redirect refusal and system TLS checks remain unchanged; sign-in/model requests keep their existing transport. No test failure or partial answer is silently treated as success.

### 1.0.1 response-reception update

Read SSE from raw bytes with preserved blank-line boundaries (LF/CRLF/CR), fragmented UTF-8, BOM and multiline data handling. Return only after a validated `response.completed`, immediately without waiting for socket EOF; incomplete streams never display partial text. Each inference has its own cancellable session. Settings retain the latest question stage, bounded HTTP/content-type/event counts, request ID and sanitized error code/parameter separately from model-loading status. Raw bodies/messages, questions, answers and credentials are never diagnostic records; diagnostics are in-memory only. The main display/gestures and Keychain service/bundle ID remain unchanged.

The core checks now exercise the production reader through a private ephemeral URLSession/URLProtocol fixture, including an open stream after completion, failures, malformed/truncated SSE, framing and non-SSE responses. No real account or external request is used. Real inference on the user's phone is still a required acceptance test; this revision does not claim to have fixed the live-account failure until that test passes.

## Independent offline calculator

5×8 Windows-style scientific keypad, immediate-execution decimal arithmetic, memory, degrees/radians, trigonometry, logarithms, powers, factorial, remainder, floor/ceiling. This is not a symbolic algebra engine. No login or network is needed for these functions.

## Personal gestures

- Double `=` within 330ms enters AI, never toggles out. Normal single equals is delayed 335ms to distinguish it.
- C cancels work and returns to calculator. Other scientific buttons do not compute in AI. Clipboard is never read in normal mode.
- AI only: double-tap display opens the keyboard; keyboard Send submits; display long-press 0.6s reads clipboard text/image and sends once. A small 9pt preview shows the typed question and keypad math. Pending is 0, only a completed final answer is rendered. Horizontal swipe changes answer lines. No mode/settings icon or lock.
- Settings: ln → n! → mod → ln within 4s. Completion restores the earlier calculator/question state. This discoverable sequence is not access control.

## AI and security boundary

Official SIWC open-source OAuth draft implementation: system Safari, fresh state/nonce/PKCE S256, issued oaiapp client ID, 127.0.0.1-only random-port listener, RS256/JWKS ID-token issuer/audience/nonce/subject/expiry verification, plan scope check, local Keychain ThisDeviceOnly storage, refresh serialization, account-specific official model catalogue, direct api.openai.com/v1/responses SSE with store:false. No cookies, private ChatGPT endpoints, proxy, transferred Windows tokens, API keys or paid fallback. Normal system TLS remains enabled; authenticated redirects are refused. No analytics or raw auth/request/response logging.

The system may end a background login wait. Return to the app and retry; no unauthorized background entitlement or custom callback bypass is added. Real account authorization, availability of the preview for this client/device, model support, image inference and full phone interaction **must be verified on the user's iPhone**. Synthetic tests or compilation do not establish that ChatGPT login works. ChatGPT plan limits still apply. Questions are independent, not conversational history; only the current input is sent.

## Build

On macOS/Xcode run `bash build-calculator.sh`. It runs offline synthetic tests, creates the temporary Xcode project and icon, builds an unsigned arm64 iOS package, builds/launches a simulator and captures a screenshot. No Apple signing credentials are used. The manual Actions workflow runs only on a public repository after explicit free storage review. No billing setup or private/paid runner is requested. Build outputs are short-lived (1 day).

`build/ScientificCalculator-unsigned.ipa` is **not directly installable**. Personal signing on the user's Windows computer (e.g. their already installed Sideloadly), device trust and Developer Mode remain separate user-controlled steps. Personal signing generally needs renewal after 7 days. The old probe uses a different bundle ID and is not overwritten automatically.

## Primary contracts

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

No actual user-account AI success is asserted by this source package.
