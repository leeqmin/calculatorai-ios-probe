# 아이폰 네이티브 계산기 — 1단계 연결 시험

상태 (2026-10-19): **GitHub 표준 Mac runner에서 핵심 검사 및 iOS 장치용 미서명 앱 빌드 성공.** [실행 결과](https://github.com/leeqmin/calculatorai-ios-probe/actions/runs/39211454008), 빌드 커밋 `3cae7bb11d38f1c2353ca1f51d048d6e84dd2ab3`, 작업 47초. Windows 자체에서 컴파일한 것이 아닙니다. **아이폰 설치·실행·실제 OAuth/AI 요청은 여전히 미검증**입니다. 완성된 AI 계산기가 아닙니다.

## 왜 이 시험부터 하는가

공식 Sign in with ChatGPT의 OSS 흐름은 `http://127.0.0.1:<port>/auth/callback` 수신기를 먼저 열도록 요구합니다. iOS 로그인 중 기기 내부 수신 및 앱 수명 주기를 검증해야 합니다. 지원되는 로그인 화면/콜백 방식이 실제로 가능한지는 별도 확인이 필요합니다.

이 프로젝트는 외부 서비스 없이 **모의 승인 → 일회성 state 확인 → 앱 화면 갱신**만 시험합니다. 앱 내부 SFSafariViewController와 외부 Safari 두 모드를 제공합니다. 전자는 앱 내 복귀를, 후자는 앱이 백그라운드로 이동했을 때 수신 지속 여부를 관찰합니다. 외부 Safari에서 앱으로 자동 전환하는 기능은 없습니다. 실행 시 네트워크/서명 문제를 포함해 실패할 수 있습니다.

## 포함하지 않는 것

- 실제 OpenAI 로그인, OAuth 토큰 발급/저장, 모델 조회, AI 호출
- 계산기 UI·사진 해석·수식 렌더링 (연결 검증 후 기존 기능 이식 예정)
- 계정 비밀번호/API 키/기존 Windows 자격 증명
- 외부 서버/분석/원격 로깅/숨은 API/상시 백그라운드 서비스

수신기는 127.0.0.1에만 바인딩하며 120초 만료, 중복 state/잘못된 Host/재사용 콜백 거부, 8KB 요청 상한, 연결 8개 상한, 연결별 5초 제한을 사용합니다. 실제 OAuth 보안 검증을 대체하지 않습니다.

## Mac에서 검증

Xcode를 설치하고 이 폴더에서 `bash build-macos.sh`를 실행합니다. Foundation 기반 핵심 검증 10개를 실행한 뒤 iOS 장치용 앱을 빌드합니다. 결과는 `build/CalculatorProbe-unsigned.ipa`이며, **서명되지 않아 직접 설치되지 않습니다.**

직접 Mac 설치: CalculatorProbe.xcodeproj를 열고 Signing & Capabilities에서 자신의 Personal Team/고유 Bundle ID를 선택한 뒤 iPhone을 연결해 실행합니다. 계정 로그인, 기기 신뢰 및 Developer Mode는 사용자가 직접 승인해야 합니다.

Windows만 있는 경우: 사용자가 별도로 승인한 GitHub 저장소에 **이 폴더만** 올려 Mac Actions runner로 빌드할 수 있습니다. 이 템플릿은 공개 저장소에서만, 수동 실행 시 공개/무료 저장 공간 확인을 체크해야 실행됩니다. 공개 표준 runner의 빌드 시간은 무료이지만 아티팩트 저장 공간은 계정의 공유 한도 확인이 필요합니다. 결제 수단 추가/유료 전환/초과 사용을 허용하지 않습니다. 사용자 승인 후 시험용 소스 11개만 공개 저장소에 업로드하고 수동 실행 1회를 완료했습니다. 결제·Apple 계정·실제 OpenAI 자격 증명을 사용하지 않았습니다.

생성된 아티팩트는 65.6 KB이며 보관 기간은 1일입니다. 현재 자동 브라우저에서 다운로드 요청이 시간 초과/클라이언트 차단되어 로컬 파일 확보 및 내부 구조·해시 독립 검사는 하지 못했습니다. [실행 결과 페이지](https://github.com/leeqmin/calculatorai-ios-probe/actions/runs/39211454008)의 Artifacts에서 사용자 본인이 내려받아야 합니다. 표시된 SHA-256은 GitHub 아티팩트 값이며 개별 IPA 파일 해시를 직접 계산한 것이 아닙니다.

IPA 설치는 별도 단계입니다. AltStore Classic/AltServer의 Windows 경로가 후보이며 Apple 계정·기기 신뢰·설치 도구 승인이 필요합니다. 무료 개인 서명은 보통 7일 후 만료되어 갱신이 필요합니다. iPhone 12 mini / 사용자 보고 iOS 26.6.1에서의 호환성과 재서명 설치는 아직 검증하지 않았습니다. Apple 자격 증명을 GitHub에 넣지 않습니다.

## 실기기 통과 기준

1. 앱 내부 시험을 시작하고 모의 승인 페이지가 보인다.
2. 즉시 승인 및 60초 대기 후 승인 모두 앱에 `모의 수신 성공`이 표시된다.
3. 브라우저 닫기/취소/120초 만료 후 수신기가 정리된다.
4. 외부 Safari 시험은 백그라운드 수신의 성공/실패를 따로 기록한다.
5. 실제 인증은 이 시험과 별도: 지원되는 시스템 인증 세션, PKCE/state/nonce, 발급 client_id, ID 토큰 서명/issuer/audience/만료 검증, 계획 사용 권한, Keychain 저장/갱신/로그아웃 구현 및 사용자 동의가 필요하다.
6. 실제 계정 승인과 AI 요청이 성공하기 전에는 전체 경로가 된다고 표시하지 않는다.

## 근거

- [OpenAI 등록/로그인 계약](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [OpenAI 미리보기 제한](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple Personal Team / 7일 만료](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [GitHub Actions 과금/무료 한도](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [AltStore Windows 설치](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
- [AltStore 갱신](https://faq.altstore.io/altstore-classic/your-altstore)
