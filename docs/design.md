# learn-by-news-app 설계 문서

> 단일 출처는 두 개다. 앱 UI·구조는 이 문서, **서버 API 계약은 웹 리포의 `docs/design.md` 14장**(https://github.com/gonisaidthat-debug/learn-by-news/blob/main/docs/design.md). 아래는 그 14장의 사본(2026-11-06)이며 서버가 바뀌면 웹 리포 쪽이 먼저 바뀌고 여기로 복사한다.

## 0. 한 줄 요약

웹(https://learn-by-news.goni-said-that.workers.dev)과 같은 Worker API·D1을 쓰는 SwiftUI 네이티브 iOS 앱. 웹은 그대로 두고, 앱은 폰에서 번역 연습을 하기 위한 두 번째 클라이언트.

## 1. 결정된 것과 남은 것

**goni 결정 (2026-11-06):**
- 화면 범위: **전부**. 공책 목록(붙여넣기 포함), 공책(번역·채점·다시 쓰기·건너뛰기·제거·합치기), 마지막 장(점수·총평), 표현장(포스트잇 벽), 시험지, 기록, 공부 세션.
- 공책 UI: **웹과 같은 은유**. 줄노트 위 인쇄체 원문 + 손글씨 번역, 왼쪽 여백 등급 도장, 빨간 물결 밑줄, 연필 참고 번역, 포스트잇, "✂ 여기까지" 점선. 글꼴은 Nanum Pen Script(OFL)를 앱에 번들.

**goni 추가 결정 (2026-11-06): 나머지도 전부 웹과 동일하게.** 비밀번호는 한 번 입력해 Keychain에 두고(웹의 localStorage 역할), 세션 시작점은 UserDefaults(웹의 localStorage 역할), 붙여넣기는 텍스트 붙여넣기 칸 + 링크 칸(웹과 같은 자동 URL 감지). 공유 시트는 나중.

**goni 추가 결정 (2026-11-06): 버그 추적용 로그 기능 포함.** 앱은 OSLog와 로컬 순환 파일(최근 2000줄)에 기록한다. 설정 화면의 "로그 보내기"와, 다음 실행 시 자동(직전 실행에 error/fatal이 있었거나 비정상 종료였으면)으로 서버 `POST /api/logs`에 올린다. 항목: level(debug/info/warn/error/fatal), tag(화면/모듈), message, context(JSON), at. 기사 원문·번역 전문은 넣지 않는다(문장 id만). 서버는 30일 보관하고 웹 세션에서 `GET /api/logs`로 본다. 설정 화면에 로컬 로그 보기·지우기도 둔다.

**앱 세션에서 goni와 정할 것 (남은 것 없음, 구현하며 생기면 여기에):**
- 세션 시작점(UserDefaults)과 비밀번호 보관(Keychain).
- 기사 붙여넣기 경로: 클립보드 붙여넣기 + 공유 시트(URL만 올 수 있음).

## 2. API 계약 (웹 리포 14장 사본, 2026-11-06)

결정: **웹은 그대로 두고, iOS 앱을 SwiftUI 네이티브로 따로 만든다. DB는 공유한다.** 공유 방법은 앱이 웹과 같은 Worker API를 호출하는 것. 별도 리포 `learn-by-news-app`, 별도 세션. 이 절이 그 세션의 단일 출처다. 서버가 바뀌면 이 절도 같이 고친다.

### 기본
- Base URL: `https://learn-by-news.goni-said-that.workers.dev`
- 모든 요청: `Authorization: Bearer <percent-encoded UTF-8 APP_PASSWORD>` (헤더는 ASCII만 실리므로 한글 비밀번호는 반드시 인코딩. Swift: `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`). 서버는 디코드해 비교하며 인코딩 안 된 ASCII 값도 받는다. 비밀번호 입력란은 한글 키보드를 막지 않는다. JSON 본문은 `Content-Type: application/json`. 틀리면 `401 {"error":"unauthorized"}`.
- 오류는 항상 `{"error": "<한국어 메시지>"}`. 429는 하루 Claude 호출 상한. 413은 본문 512KB 초과.
- 시각은 전부 Unix ms. 등급은 `"A"|"B"|"C"|"D"|"skip"`. 점수는 등급 평균(A100 B80 C50 D20, skip 제외, 반올림)이며 **클라이언트가 계산**한다.
- 앱 아이콘 초안: `docs/assets/app-icon-1024.png` (공책+도장, 자체 제작).

### 타입
```
Feedback   { grade, issues: [{source, mine, meaning, why}], reference, expressions: [{phrase, meaning}] }
Attempt    { translation, grade, feedback: Feedback, created_at }
Sentence   { id, idx, paragraph, text, attempt: Attempt|null, history: Attempt[] }   // history = 이전 시도, 오래된 순
Phrase     { id, phrase, meaning, sentence_id, article_id, created_at, sentence_text?, article_title? }
Review     { id, score: int|null, created_at, summary, patterns: [{title, detail}], praise }
Session    { id, started_at, ended_at, attempts, score: int|null, articles: string[], created_at }
QuizItem   { key, kind: "issue"|"phrase", sentence_id, article_id, article_title, sentence_idx, sentence_text,
             source, mine, meaning, why, issued_at, last_correct: bool|null, last_at, tries, wrong }
```

### 엔드포인트
| 메서드·경로 | 요청 | 응답 |
|---|---|---|
| GET `/api/auth` | — | `{ok:true}` (비밀번호 확인용) |
| GET `/api/articles` | — | `[{id, title, source, created_at, sentence_count, done_count, review_count, grades:{A?,B?,C?,D?,skip?}}]` 최신순. `review_count` = 총평 개수 = 완주 회차 |
| POST `/api/articles` | `{title, source?, sentences:[{paragraph, text}]}` 문장 분리는 클라이언트 | `{id}` |
| GET `/api/articles/:id` | — | `{id, title, source, created_at, sentences: Sentence[], phrases: Phrase[], reviews: Review[]}` reviews 최신순 |
| PATCH `/api/articles/:id` | `{source?} \| {title?}` | `{ok}` |
| DELETE `/api/articles/:id` | — | `{ok}` 기록·표현·총평까지 삭제 |
| POST `/api/articles/:id/review` | `{score: int\|null}` (클라 계산값 보관용) | `Review` — Claude 호출, 수 초 걸림 |
| POST `/api/sentences/:id/attempts` | `{translation}` 또는 `{skip:true}`, 선택 `attempt_id`(클라이언트 UUID, 멈추기용) | `Feedback & {translation, created_at}` `& {phrases: Phrase[]}` — **첨삭 표현은 서버가 기본으로 표현장에 저장**하고(같은 문장·같은 표현은 한 번만) 새로 저장된 것을 `phrases`로 돌려준다. 클라이언트는 이를 공책의 phrases에 합쳐 포스트잇을 "붙은" 상태로 그린다. 떼는 건 `DELETE /api/phrases/:id`(goni 결정 2026-11-10) — translation이면 Claude 호출(약 5~10초), skip은 즉시 |
| DELETE `/api/attempts/:id` | — | `{ok, removed}` **멈추기**: 채점이 끝났으면 그 시도 삭제, 아직이면 묘비를 남겨 결과 도착 시 버림(그 요청은 409 `{cancelled:true}`) |
| POST `/api/sentences/:id/merge` | `{dir:"prev"\|"next"}` | `{ok, kept, text}` 붙는 쪽 문장과 기록 삭제 |
| DELETE `/api/sentences/:id` | — | `{ok}` |
| GET `/api/phrases?q=` | — | `Phrase[]` 최신순, q는 phrase/meaning LIKE |
| POST `/api/phrases` | `{phrase, meaning, sentence_id, article_id}` | `Phrase` |
| DELETE `/api/phrases/:id` | — | `{ok}` |
| GET `/api/quiz` | — | `QuizItem[]` (순서는 클라가: 안 본 것→틀린 것→맞힌 것, 묶음 안 섞기) |
| POST `/api/quiz/results` | `{key, sentence_id, source, correct: bool}` | `{ok}` |
| GET `/api/sessions` | — | `Session[]` 최신순 |
| POST `/api/sessions` | `{started_at}` | `Session` — started_at 이후 채점이 없으면 400 |
| DELETE `/api/sessions/:id` | — | `{ok}` |
| GET `/api/log?days=60` | — | `{since, attempts:[{id, sentence_id, article_id, translation, grade, created_at, idx, text, title}], sessions, reviews:[{id, article_id, title, score, created_at, summary}], quiz:[{id, key, source, correct, created_at, kind}]}` |
| POST `/api/logs` | `{device, app_version, entries:[{level, tag, message, context?, at}]}` 최대 500개 | `{ok, saved}` |
| GET `/api/logs?days=7&level=&limit=500` | — | 로그 목록 최신순 |
| DELETE `/api/logs?before=<ms>` | — | `{ok, deleted}` |

### 클라이언트가 지켜야 할 규칙 (웹과 동일 동작)
- **문장 분리**는 클라이언트 몫. 첫 줄 제목, URL만 있는 줄은 source, 빈 줄 사이가 문단. 약어(월 약어, Mr./Dr./Jr., No., vs., U.S. 등) 뒤는 끊지 않고, 소문자·구두점으로 시작하는 조각은 앞에 붙인다. iOS는 `NLTokenizer(unit: .sentence)` + 같은 보정.
- **제출 즉시 다음 문장**으로 넘어가고 채점은 뒤에서 받는다(여러 개 동시 가능). 결과가 오면 그 문장을 펼쳐 보여준다.
- **멈추기**: 채점 중인 문장에 "멈추기 ↩". 누르면 요청을 취소(URLSessionTask.cancel)하고 `DELETE /api/attempts/:attempt_id`를 보낸 뒤, 그 문장이 다시 입력란이 되고 쓰던 번역이 그대로 들어간다(다시 쓰기 중이었으면 그 자리에서). 제출할 때 attempt_id를 UUID로 만들어 보내야 멈추기가 된다.
- **열람 모드**: 완료 여부·다시 쓰기 진행과 무관하게 전체 문장과 최신 번역·첨삭·이전 시도를 보여주는 화면. 다시 쓰기 중 "이전 회차 열람"(별도 화면으로 push, 진행 상태는 유지), 마지막 장 "공책 전체 열람", 기록·시험지의 문장 링크가 여기로 온다.
- **처음부터 다시 쓰기**(마지막 장 버튼): 첫 문장부터 순서대로 다시 쓰기 모드로 돈다(진행 표시 "다시 n / m"). **화면은 처음 하는 것처럼 비운다**: 이번에 새로 제출한 문장만 위에 쌓이고, 아직 안 쓴 문장(이전 번역·도장)은 보이지 않는다. 이전 번역은 데이터로 남아 펼치면 "이전 시도"로만 보인다(goni 결정 2026-11-10). **진행 상태는 기기에 저장**(UserDefaults, 공책별 ids·done)해 앱을 껐다 켜거나 다른 화면에 다녀와도 그 자리에서 이어진다. 마지막 장은 진행 중이면 "처음부터 다시 쓰기 이어서 (n / m) →"를 보여주고 총평을 자동 요청하지 않는다. 저장이 없을 때는 "최근 24시간 안에 다시 쓴 앞쪽 문장 수"로 추정해 "오늘 다시 쓴 n문장 다음부터 이어서 →"를 보여준다. 중단·완료 시 저장을 지운다. 각 제출은 새 attempt(이전 것은 history). 중간에 취소 가능. 마지막 문장을 제출하면 공책에 머물며 채점이 전부 끝나길 기다렸다가 마지막 장으로 가서 새 총평을 자동 요청한다(`POST /api/articles/:id/review`, 기존 총평은 그대로 남음). 채점 오류로 "다시 시도" 상태인 문장이 있으면 이동하지 않는다. 서버 변경 없음.
- **세션 시작점은 클라이언트가 보관**(웹은 localStorage). 앱은 UserDefaults. 시작 전에는 입력 불가. "오늘 여기까지"는 `POST /api/sessions {started_at}`. 기기 간 시작점은 공유되지 않는다(필요해지면 서버로 옮긴다).
- 참고 번역 기본 펼침. 등급 도장·빨간 밑줄(issue.mine을 번역에서 찾아 표시)·포스트잇 저장 토글은 웹과 같은 의미.
- 폴백 금지: 채점 실패 시 같은 요청 재시도만.

## 3. 앱 구조 (구현 메모, 2026-11-06)

- `project.yml` → `xcodegen generate`. 타깃 LearnByNews, 번들 `com.goni.learn-by-news`, iOS 17+, 세로 고정.
- `LearnByNews/Core`: `Models`(API 타입, 점수 계산), `API`(URLSession, Bearer, 401이면 Keychain 비우고 로그인 화면), `Keychain`, `SessionStore`(UserDefaults `lbn_session_start`), `Split`(NLTokenizer + 웹과 같은 약어·소문자·구두점 보정), `AppLog`(OSLog + Application Support/app-log.jsonl 2000줄 순환, 비정상 종료·error 감지 후 다음 실행 때 자동 POST /api/logs), `MockServer`(DEBUG 전용).
- `LearnByNews/UI`: `Theme`(웹 styles.css 색·글꼴·줄높이 32pt·여백 36pt), `Paper`(줄노트 Canvas, Entry, Stamp, Sticky, Tiny, NotebookHead), `EntryView`(채점 항목, 빨간 밑줄 markWrong, 포스트잇 토글, FlowLayout, SourceLink).
- `LearnByNews/Screens`: `ShelfView`(붙여넣기+링크+공책 목록+공부 기록), `NotebookView`, `DoneView`, `PhrasesView`, `QuizView`, `ActivityLogView`, `SettingsView`, `SessionBar`(SessionModel.shared).
- 탭: 기사 / 표현장 / 시험지 / 기록 / 설정. 시험지·기록의 "공책에서 보기"는 `Router.open`으로 기사 탭의 NavigationStack 경로를 바꾼다.
- 빨간 물결 밑줄: SwiftUI에 물결 패턴이 없어 점선(`.dot`) 밑줄로 대신한다.
- Enter 제출: 세로 TextField에서 줄바꿈 문자가 들어오면 제출(한글 조합 중 Enter는 조합 확정이라 줄바꿈이 안 들어온다).

### 시뮬레이터 확인용 환경변수 (DEBUG 빌드만)
- `SIMCTL_CHILD_LBN_MOCK=1`: 서버 대신 메모리 모의 서버(`MockServer`). 비밀번호 없이 화면을 볼 수 있다.
- `SIMCTL_CHILD_LBN_ROUTE=notebook:a1 | notebook:a1:s2 | done:a2 | restart:a2 | restart:a2:1(앞 1문장 뒤부터) | phrases | quiz | log | settings`: 시작 화면.
- `SIMCTL_CHILD_LBN_SESSION=1`: 공부 세션이 시작된 상태로 시작.
- `SIMCTL_CHILD_LBN_AUTOSUBMIT=1`: 공책을 열자마자 현재 문장에 번역을 넣고 제출(채점 중 상태·멈추기 버튼 확인용, 모의 채점이 8초 걸린다).
- 모의 모드에서는 Face ID 잠금을 끈다.
- 예: `SIMCTL_CHILD_LBN_MOCK=1 SIMCTL_CHILD_LBN_ROUTE=notebook:a1 xcrun simctl launch <sim> com.goni.learn-by-news`

### 실기기에서 goni가 확인할 것 (시뮬레이터에서 못 본 것)
- 실제 비밀번호 로그인과 실제 서버 응답 해석(특히 채점·총평·시험지 JSON).
- 한글 키보드에서 Enter 제출이 조합 중 글자를 잃지 않는지.
- 채점 대기 중 도장(✎ 흔들림)과 결과 도착 시 펼침·스크롤.
