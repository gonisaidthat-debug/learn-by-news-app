# learn-by-news-app

웹 https://learn-by-news.goni-said-that.workers.dev 과 같은 Worker API·D1을 쓰는 SwiftUI 네이티브 iOS 앱. 웹 리포(learn-by-news)는 건드리지 않는다.

- 설계 단일 출처: `docs/design.md`. API 계약은 웹 리포 `docs/design.md` 14장이 원본이고 여기 2장은 사본.
- 서버를 바꿔야 하면 여기서 하지 말고 웹 리포 세션에 요청한다(goni가 결정을 전달).
- 비밀번호(APP_PASSWORD)는 Keychain에. 리포에 쓰지 않는다.
- 빌드 확인은 `xcodebuild` 결과만 믿는다. 기능이 바뀌면 시뮬레이터 스크린샷으로 확인하고 실기기(goni의 iPhone)에도 설치한다.
