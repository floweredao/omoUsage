# OmoUsage Design Contract

## 0. Reference

- The supplied menu-bar screenshot remains the visual source of truth.
- The user’s corrective feedback overrides the screenshot for meter badges,
  meter color, refresh emphasis, provider help, and the status-item glyph.
- The August 3 menu-bar and system-monitor screenshots override the earlier
  custom-panel behavior: the dashboard must anchor to its own status item and
  follow the current macOS appearance with high semantic contrast.
- OpenUsage supplies provider/authentication behavior only; its extra product
  surfaces, branding, and help links are not copied.
- Interaction mechanics adapt beui.dev `button` and `shared-layout-bg`:
  immediate hover tint, spring-like press scale, and interruptible return.
- The private web dashboard follows this existing semantic system rather than
  introducing a separate brand. Its spatial contract combines StyleGallery
  `card-grid` for provider repetition with `scroll-body-shell` for one
  document-owned vertical scroll region; cards never create nested scroll.

## 1. Product Intent

OmoUsage is a compact, native macOS status utility. The dashboard contains
only providers with usable authenticated data. Settings reports local
credential discovery and owns API-key entry for providers that upstream
OpenUsage configures in-app. It also launches each companion provider's
official connection flow without owning or rewriting third-party credentials.

OmoUsage Mobile is a read-only iPhone companion. The Mac remains the only
credential owner and publishes the latest usage snapshot through the user's
private iCloud key-value store. The mobile app never receives provider
credentials and never starts third-party authentication.

The web dashboard is another read-only companion surface. The Mac serves only
the sanitized snapshot on loopback, and Tailscale supplies private tailnet
identity and HTTPS. The web surface never receives credentials, invokes
provider APIs, or exposes authentication mutations. Its sole dashboard
command is a nonce-protected request to the existing local
`UsageDashboardViewModel.refresh()` owner; the browser never becomes a second
provider-fetch owner.

The web settings page is a narrowly scoped control surface rather than a
credential surface. It may persist an independent Web language, synchronize
provider display order and visibility, and expose refresh state from the one
local Mac view model. Web language initializes from App language once when no
web preference exists, then changes independently.
API keys, credential status internals, local paths, launch-at-login, executable
launches, and other privileged controls remain native-only.

## 2. Visual Tokens

- Panel: 320 pt wide, native `NSPopover`, regular system material.
- Spacing: 4/8/10/12/14/20 pt.
- Text: system type, 10.5–15 pt, medium through bold.
- Standard meter: muted eucalyptus `#4C8577`; extra meter: muted amber
  `#B7793F`; track: primary at 9% opacity.
- Footer controls share the same passive secondary foreground. No icon-only
  footer action receives a persistent filled background.
- Provider colors identify brands without expanding the dashboard chrome.
- Settings rows use semantic control backgrounds and separator colors; meter
  tracks use 16% semantic contrast in both appearances.
- Mobile canvas and cards use semantic system backgrounds. Mobile meters reuse
  the standard eucalyptus and extra-usage amber tokens without introducing a
  second palette.
- Web canvas: `#F4F4F0` light and `#111310` dark; card: semantic elevated
  surfaces with a one-pixel low-contrast border and restrained shadow.
- Web spacing: 4/8/12/16/20/24/32 px. Content is capped at 720 px and uses
  16 px phone gutters, increasing to 24 px when space permits.
- Web focus and status colors meet WCAG AA against their surfaces. Standard
  and extra meters reuse eucalyptus and amber; availability is also written.
- Keyboard focus uses opaque eucalyptus `#3F7568` on light surfaces and
  `#79B5A5` on dark surfaces so the three-pixel outline stays above 3:1
  against both the canvas and elevated controls.
- Web accent text uses dedicated AA tokens rather than meter-fill colors:
  eucalyptus `#3F7568` and amber `#955F2D` on light surfaces, eucalyptus
  `#79B5A5` and amber `#E0A064` on dark surfaces.
- Dashboard and settings navigation uses the exact bundled OmoUsage app icon
  as the same-origin SVG favicon. The established eucalyptus gauge tile stays
  as the in-page dashboard identity ornament; it is not a replacement page
  icon or a second favicon.
- iOS Safari receives a 180×180 PNG rendered from that same bundled
  `AppIcon.svg` through `apple-touch-icon` metadata, so the share sheet uses
  OmoUsage artwork rather than the generic website compass.

## 3. Typography

- Provider names: 15 pt bold.
- Plan pills: 10.5 pt semibold.
- Meter labels: 11.5–12 pt medium.
- Metadata and reset labels: 10.5 pt regular/medium.
- Mobile title: native large navigation title.
- Mobile provider names: 17 pt semibold; meter labels and values: 13 pt
  medium/semibold; metadata: 12 pt regular.
- Web uses the system font stack with a 28 px/700 page title, 17 px/650
  provider names, 14 px/600 meter values, and 12–13 px metadata. Text remains
  usable at 200% zoom without clipping or horizontal page scroll.
- Settings labels use 15–17 px semibold hierarchy; helper, synchronization,
  and validation text use 12–13 px regular text with explicit status wording.

## 4. Layout

- Provider order follows OpenUsage: Claude, Codex, Cursor, Antigravity,
  Copilot, Devin, Grok, OpenCode, OpenRouter, Z.ai.
- Providers without prior usage are omitted when unavailable or unauthenticated.
  Providers with last-good usage remain visible during transient failures and
  malformed or expired credential recovery.
- Settings lists all ten providers with connection state and exact local
  credential guidance.
- CLI- and app-backed providers expose one `연결 시작` control that launches
  the official installed authentication flow. If the required tool is absent,
  the control reports which executable must be installed; help links remain
  available separately and are never reported as successful authentication.
- Copilot prefers its official CLI, then an installed GitHub CLI. OpenCode
  resolves only the official `opencode` executable; similarly named third-party
  binaries such as `opencodex` are never used.
- API-key fields appear only for OpenRouter and Z.ai.
- Meter rows render only the period title, remaining percentage, track, and
  reset text. The former `메뉴바` badge is not part of the UI.
- Mobile owns the full screen and scrolls provider cards vertically with
  16 pt page margins and 12 pt card spacing. Pull-to-refresh reloads iCloud;
  it does not call provider APIs from the phone.
- The mobile empty state explains that the Mac must refresh once and that both
  devices must use the same Apple ID.
- Web owns one page-level vertical scroll. The sticky summary header remains
  compact; provider cards form a single column below 640 px and a fluid
  two-column card grid above it. No card has internal scrolling.
- The web empty and error states stay inside the main content region and keep
  the last successful refresh timestamp visible when available.
- `/settings` reuses the same 720 px shell and sticky identity header. Its
  controls form one column below 640 px and grouped cards above it. Provider
  order controls remain in DOM order and never create nested scrolling.

## 5. Components

- `ProviderSectionView`: authenticated provider usage only.
- `ProviderSettingsRow`: icon, name, connection status, native help, and
  provider-appropriate connection controls; API-key providers expose editable
  authentication controls instead.
- `ProviderHelpView`: native Korean setup guidance plus an optional official
  provider link; it never routes through OpenUsage.
- `InteractiveIconButton`: 28 pt hit target with hover, focus, and press state.
- `ProviderIcon`: 20 pt branded tile with SVG or native monogram fallback.
- `MobileProviderCard`: provider identity, optional plan pill, usage groups,
  meters, credits, and provider timestamp in one semantic grouped surface.
- `MobileUsageMeter`: title, remaining percentage, 6 pt capsule track, and
  reset metadata with the same period color semantics as macOS.
- `MobileSyncState`: loading, synchronized content, empty guidance, and
  recoverable error states; each has explicit text rather than color alone.
- `WebDashboardHeader`: identity, private-tailnet status, latest refresh time,
  a non-interactive live connection indicator, the dashboard/settings page
  link, and `WebRefreshButton`.
- `WebProviderCard`: provider name, plan, availability, grouped usage meters,
  credits, and provider timestamp in one semantic article.
- `WebUsageMeter`: label, numeric remaining percentage, accessible progress
  semantics, reset metadata, and the shared period color.
- `WebRefreshButton`: one local-view-model refresh command, immediate busy and
  disabled state, synchronized completion timestamp, and no parallel fetch
  owner.
- `WebSettingsPage`: independent Web language selector, provider order
  controls, provider visibility controls, local synchronization status, and
  dashboard back link. It never displays credential values or
  credential-source metadata.

## 6. Motion and Interaction

- Hover: 100–120 ms ease-out tint without geometry movement.
- Press: stronger tint and symbol opacity feedback without scaling.
- Refresh: continuous rotation only while work is active.
- Refresh has no persistent accent fill; hover and press are its only
  background states.
- Reduced motion: no scale or rotation; opacity/color feedback remains.
- Every icon-only action has an accessibility label and help tooltip.
- Mobile refresh uses the native pull gesture and toolbar action. No decorative
  motion is added; system reduced-motion and Dynamic Type behavior are kept.
- Web data refreshes every 30 seconds and when the page becomes visible. The
  connection indicator announces loading, current, and unavailable states.
  Meter transitions use opacity only and are disabled by reduced motion.
- Web settings reconcile from `/api/settings` every 2 seconds and when the
  page becomes visible so native-app changes propagate without navigation.
- A user-triggered refresh updates the control state immediately, disables the
  button while the local app is refreshing, and returns to idle only after the
  local view model publishes completion. Settings mutations optimistically
  disable only the affected control and reconcile from `/api/settings`.

## 7. Accessibility

- Minimum pointer target: 28×28 pt in the compact footer.
- Keyboard focus uses the native accent outline.
- Connection state is communicated by text plus color.
- Korean labels must not clip at the Settings window’s minimum width.
- Missing companion tools produce a localized installation requirement rather
  than opening documentation or reporting that authentication started.
- Text and controls use semantic system colors and remain legible in both
  macOS appearances without an app-specific theme toggle.
- Mobile cards retain readable order at accessibility text sizes, expose each
  meter as one combined accessibility element, and use at least 44 pt touch
  targets for toolbar actions.
- Web markup uses one `main`, semantic provider `article` elements, explicit
  status text with `aria-live="polite"`, and native `progress` semantics.
- Settings controls have explicit labels, at least 44 px touch targets,
  deterministic keyboard order, and status/error announcements through a
  polite live region. Reorder buttons name provider and direction.
- At 390×844, 375 px, 768 px, and 1280 px viewports, the document has no
  horizontal overflow. Light/dark system preference and reduced motion are
  honored without a theme toggle.

## 8. Accepted Constraints

- The dashboard is presented by `NSPopover.show(relativeTo:of:preferredEdge:)`
  from the OmoUsage `NSStatusItem`; no custom pointer or screen-relative panel
  geometry is used.
- OmoUsage never forces Aqua, Dark Aqua, or a SwiftUI color scheme. Dashboard,
  Settings, help, and controls inherit the operating-system appearance.
- Companion providers keep upstream-style local credential discovery while
  OmoUsage launches only their installed official authentication flow.
- Provider help may link to official documentation. The main Settings row
  starts authentication for missing, malformed, or expired credentials and
  offers refresh retry for transient provider failures while keeping
  disconnect available.
- The menu-bar item uses the native
  `gauge.with.dots.needle.50percent` SF Symbol as a 14 pt, medium-weight
  monochrome template image.
- OpenRouter and Z.ai keys are written only to their documented local config
  files; values are never rendered after save or written to diagnostics.
- Mobile synchronization contains usage totals, plan labels, reset times, and
  refresh timestamps only. Provider credentials, cookies, API keys, local file
  paths, and diagnostics never enter iCloud.
- The web server binds only to `127.0.0.1:7827`. Tailscale Serve proxies that
  loopback endpoint to the authenticated tailnet; Tailscale Funnel and direct
  LAN/public binding are forbidden.
- Web control chrome remains English. The selected Web language is persisted
  separately from native App language and localizes provider-generated
  dashboard text only; changing it never mutates the native
  `LocalizationController` or App language preference.
- Read routes are `GET /`, `GET /settings`, `GET /api/snapshot`,
  `GET /api/settings`, `GET /favicon.svg`, and
  `GET /apple-touch-icon.png`. Mutating routes are limited to
  `POST /api/refresh` and `POST /api/settings`.
- Every mutation requires an unpredictable per-launch nonce delivered in the
  same-origin HTML shell and echoed as `X-Omo-CSRF`. Unknown fields, secret
  fields, malformed JSON, invalid provider IDs/orders, oversized bodies,
  unsupported methods, and traversal-like paths are rejected before dispatch.
- The loopback machine remains a trusted boundary; the nonce blocks cross-site
  and accidental mutation, while Tailscale identity remains the remote access
  boundary. No cookies, analytics, external fonts, or third-party scripts are
  accepted.
- iCloud key-value sync requires both Xcode targets to use the same development
  team and ubiquity key-value identifier. Simulator and Catalyst fixture mode
  is accepted only for visual QA; production reads the private iCloud snapshot.
