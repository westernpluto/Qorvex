# Qorvex

A native iOS Reddit app built in Swift and SwiftUI, designed for iPhone Duo. Sign in with your Reddit account to read your feed.

## Features

- **Your Reddit:** your front page, communities, sorts (Hot, New, Top, Rising, Controversial), search, profiles and threaded comments
- **Media in place:** images, galleries, Reddit video, GIFs, direct video links and YouTube play inline, in feeds, posts and comments
- **Comments:** clear dividers, colored depth rails, tap to collapse, a next-comment button and inline "load more"
- **Minimal:** four tabs (Home, Search, Saved, Settings), with a feed switcher on Home for Popular, All and your communities
- **Native:** swipe actions, long-press menus, haptics, Dynamic Type, Light / Dark / Midnight Black themes
- **Private:** saved posts, history and filters stay on your device

## iPhone Duo

Built around Apple's iPhone Duo guidance:

- **One layout across postures.** On the inner display, the feed and the post sit side by side. On the outer display, posts open full screen like a normal iPhone app. Folding or unfolding keeps your place.
- **System containers only** (tab bar, split view, navigation stacks), so bars can move to the side of the display and content stays clear of the fold and cameras.
- **Vertical-bar ready:** every toolbar item has an icon and a title.
- **Container-relative layout:** no fixed screen sizes or device checks.
- **Built with Xcode 27** so the app uses the full screen.

## Your Reddit account

Sign in once on reddit.com's own page inside the app. Qorvex never sees your password. While signed out, Qorvex sends nothing to Reddit and shows example posts instead.

Requests are paced and cached so the app stays well under Reddit's limits. If Reddit pushes back, Qorvex pauses and shows cached content.

## Your own API key (optional)

If you have your own Reddit app (reddit.com/prefs/apps, type "installed app"), you can connect it in Settings → Advanced. The redirect URI must match exactly (default `qorvex://auth`).

## Installing

Every push builds an unsigned IPA on GitHub Actions (Xcode 27 runner). Download the **Qorvex-1.0.N** artifact from the Actions tab and install it with a sideloading tool that signs with your Apple ID. With a Mac, you can instead open `Qorvex.xcodeproj` in Xcode, set your team and run it on your iPhone. Free Apple IDs need re-signing every 7 days.

## Project layout

```
Qorvex/
  App/         App entry, tab bar, adaptive split navigation
  Core/        Models, Reddit client, settings, library, markdown, routing, sample content
  Components/  Post rows, media views, inline media, shared UI
  Views/       Feed, post & comments, search, saved, profile, settings
```

Requires iOS 17+. No third-party dependencies.

*Qorvex is an independent app and is not affiliated with Reddit.*
