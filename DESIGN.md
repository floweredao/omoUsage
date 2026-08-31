# OmoUsage Design Contract

## 0. Reference

- The supplied menu-bar screenshot remains the visual source of truth.
- The user’s corrective feedback overrides the screenshot for meter badges,
  meter color, refresh emphasis, provider help, and the status-item glyph.
- The August 3 menu-bar and system-monitor screenshots override the earlier
  custom-panel behavior: the dashboard must anchor to its own status item and
  follow the current macOS appearance with high semantic contrast.
- The August 28 side-notch references define an optional alternate native
  presentation. They contribute edge glanceability, circular remaining-usage
  summaries, and inward detail expansion without copying their black
  silhouette, speech-tail geometry, branding, or "used" percentage semantics.
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

The native dashboard offers two mutually exclusive presentation styles.
`Popover` is the default and preserves the status-item-anchored 320 pt
`NSPopover`. `Side Notch` keeps a 6 pt reveal handle at the selected screen's
usable right edge, reveals a 56 pt usage rail on edge entry or menu-bar
request, and expands a 280 pt provider detail card inward. Both styles share
one dashboard view model and refresh owner. Switching styles closes the
previous surface before enabling the next.

OmoUsage Mobile is a read-only iPhone companion. The Mac remains the only
credential owner and publishes the latest usage snapshot through the user's
private iCloud key-value store. The mobile app never receives provider
credentials and never starts third-party authentication.

The web dashboard is another companion surface. The Mac serves only the
sanitized snapshot and narrowly scoped display controls on loopback, and
Tailscale supplies private tailnet identity and HTTPS. The web surface never
receives credentials, invokes provider APIs, or exposes authentication
mutations. Its refresh command delegates to the existing local
`UsageDashboardViewModel.refresh()` owner; the browser never becomes a second
provider-fetch owner.

The web settings page is a narrowly scoped control surface rather than a
credential surface. It may persist an independent Web language, synchronize
account-provider display order and visibility, and expose refresh state from
the one local Mac view model. Two accounts on one provider remain separate
controls and neither order nor visibility broadens to provider-level mutation.
Web language initializes from App language once when no web preference exists,
then changes independently.
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
- Dashboard-order rows reuse the settings surface, separator, 4/8/10 pt
  spacing, system type, and native focus/accent treatments. Their 24 pt
  provider icon and SF Symbol drag handle introduce no new color, material,
  radius, or typography token.
- The side-notch rail and detail card use regular system material, semantic
  borders, and the existing eucalyptus/amber usage palette. Provider branding
  remains inside the existing icon tiles.
- The hidden side-notch handle is 6 pt wide with an 8 pt edge tracking region.
  The revealed rail uses 20 pt leading corners and square screen-edge corners;
  its ring track reuses `UsageMeterVisualTokens.trackOpacity`.
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
- Side-notch mode pins a 6 pt hidden handle or 56 pt revealed rail to
  `NSScreen.visibleFrame.maxX`, centers it vertically with 20 pt minimum top
  and bottom margins, and grows to 344 pt inward without moving its right
  edge. Provider rows are 58 pt high. Fourteen points of total rail padding
  plus a 58 pt vertically stacked footer defines the rail's natural height.
  While presented, the panel also reserves the largest visible provider
  detail height plus 12 pt top and bottom margins. This prevents vertical
  movement on provider selection and may leave intentional slack between the
  last provider row and footer when detail content is taller than the rail.
- The side-notch detail card is 280 pt wide and at most 320 pt high. It uses
  the existing provider section, applies 14 pt content padding, and scrolls
  only when that provider's complete usage content exceeds the cap.
- Providers without prior usage are omitted when unavailable or unauthenticated.
  Providers with last-good usage remain visible during transient failures and
  malformed or expired credential recovery.
- Retained last-good usage keeps every meter and states its staleness instead of
  reading as current. The provider card gains an amber symbol-and-text badge
  above its meters, keeps the unchanged last successful refresh time, and adds
  the newer failed attempt time on its own line. The success time never advances
  on a failed attempt, while the footer's aggregate attempt time does. Popover,
  Side Notch detail, web, and mobile cards follow the same rule, and the Side
  Notch rail marks the stale provider with the same symbol.
- Settings owns one retained window that closes and reopens without duplication.
  It is deliberately not miniaturizable because a minimized Settings thumbnail
  creates Dock presence for an otherwise Dockless `LSUIElement` application.
- Settings owns one page scroll region. The existing outer `ScrollView` around
  the settings stack is the only scroll owner; every section inside it,
  including `Dashboard Order`, lays out at its intrinsic content height and
  never nests a second scroll region. The ordering list is height-driven by its
  row count (row height times count) rather than a fixed viewport fraction, so
  a wheel gesture anywhere in Settings always moves the same surface.
- This follows StyleGallery `scroll-body-shell`: the settings header and footer
  remain stable while the named outer body owns vertical scrolling. API-key
  account forms and account rows participate in ordinary body flow and never
  introduce another `List` or `ScrollView`.
- `Dashboard Order` sits between the presentation/login settings group and the
  `Provider Authentication` group. Ordering is a separate task from
  authentication, so it gets its own titled section rather than controls
  embedded in each auth row.
- The ordering list is keyed by `AccountProviderID`, so two accounts on one
  provider are two independently draggable rows. Each row shows a drag handle,
  `ProviderIcon`, provider name, the sanitized account alias when the account
  is non-default or the provider has more than one account, and `N of M`
  position text.
- Settings lists all ten providers with connection state and exact local
  credential guidance. When Side Notch is selected, Settings also exposes a
  localized native menu for 0.4, 0.8, 1.2, or 2.0 second hide delay; 0.8
  seconds remains the default.
- CLI- and app-backed providers expose one `연결 시작` control that launches
  the official installed authentication flow. If the required tool is absent,
  the control reports which executable must be installed; help links remain
  available separately and are never reported as successful authentication.
- Copilot prefers its official CLI, then an installed GitHub CLI, with no web
  fallback. Launch remains pending because GitHub OAuth alone does not prove
  Copilot quota access; the refreshed provider endpoint decides availability.
  OpenCode Go uses an OmoUsage-owned API-key field and still discovers official
  `auth.json` and local usage as lower-priority fallbacks.
- API-key fields appear only for OpenCode Go, OpenRouter, and Z.ai.
- `API Key Accounts` follows Provider Authentication. Its compact form has a
  provider picker, sanitized account-alias field, secure key field, and one
  Add Account action. Existing non-default references are intrinsic-height
  rows with provider icon, provider name, account alias, and a destructive
  Remove action. Keys and account UUIDs are never rendered.
- Meter rows render only the period title, remaining percentage, track, and
  reset text. The former `메뉴바` badge is not part of the UI.
- Mobile owns the full screen and scrolls provider cards vertically with
  16 pt page margins and 12 pt card spacing. Pull-to-refresh reloads iCloud;
  it does not call provider APIs from the phone.
- Mobile states when the Mac last checked rather than implying that the phone
  just refreshed. That time is the snapshot's own refresh attempt and never
  moves on a pull; only a newly published snapshot advances it. Once the
  snapshot reaches fifteen minutes of age, the header adds an amber
  symbol-and-text out-of-date badge. Snapshot age and provider staleness are
  separate facts and may appear together on one screen.
- A failed iCloud read keeps the last good snapshot and its timestamps on
  screen and adds one explicit sync-issue line instead of blanking the data.
  The refresh affordance states that it checks iCloud only.
- Mobile preserves snapshot order and keys every provider card by
  `AccountProviderID`. A non-default account, or any provider repeated in the
  snapshot, shows its sanitized alias directly below the provider name as one
  truncating line of native secondary caption text. A lone legacy account
  remains visually unchanged.
- The mobile empty state explains that the Mac must refresh once and that both
  devices must use the same Apple ID.
- Web owns one page-level vertical scroll. The sticky summary header remains
  compact; account-provider cards follow StyleGallery `card-grid`, forming a
  single column below 640 px and a fluid two-column grid above it. Each card is
  keyed by `AccountProviderID`; DOM, reading, focus, and account order stay
  aligned, and no card has internal scrolling.
- Repeated provider cards and settings rows pair the provider brand mark with
  an alias whenever the account is non-default or that provider occurs more
  than once. Alias containers use `min-width: 0`, one-line ellipsis, and a
  native title exposing the full sanitized value without page overflow.
- The web empty and error states stay inside the main content region and keep
  the last successful refresh timestamp visible when available.
- `/settings` reuses the same 720 px shell and sticky identity header. Its
  controls form one column below 640 px and grouped cards above it. Provider
  order controls remain in DOM order and never create nested scrolling.

## 5. Components

- `ProviderSectionView`: authenticated provider usage only.
- `ProviderSettingsRow`: icon, name, connection status, native help, and
  provider-appropriate connection controls; API-key providers expose editable
  authentication controls instead. It owns authentication only and carries no
  ordering affordance.
- `ProviderOrderingView`: the `Dashboard Order` surface. A native SwiftUI
  `List` in `.plain` style with an explicit draggable SF Symbol handle and
  account-qualified row drop destinations. A targeted row receives the native
  accent tint, and one completed drop produces one semantic insertion. Its
  height is computed from a 60 pt content-safe row height times the row count
  and it sets `.scrollDisabled(true)`; the page `ScrollView` keeps scroll
  ownership. A `Reset to Default` control sits in the section header and is
  disabled while the order already equals the configured default.
- `ProviderOrderRow`: one composite account-provider row. Drag handle glyph,
  `ProviderIcon`, provider name, optional sanitized account alias, and
  `N of M` position text. Never renders credentials, account UUIDs, or
  credential-source paths.
- `APIKeyAccountsSection`: native multi-account management for OpenCode,
  OpenRouter, and Z.ai. The add action is disabled until alias and key are both
  nonempty; success clears both drafts, while failure preserves them for
  correction and reports localized status without echoing the key.
- `APIKeyAccountRow`: provider icon, provider name, sanitized alias, and one
  targeted Remove action. It represents only non-default account-provider
  references; legacy API-key editing stays in `ProviderSettingsRow`.
- `DashboardAccountIdentityRule`: shows a sanitized alias beside the provider
  name whenever the account is non-default or the current snapshot contains
  more than one row for that provider. The alias uses secondary system text
  and never exposes UUIDs, paths, or credential source.
- `ProviderHelpView`: native Korean setup guidance plus an optional official
  provider link; it never routes through OpenUsage.
- `InteractiveIconButton`: 28 pt hit target with hover, focus, and press state.
- `SideNotchPanelController`: one retained nonactivating floating `NSPanel`,
  authoritative hidden/revealed/detail state, cancellable 0.18 s edge-reveal
  dwell, user-configurable auto-hide, screen-aware frame calculation,
  outside-click collapse, and Space/display reconfiguration. Only a pinned
  selection may take panel key state or start the outside-click and Escape
  monitors; a hover preview does neither.
- `SideNotchPanelState`: authoritative side-notch selection. It is keyed by
  `AccountProviderID`, not `ProviderID`, so two accounts on one provider
  address distinct rows, and it distinguishes a transient `hovered` selection
  from a `pinned` one.
- `SideNotchPanelView`: provider rail, remaining-usage rings, selected provider
  detail, refresh, Settings, Quit, and one AppKit edge tracking surface.
- `DashboardPresentationStyleStore`: repaired UserDefaults preference with
  Popover as the backward-compatible default.
- `SideNotchHideDelayStore`: repaired typed UserDefaults preference with 0.8
  seconds as the omitted-key default.
- `ProviderIcon`: 20 pt branded tile with SVG or native monogram fallback.
- `MobileProviderCard`: composite account-provider identity, conditional
  sanitized account alias, optional plan pill, usage groups, meters, credits,
  and provider timestamp in one semantic grouped surface.
- `MobileUsageMeter`: title, remaining percentage, 6 pt capsule track, and
  reset metadata with the same period color semantics as macOS.
- `MobileSyncState`: loading, synchronized content, empty guidance, and
  recoverable error states; each has explicit text rather than color alone.
- `MobileFreshnessPresentation`: the one model behind that header. It derives
  the Mac's last check time, the fifteen-minute snapshot age, and the sync-issue
  flag from an injected clock, so every surface and test reads the same state.
- `WebDashboardHeader`: identity, private-tailnet status, latest refresh time,
  a non-interactive live connection indicator, the dashboard/settings page
  link, and `WebRefreshButton`.
- `WebProviderCard`: provider mark, provider name, conditional sanitized account
  alias, plan, availability, grouped usage meters, credits, and provider
  timestamp in one semantic article keyed by `AccountProviderID`.
- `WebUsageMeter`: label, numeric remaining percentage, accessible progress
  semantics, reset metadata, and the shared period color.
- `WebRefreshButton`: one local-view-model refresh command, immediate busy and
  disabled state, synchronized completion timestamp, and no parallel fetch
  owner.
- `WebSettingsPage`: independent Web language selector, composite account
  order controls, account visibility controls, explicit per-account status,
  local synchronization status, and dashboard back link. It uses stable
  escaped DOM keys derived from the typed account/provider fields and never
  displays UUIDs, credential values, or credential-source metadata.

## 6. Motion and Interaction

- Hover: 100–120 ms ease-out tint without geometry movement.
- Press: stronger tint and symbol opacity feedback without scaling.
- Entering the 6 pt edge handle for 0.18 seconds reveals the rail and cancels
  a pending hide. Brief crossings cancel the reveal task before it fires.
  The stationary pointer that triggered the reveal is not treated as a
  provider-row hover; the visible handle stays 6 pt wide inside one bounded
  8×144 pt transparent tracking region, and a preview begins only after the
  pointer moves inward past that tracking strip. The hidden region is centered
  on the latest edge-entry anchor, falls back to the screen midpoint, and
  clamps wholly inside that screen's visible frame. Right-edge app and
  scrollbar input above and below it remains owned by the foreground app.
  Leaving the revealed rail schedules one cancellable hide using the selected
  0.4, 0.8, 1.2, or 2.0 second delay. Background refresh and controller-driven
  frame changes never reveal the rail.
- Only hidden-edge entry records a vertical reveal anchor. Re-entering an
  already visible panel does not move that anchor, and menu-bar activation
  clears any old edge anchor so the compact rail opens at the screen center.
- Side-notch provider detail has two selection kinds. Pointing at a rail row
  opens a transient hover preview immediately; clicking it, or pressing Return
  or Space on it, pins that row. Hover is a preview, never a commitment.
- A hover preview is passive by contract: it never makes the panel key, never
  starts the outside-click monitor, and never moves keyboard focus away from
  the frontmost application. Only pinning may activate the panel.
- Moving between rail rows retargets the transient preview to the newly
  pointed row. A pinned selection is never overwritten by incidental hover;
  it changes only through an explicit click, Return, or Space.
- The transient preview collapses when the pointer leaves the whole panel,
  including its detail card and the gap between rail and detail. Traveling
  from the rail across that gap into the detail keeps the preview open, so a
  previewed card can always be reached and scrolled.
- Clicking the pinned active row collapses it. Pressing Escape, or clicking
  outside the panel, also collapses the detail while leaving the rail
  available.
- Leaving the whole panel clears a transient preview and starts the configured
  rail auto-hide delay. A pinned detail survives pointer exit.
- When the selected provider disappears from a refresh, the composite
  selection reconciles: it is cleared rather than left pointing at a row that
  no longer exists.
- Provider detail uses opacity-only insertion/removal while the AppKit panel
  alone owns the inward width animation; no second directional SwiftUI move
  competes with panel geometry.
- In Side Notch mode, clicking the menu-bar status item only reveals or hides
  the rail. It never selects a provider or opens provider detail.
- Side-notch width changes use a 200 ms interruptible ease-out. Hover-driven
  preview and spatial retarget obey the same motion policy. Reduced Motion
  makes geometry changes immediate while retaining opacity/color feedback.
- Dashboard-order drag, keyboard move, and reset are one intent with one
  effect. Every logical move writes the composite order exactly once, reorders
  the snapshot once, and publishes control state once. A boundary move (up at
  the top, down at the bottom) is a no-op that writes nothing.
- Reorder motion is the native `List` row animation. No custom transform or
  spring is layered on top, so system Reduce Motion is honored by AppKit
  without an app-specific branch.
- Refresh uses a dedicated active subtree that rotates only while work is
  active. Returning to idle creates a fresh zero-rotation button, so no
  repeat-forever transaction survives refresh completion.
- Refresh has no persistent accent fill; hover and press are its only
  background states.
- Reduced motion: no scale or rotation; opacity/color feedback remains.
- Every icon-only action has an accessibility label and help tooltip.
- Reordering is immediate and uses native drag feedback rather than decorative
  animation. Reduced Motion needs no custom fallback. Successful keyboard or
  accessibility moves post a polite AppKit announcement; no-ops do neither.
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
- Side-notch provider targets are at least 56×58 pt. Each exposes the provider
  name, localized remaining percentage, and a detail-view hint; color and arc
  geometry never carry the meaning alone.
- Edge hover is an accelerator, not the sole entry. Menu-bar activation and
  accessibility focus expose the same revealed state without provider
  selection.
- Hover is never the only way to reach side-notch detail. Every rail row stays
  a focusable button that opens the same detail through Return or Space, so
  keyboard and assistive-technology users lose nothing when no pointer is
  present. The row hint describes that committing path truthfully rather than
  advertising hover.
- Rows are identified by account and provider together, so a screen reader
  reading two accounts of one provider announces two distinct targets.
- Side-notch rows for non-default or repeated accounts show a compact alias
  badge on the rail, the full sanitized alias in detail, help, and
  accessibility text, and remain independently keyed by account and provider.
- Dashboard provider headings include the visible account alias in their
  accessibility label whenever `DashboardAccountIdentityRule` shows it.
- API-key account controls have explicit provider, alias, key, add, and remove
  labels. Validation and persistence feedback is textual, localized, and
  announced by the native settings hierarchy; color is never the only signal.
- Opening a hover preview must not steal keyboard focus from the frontmost
  application; typing in another app continues uninterrupted while a preview
  is open.
- Keyboard focus uses the native accent outline.
- Dashboard order is reachable without a pointer. Each ordering row is
  focusable and exposes explicit `Move Up` and `Move Down` actions bound to
  Command-Up and Command-Down, driving the same semantic move intent as drag.
  Drag is never the only path to reorder.
- Each ordering row exposes its provider-plus-account label, its position as an
  accessibility value, and Move Up / Move Down as custom accessibility actions.
  After a move completes, an `NSAccessibility` polite announcement states the
  new position.
- Ordering never changes connection state. Disconnected providers remain listed
  and orderable with an explicit hidden-from-dashboard status text; disconnect
  stays in the authentication section only.
- Connection state is communicated by text plus color.
- Staleness is communicated by symbol plus text, never by color alone, and the
  Side Notch rail speaks it as part of the provider's accessibility value.
- Every ordering row is one accessibility element labelled by provider and
  sanitized account alias, with position as its value and Move Up/Move Down
  custom actions. Connected/hidden state is spoken and ordering never performs
  a disconnect operation.
- Korean labels must not clip at the Settings window’s minimum width.
- Missing companion tools produce a localized installation requirement rather
  than opening documentation or reporting that authentication started.
- Text and controls use semantic system colors and remain legible in both
  macOS appearances without an app-specific theme toggle.
- Mobile cards retain readable order at accessibility text sizes, expose each
  meter as one combined accessibility element, and use at least 44 pt touch
  targets for toolbar actions.
- The mobile sync header is one accessibility element that speaks the Mac's
  last check time first, then out-of-date and sync-issue qualifications, and
  hints that refreshing checks iCloud only. Snapshot age is never carried by
  the badge color alone.
- When a mobile account alias is visible, it participates in the card's native
  accessibility hierarchy so repeated same-provider cards are distinguishable
  without relying on order. Truncation is visual only; assistive technologies
  receive the full sanitized string.
- Web markup uses one `main`, semantic provider `article` elements, explicit
  status text with `aria-live="polite"`, and native `progress` semantics.
- Settings controls have explicit labels, at least 44 px touch targets,
  deterministic keyboard order, and status/error announcements through a
  polite live region. Reorder and visibility buttons name both provider and
  visible sanitized alias when needed; two same-provider accounts remain
  distinguishable without relying on color or row position.
- Account aliases are inserted with text-only DOM APIs, truncate visually at
  narrow widths, and expose the full sanitized label through `title`; account
  UUIDs remain wire identity only and are never visible or announced.
- At 390×844, 375 px, 768 px, and 1280 px viewports, the document has no
  horizontal overflow. Light/dark system preference and reduced motion are
  honored without a theme toggle.

## 8. Accepted Constraints

- The dashboard is presented by `NSPopover.show(relativeTo:of:preferredEdge:)`
  from the OmoUsage `NSStatusItem`; no custom pointer or screen-relative panel
  geometry is used.
- That popover constraint applies unchanged to the default Popover style.
  Side Notch is a separate borderless, nonactivating `NSPanel` at floating
  level with `canJoinAllSpaces`, `fullScreenAuxiliary`, `transient`,
  `auxiliary`, and `ignoresCycle` collection behavior. It uses only
  `NSScreen.visibleFrame` geometry and never alters the AppKit-owned popover.
- Side Notch is disabled by default. When selected it restores hidden after
  launch and never persists revealed state, provider selection, or detail.
- OmoUsage never forces Aqua, Dark Aqua, or a SwiftUI color scheme. Dashboard,
  Settings, help, and controls inherit the operating-system appearance.
- Native SwiftUI has no reorder handle for a non-scrolling stack, so Dashboard
  Order uses an explicit SF Symbol handle and row drop targets. AppDelegate/web
  retain the legacy provider projection until registry wiring; the composite
  compatibility projections only; the native composition and ordering surface
  are registry-owned and use composite account-provider identity throughout.
- Companion providers keep upstream-style local credential discovery while
  OmoUsage launches only their installed official authentication flow.
- Provider help may link to official documentation. The main Settings row
  starts authentication for missing, malformed, or expired credentials and
  offers refresh retry for transient provider failures while keeping
  disconnect available.
- Companion launch is pending, not authenticated. Settings records
  `waitingForCredential` after an installed app or CLI launches and performs
  one completion check on `NSApplication.didBecomeActiveNotification`.
  Only refreshed `.available` state becomes authenticated; missing,
  malformed, unavailable, or authentication-required credentials remain
  pending, and refresh failure is reported as failed. Help/browser links never
  complete authentication, and reconnect never starts its own refresh.
- The menu-bar item uses the native
  `gauge.with.dots.needle.50percent` SF Symbol as a 14 pt, medium-weight
  monochrome template image.
- OpenCode Go, OpenRouter, and Z.ai keys are written only to their private local
  config files; values are never rendered after save or written to diagnostics.
- Adding a non-default API-key account writes its private key file before the
  atomic registry update and deletes that new file if registry persistence or
  readback fails. Removing persists the registry reference first and deletes
  only the targeted account file; a key-file deletion failure restores the
  prior registry before reporting failure. Legacy references cannot be removed
  through multi-account controls.
- Mobile synchronization contains usage totals, plan labels, reset times, and
  refresh timestamps only. Provider credentials, cookies, API keys, local file
  paths, and diagnostics never enter iCloud.
- The web server binds only to `127.0.0.1:7827`. Tailscale Serve proxies that
  loopback endpoint to the authenticated tailnet; Tailscale Funnel and direct
  LAN/public binding are forbidden.
- Web control chrome and provider-generated dashboard text follow the selected
  Web language. That preference is persisted separately from native App
  language; changing it never mutates the native `LocalizationController` or
  App language preference.
- Read routes are `GET /`, `GET /settings`, `GET /api/snapshot`,
  `GET /api/settings`, `GET /favicon.svg`, and
  `GET /apple-touch-icon.png`. Mutating routes are limited to
  `POST /api/refresh` and `POST /api/settings`.
- Every mutation requires an unpredictable per-launch nonce delivered in the
  same-origin HTML shell and echoed as `X-Omo-CSRF`. Account identity is a
  typed JSON object `{accountID, providerID}`. Composite orders must be unique
  and exactly equal the configured roster; visibility targets must belong to
  that roster. Unknown fields, secret fields, malformed UUIDs, invalid provider
  IDs/orders, oversized bodies, unsupported methods, and traversal-like paths
  are rejected before dispatch.
- Legacy `providerOrder` and `disconnectedProviders` remain read-only settings
  projections for older readers. Legacy provider-level command parsing remains
  only for compatibility tests and external callers; the bundled web UI emits
  account-qualified commands exclusively, so one action never silently changes
  multiple accounts on the same provider.
- The loopback machine remains a trusted boundary; the nonce blocks cross-site
  and accidental mutation, while Tailscale identity remains the remote access
  boundary. No cookies, analytics, external fonts, or third-party scripts are
  accepted.
- iCloud key-value sync requires both Xcode targets to use the same development
  team and ubiquity key-value identifier. Simulator and Catalyst fixture mode
  is accepted only for visual QA; production reads the private iCloud snapshot.
