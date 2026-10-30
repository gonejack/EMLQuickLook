# EML Quick Look

A macOS Quick Look extension for `.eml` and `.emlx` messages that parses and
renders the MIME body itself instead of relying on Mail's preview extension.

It was written to fix a specific bug: on current macOS builds, Apple Mail's
Quick Look extension calls `MCMessage +messageWithRFC822Data:sanitizeData:NO`,
and for a standards-compliant CRLF message that parser returns zero MIME
subparts. The preview then shows headers or a blank body even though the file
is valid. This extension normalizes line endings, parses the message, and
returns a self-contained HTML preview.

## Features

- `.eml` and Apple Mail `.emlx` files
- CRLF, LF, and mixed line endings
- base64 and quoted-printable transfer encodings
- charset detection (declared charset, HTML meta charset, UTF-8, GB18030,
  Windows-1252 fallbacks)
- RFC 2047 encoded headers (`=?UTF-8?B?...?=`)
- `multipart/alternative`, `multipart/related`, and `multipart/mixed`
- inline `cid:` images embedded as `data:` URLs
- Apple Mail "share page" exports made of a sequence of HTML fragments and
  images, concatenated into one article
- a Mail-like message header with sender, date, subject, and recipients,
  using Mail's header type sizes, colors, and spacing
- Mail's 12px Helvetica base typography for HTML bodies, with the message's
  own fonts and sizes still taking precedence
- readable plain-text rendering when there is no HTML body
- attachment list with file names and sizes

Scripts, iframes, objects, meta-refresh tags, inline event handlers, and
`javascript:` URLs are removed from HTML; a restrictive Content-Security-Policy
is added as well. Remote images are not blocked, so a message can still load
tracking pixels from the network.

## Requirements

- macOS 14 or later
- Apple Silicon (the build script targets `arm64-apple-macosx14.0`)
- Xcode Command Line Tools (`xcrun swiftc`, `codesign`)

The build is ad-hoc signed. That is enough for local use, but a Developer ID
signed extension from another app can take precedence for the same content
type. In that case, disable the competing extension with `pluginkit`.

## Build

```sh
cd EMLQuickLook
./build.sh
```

This creates:

- `build/EMLQuickLook.app` — host app with the Quick Look extension
- `build/emlrender` — command-line renderer that writes the preview HTML

## Install

```sh
./install.sh
```

`install.sh` builds the app, copies it to `~/Applications`, registers it with
Launch Services and `pluginkit`, disables Apple Mail's Quick Look extension,
and resets the Quick Look cache. Use `./install.sh --no-build` to install an
existing `build/EMLQuickLook.app` without rebuilding.

Disabling Mail's extension is required because Quick Look has no documented
per-content-type extension precedence. With both enabled, Mail's extension is
selected for `com.apple.mail.email` and the CRLF bug remains.

Open the app once if Finder does not pick up the extension immediately.

## Verify

Select an `.eml` file in Finder and press Space. The first preview can take a
moment while the extension starts.

Render a file without Quick Look:

```sh
./build/emlrender message.eml /tmp/preview.html
open /tmp/preview.html
```

The `emlrender` output reports the parsed title, body type, and number of
embedded images. For example:

```
input bytes:   1081560
message bytes: 1081560
title:         DOS Gaming In Docker
summary:       html body, 5 inline image(s)
html bytes:    1050628
```

`qlmanage -p` is not a reliable test on every macOS build; if it crashes or
shows a blank panel, use Finder or the included host app:

```sh
open ~/Applications/EMLQuickLook.app --args --preview "$PWD/message.eml"
```

Follow the extension log with:

```sh
log stream --level debug --predicate 'subsystem == "com.youi.EMLQuickLook"'
```

## Troubleshooting

If the old preview is still shown, reset Quick Look and restart it:

```sh
qlmanage -r
qlmanage -r cache
killall quicklookd
```

Check which extensions are elected:

```sh
pluginkit -m -A -D -v -p com.apple.quicklook.preview \
    | grep -iE 'MailQuickLook|EMLQuickLook'
```

A `+` means enabled, `-` means disabled. The custom extension should be `+`
and `com.apple.mail.MailQuickLookExtension` should be `-`.

To re-enable Mail's extension:

```sh
pluginkit -e use -i com.apple.mail.MailQuickLookExtension
```

## Uninstall

```sh
./uninstall.sh
```

This removes `~/Applications/EMLQuickLook.app`, unregisters the extension,
re-enables Mail's Quick Look extension, and resets the Quick Look cache.

## Layout

```
Extension/
  PreviewProvider.swift   QLPreviewProvider that returns HTML data
  MIMERenderer.swift      MIME parser, decoders, charset and header handling
  HTMLRenderer.swift      body selection, image embedding, sanitization
  Info.plist              declares com.apple.mail.email/emlx
Host/
  main.swift              QLPreviewPanel test harness
Tools/
  main.swift              emlrender CLI
  snapshot.swift          WKWebView PNG snapshot helper
build.sh                  builds and ad-hoc signs everything
install.sh                installs and elects the extension
uninstall.sh              removes it and restores Mail's extension
```

## Why not re-render through Mail's extension?

Passing a temporary `.emlx` file back to Quick Look via
`QLPreviewReply(fileURL:)` does not invoke another preview extension. Quick
Look renders the referenced file with a built-in generator, so the nested
approach cannot reuse Mail's renderer. Producing the HTML directly in this
extension is the dependable route.
