# 공학용 계산기 — native iPhone/iPad app

New actual calculator, separate from the old synthetic CalculatorProbe. Own newly authored files are MIT licensed (LICENSE-calculator). Bundled KaTeX retains its own MIT license in KaTeX-vendor.zip/katex/LICENSE. No credentials or device identifiers belong in this repository.

## Independent offline calculator

5×8 Windows-style scientific keypad, immediate-execution decimal arithmetic, memory, degrees/radians, trigonometry, logarithms, powers, factorial, remainder, floor/ceiling. This is not a symbolic algebra engine. No login or network is needed for these functions.

## Personal gestures

- Double `=` within 330ms enters AI, never toggles out. Normal single equals is delayed 335ms to distinguish it.
- C cancels work and returns to calculator. Other scientific buttons do not compute in AI. Clipboard is never read in normal mode.
- AI only: double-tap display opens the keyboard; keyboard Send submits; display long-press 0.6s reads clipboard text/image and sends once. Draft stays hidden. Pending is 0, only a completed final answer is rendered. Horizontal swipe changes answer lines. No mode/settings icon or lock.
- Settings: ln → n! → mod → ln within 4s. Completion restores the earlier calculator state. This discoverable sequence is not access control.

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
