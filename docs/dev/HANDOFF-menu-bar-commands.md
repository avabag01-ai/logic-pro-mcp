# 작업 지시서: `logic_system`에 메뉴바 명령 추가 (list_menus / click_menu)

> 맥에서 이 저장소를 연 Claude Code 세션에 이 파일을 그대로 넘기세요.
> 예: `claude "docs/dev/HANDOFF-menu-bar-commands.md 읽고 그대로 진행해"`

## 목표

화면 캡처 없이 Logic Pro의 **메뉴바 전체를 손쉬운 사용(AX) API로 읽고, 메뉴 경로로 아무 항목이나 실행**하는 범용 명령 두 개를 `logic_system` 도구에 추가한다. 로직의 메뉴에 있는 기능 대부분을 AI가 빠르게 쓸 수 있게 하는 게 목적이다.

- 대상 로직 언어: **한국어** (ko-KR은 이 프로젝트의 measured locale)
- 브랜치: `feat/menu-bar-commands`
- 원본: MongLong0214/logic-pro-mcp (MIT), 포크: avabag01-ai/logic-pro-mcp

## 현재 상태

리눅스 클라우드 세션에서 초안 구현을 진행했다. 거기서는 Swift 툴체인이 없어서 **빌드와 테스트를 한 번도 못 돌렸다.** 브랜치에 초안이 커밋되어 있으면 그걸 출발점으로 삼아 빌드 에러부터 고치고, 초안이 없으면 아래 명세대로 처음부터 구현한다.

## 명세

### 1. `list_menus` (읽기 전용)

- params: `menu?: String` (최상위 메뉴 하나로 제한), `max_depth?: Int` (기본 3, 최대 5)
- 메뉴바를 재귀로 돌며 항목마다 다음을 반환한다:
  - `title`: AX 제목 원문
  - `path`: 최상위부터의 제목 배열
  - `enabled`: true, false, 또는 읽을 수 없으면 null
  - `has_submenu`
  - `shortcut`: `AXMenuItemCmdChar`와 `AXMenuItemCmdModifiers`로 만든 단축키. 해석 방법은 `AccessibilityChannel+Editing.swift` 168~188행 부근 참고
- 구분선(빈 제목)은 건너뛴다.
- `ui_locale`을 포함한다. `AXLogicProElements+Menu.swift`의 `logicUILocaleIdentifier`를 쓴다.
- 메뉴를 열기 전에는 제목이 오래된 값일 수 있다 (`Editing.swift` 109~145행 `openMenuAndConfirm` 참고). 열지 않고 읽는다면 응답에 `titles_may_be_stale_until_opened: true`를 표시한다.
- State A 응답 규약(`Utilities/HonestContract.swift`)을 따른다.

### 2. `click_menu` (변경 작업)

- params: `path` (문자열 배열, 예: `["트랙","새로운 트랙..."]`; `"트랙 > 새로운 트랙..."`처럼 하나의 문자열도 허용), `confirmed: true` (필수)
- 확인 수준: `.l2` (`system.clear_traces`와 같은 방식)
- 제목 비교 전에 정규화한다: 앞뒤 공백 제거, U+00A0을 일반 공백으로, `...`와 `…`(U+2026)를 같게, 대소문자 무시.
- **라이브 AX 제목과 호출자 문자열만 비교한다.** 한국어 문자열을 코드에 하드코딩하지 않는다. `Scripts/check-labelsets-live-in-the-policy.py`, `check-ax-comparisons-use-labelsets.py`, `ci-forbid-hardcoded-menu-bar-item.sh`를 통과해야 한다.
- 다음 경우에는 거부한다 (State C, isError):
  - 경로의 한 단계를 찾지 못함 → 에러에 **형제 항목 제목 목록**을 포함
  - 같은 이름이 둘 이상 매칭됨 (모호함)
  - 마지막 항목이 비활성이거나 활성 상태를 읽을 수 없음
  - 마지막 항목에 하위 메뉴가 있음 (말단 항목이 아님)
  - 경로가 비었거나 6단계를 넘음
  - 애플 메뉴 (메뉴바 자식 인덱스 0)
  - 단축키가 Cmd+Q인 항목 → `logic_project quit`을 쓰라고 안내
- 실행은 `AccessibilityChannel+Project.swift` 1519~1560행 `clickMenuItem` 패턴 (`AXHelpers.performAction(el, kAXPressAction)`)을 따른다.
- 응답은 State B (누른 것까지만 확인, 결과는 읽어서 검증하지 않음). extras에 `path_matched`(실제 AX 제목)와 `ui_locale`을 넣는다.

## 연동 체크리스트 (이 저장소는 명령 하나에 여러 곳을 같이 고쳐야 한다)

- [ ] `Server/OperationRegistry.swift`: `OperationID`에 `systemListMenus`, `systemClickMenu` 추가; `allowedOperationIDsByTool`, `allowedCommandsByTool`에 추가; system spec 행 추가 (669~700행 부근); click_menu는 `.l2`
- [ ] `Channels/RoutingTable.swift`: `"menu.list"`, `"menu.click"`를 `[.accessibility]`로 추가
- [ ] `Channels/AccessibilityChannel.swift` `execute` (312행 부근): case를 추가하고 새 파일 `Channels/AccessibilityChannel+MenuBar.swift`에 위임
- [ ] `Server/OperationHandlerRegistry.swift` (123~190행): 핸들러 바인딩
- [ ] `Dispatchers/SystemDispatcher.swift`: `handle`에 case 추가, `tool` 설명(Commands 목록과 Params 섹션), `help` 텍스트(2090~2110행). 변경 작업은 `startTraceIfEnabled`, `withWriteBoundaryArmed`, `finalizeTrace` 패턴을 따른다 (NavigateDispatcher의 `zoom_to_fit` 참고)
- [ ] `Qualification/SemanticOracleTable.swift`: list_menus는 `OperationOracle`과 `Tests/.../SemanticOracleFixtures.swift` 픽스처 추가; click_menu는 `structurallyUnverifiedMutatingOperationIDs`에 사유를 달아 추가 (`.mixerBank` 참고)
- [ ] 명령 목록이 들어 있는 곳: `Workflows/WorkflowSkillCatalog.swift`, `Server/OperationCatalog.swift`, `docs/API.md`, `docs/roadmap/README.md`, manifest와 server.json 등. `grep -rn setup_control_surface`로 찾을 수 있다.
- [ ] 테스트의 하드코딩된 개수 갱신 (spec 117→119, mutating 93→94 등): `OperationCatalogTests`, `OperationRegistryTests` (smallToolCount 21→23), `OperationHandlerBindingTests`, `OperationRegistryCoverageTests`, `OperationTraceCoverageTests`, `HCGlobalInvariantTests`, `DispatcherTests`, `Issue253HelpCategoriesTests`, `OperationDispatchCensusTests`
- [ ] 새 테스트 `Tests/LogicProMCPTests/MenuBarCommandsTests.swift`: 등록과 params, `.l2`, confirmed 없을 때 거부, 경로 파싱, 정규화, 메뉴 트리 스냅샷에 대한 순수 함수 경로 탐색

## 맥에서 검증

```bash
git fetch origin && git checkout feat/menu-bar-commands && git pull
swift build
swift test --filter MenuBarCommands
swift test --no-parallel          # 라우팅이나 안전 정책을 바꿨으면 필수
for f in Scripts/check-*.py; do python3 "$f" || echo "FAIL $f"; done
bash Scripts/ci-forbid-hardcoded-menu-bar-item.sh
```

### 실제 로직(한국어)에서 수동 테스트

1. 로직을 실행하고 빈 프로젝트를 연다.
2. `logic_system` `list_menus`: 메뉴 트리가 한국어 제목으로 나오는지, 단축키가 맞는지 확인
3. `list_menus {menu:"트랙"}`: 트랙 메뉴만 나오는지 확인
4. `click_menu {path:["트랙","새로운 트랙..."], confirmed:true}`: 새 트랙 창이 뜨는지 확인 (`...`로 입력해도 `…` 제목과 매칭돼야 함)
5. confirmed 없이 실행 → 거부되는지 확인
6. 없는 경로 → 형제 목록이 담긴 에러가 나오는지 확인
7. 종료 항목 (Cmd+Q) → 거부되는지 확인

## 완료 조건

- 빌드, 전체 테스트, CI 스크립트 모두 통과
- 위 수동 테스트 1~7 통과
- `feat/menu-bar-commands`에 커밋과 푸시, 포크 저장소 `main`으로 PR 생성
- 커밋 메시지는 한국어나 영어 모두 괜찮다. 원본 저장소의 커밋 스타일(`feat(system): ...`)을 따른다.

## 다음 단계 (이번 범위 아님)

- Mackie Control V-Pot으로 플러그인 파라미터 조절 (기존 MCP의 가장 큰 빈틈)
- 키 커맨드 목록 읽기와 실행
