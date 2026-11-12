# Qorvex

A native iOS Reddit reader built in Swift and SwiftUI. It's free, private, and needs no account.

Qorvex reads Reddit's public JSON pages directly from your iPhone. There's no API key, no OAuth app, no login, and no server in the middle. Every request comes from your own device.

## About rate limits

Reddit limits anonymous traffic to roughly 10 requests per minute per IP. Qorvex never goes over that limit:

- **Request budget:** a built-in governor spaces requests out (9/min by default, adjustable in Settings). Extra requests wait in a queue instead of being rejected, and a small "Pacing requests…" pill appears while they wait.
- **On-disk cache:** every page is cached, so going back, reopening a post, or switching tabs costs zero requests. You can set how fresh the cache stays (1 / 5 / 30 min).
- **Deduplication:** identical requests that are in flight at the same time share one network call.
- **Graceful fallback:** if Reddit ever answers 429, Qorvex backs off, lowers its own budget, and shows the cached copy with a banner. It never shows an error screen when cached data exists.
- **Media is free:** images and videos load from Reddit's CDN (`i.redd.it`, `v.redd.it`, `preview.redd.it`), which doesn't count against the JSON limit. They're cached in a 500 MB disk cache.

Normal reading uses about one request per screen you open (a feed page, a post's comments), so the budget is rarely the bottleneck.

## Features

**Browsing**
- Home (built from your joined communities), Popular, All, any subreddit, custom multi-community feeds
- Sorts: Hot, New, Top, Rising, Controversial, with time ranges
- Card or compact layout, infinite scroll, pull to refresh, skeleton loading
- Subreddit headers with banner, icon, member and online counts, Join, and the full sidebar
- User profiles: overview, posts and comments, with karma and account age

**Posts & comments**
- Threaded comments with colored depth rails; tap to collapse, swipe to collapse the whole thread
- Six comment sorts, "load more replies", "continue this thread", single-thread permalinks
- Floating next-comment button (long-press jumps to the previous one)
- Reddit markdown rendered natively: headings, quotes, lists, code, tables, links, tap-to-reveal spoilers
- OP, MOD and ADMIN badges, user flair, pinned comments, AutoModerator auto-collapse

**Media**
- Full-screen viewer with real pinch and double-tap zoom, swipe between gallery images, swipe down to dismiss, save to Photos, share
- Swipeable galleries, including animated items
- Reddit video over HLS with sound, through the native player (Picture in Picture supported)
- Muted autoplay in feeds that pauses off-screen; GIF/GIFV converted to video; YouTube opens in the app or Safari
- NSFW and spoiler blur with tap to reveal

**Native iOS**
- Swipe actions (right to save, left to hide or share), long-press context menus everywhere
- In-app Safari with optional Reader mode, haptics, Dynamic Type sizes
- Two-pane layout (feed | post) on wide screens: an unfolded phone, a large iPhone in landscape, or iPad
- Light, Dark, Automatic and Midnight Black (OLED) themes, with 8 accent colors

**Your data (stored only on device)**
- Joined communities, saved posts (readable offline), reading history, hidden posts
- Filters by keyword, community, user and domain
- Export and import a JSON backup

## iPhone Duo

Qorvex follows Apple's [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo) guidance:

- **One layout across every posture.** A single `NavigationSplitView` shows the feed and the post side by side on the inner display. It collapses into a single stack on the outer display, so folding or unfolding keeps the post you're reading.
- **System containers only.** Tab bar, split view, navigation stacks and sheets, so the system can move bars to the side of the display and keep content clear of the fold and cameras.
- **Vertical-bar ready.** Every toolbar item has both an icon and a title, which items need in order to appear in vertical bars.
- **Container-relative sizing.** No fixed iPhone dimensions, no `UIDevice` idiom or orientation checks. Media scales to its container's width.

> **Built with Xcode 27** so the app uses the Duo's full screen. Apple notes that apps built with Xcode 26 or earlier don't extend under the status bar and camera. CI runs on GitHub's `xcode-27` runner image.

## Installing it for free

You need a signed build to run any iOS app. Without a paid Apple Developer account, there are two free routes:

### Option A: no Mac (sideload the IPA from CI)
1. Every push builds an **unsigned IPA** on GitHub Actions. Open the repo's **Actions** tab → latest "Build iOS app" run → download the **Qorvex-1.0.N** artifact (N is the build number, also shown in Settings → Version) and unzip it.
2. Install it with a sideloading tool that signs with your free Apple ID, such as **SideStore**, **AltStore**, or **Sideloadly**.
3. Apple limits free-account apps to 7 days, so the tool re-signs it weekly (SideStore and AltStore can do this automatically on-device).

### Option B: with a Mac
1. Open `Qorvex.xcodeproj` in Xcode 16 or newer.
2. Select the **Qorvex** target → *Signing & Capabilities* → set **Team** to your Apple ID (Personal Team). Change the bundle identifier if Xcode asks.
3. Plug in your iPhone, pick it as the run destination, and press **Run**. With a free account it also needs a re-run every 7 days.

A paid Apple Developer account ($99/yr) removes the 7-day limit and allows TestFlight.

## Project layout

```
Qorvex/
  App/         App entry, tab bar, adaptive split navigation
  Core/        Models, Reddit client (rate governor + cache), settings, library, markdown, routing
  Components/  Post rows, media views, video/zoom/Safari wrappers, shared UI
  Views/       Feed, post & comments, search, library, user, settings
```

Requires iOS 17+. No third-party dependencies.

*Qorvex is an independent app and is not affiliated with Reddit.*
