# Ohm

Apple Silicon için enerji ve çekirdek yöneticisi.

### Derleme
`cd app && xcodegen && xcodebuild -scheme Ohm -configuration Debug build`

### Test
`cd app/OhmCore && swift test`

Signing: create `app/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team id>` (gitignored). Without an Xcode account, build with `CODE_SIGNING_ALLOWED=NO`.
The CLI lives at `Ohm.app/Contents/Helpers/ohm`: `Contents/MacOS/ohm` would collide with `Contents/MacOS/Ohm` on case-insensitive APFS.
