# Hushbook

A private, encrypted diary for Mac and iPhone, styled after Day One, synced through iCloud.

## Security model

- **Diary password, separate from the device passcode.** PBKDF2-HMAC-SHA256 (600k rounds) turns it into a key
  that unwraps a random 256-bit diary key. Each entry and photo is sealed with AES-256-GCM, using its record id
  as associated data. Only ciphertext is written to disk or sent to iCloud. Decrypted text and images exist only
  in memory.
- **Face ID / Touch ID only, never the passcode.** After you type the password, the diary key is stored in the
  Keychain with `.biometryCurrentSet` (`ThisDeviceOnly`, not synced). That item has no passcode fallback.
  Enrolling a new face or finger destroys it. The expiry ("Ask for password every…", default a week) is stored
  inside the protected value. Biometric unlocks never extend it; only typing the password starts a new period.
- **Auto-lock.** The iPhone locks when the app leaves the foreground (configurable) and hides the app-switcher
  snapshot. The Mac locks on sleep, screen lock, user switch, and after 5 minutes in the background (configurable).
  ⌘L locks; ⇧⌘L also forgets the biometric key.
- **No recovery.** If you forget the password, the entries are unreadable. Don't save it in Passwords /
  iCloud Keychain: the device passcode opens those.
- Photos are re-encoded as JPEG, which drops EXIF/GPS metadata.

## Voice notes

The mic button in an entry records a voice note. It's encrypted like photos (`Audio` records in iCloud), playable in
the entry, and transcribed **on the device** (audio is never sent anywhere). The transcript is added to the entry text.

- The audio is split at pauses into phrases. Whisper (WhisperKit, large-v3 turbo on Mac, the device default on iPhone)
  detects each phrase's language. Consecutive phrases in the same language are joined (≤25 s).
- Russian → **GigaAM v3** e2e CTC (Sber, MIT; Core ML conversion `inhum/gigaam-v3-coreml`), with punctuation.
  English → Whisper. A note that switches language between sentences is transcribed, not translated.
- Models download on first use (Whisper ≈0.6 GB, GigaAM ≈0.45 GB) into `Application Support/Hushbook/Models`.
  The first Whisper load compiles it for the Neural Engine (≈2–3 min on a Mac, once). Settings → Voice Notes
  shows status, can pre-download, and can force Russian or English.
- Diagnostic: `Hushbook.app/Contents/MacOS/Hushbook --transcribe-test file.m4a …` prints what a note would become.

## Importing from Day One

In Day One (Mac): **File → Export → JSON** (choose all journals). Then in Hushbook (Mac, unlocked):
**File → Import from Day One…** and pick the .zip. Text, dates, tags, starred and photos come across. Day One
Markdown is converted to plain text, and inline photos move to the entry's photo strip. Importing the same export
again skips entries that are already there. Videos, audio, location and weather are not imported. Imported entries
sync to the iPhone. Delete the export zip afterwards: it is not encrypted.

## Sync

`CKSyncEngine`, private database, zone `Diary`, container `iCloud.com.romadinov.hushbook`. Records: `Vault`
(salt + wrapped key), `Entry` (sealed payload + modified date), `Photo` (sealed asset). Sync works on ciphertext,
so it keeps running while the diary is locked. Conflicts: last edit wins. A second device looks in iCloud first
and then asks for the existing diary's password instead of creating a new diary.

## Build and install

```sh
scripts/install-mac.sh        # → /Applications/Hushbook.app (iCloud Development)
scripts/install-iphone.sh     # → the connected iPhone (iCloud Development)
DEVICE=<ipad udid> scripts/install-iphone.sh   # → the iPad (same universal app; three-column layout when wide)
scripts/sim-shots.sh <dir> list calendar media editor   # simulator screenshots with demo data
# Mac demo window rendered to PNG (Debug build; separate data folder, never syncs):
HUSHBOOK_DEMO=list HUSHBOOK_DATA_DIR=/tmp/demo HUSHBOOK_SNAPSHOT=/tmp/mac.png build/Build/Products/Debug/Hushbook.app/Contents/MacOS/Hushbook
swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
```

For TestFlight / Production builds, deploy the CloudKit schema (Vault, Entry, Photo) to Production first,
the same way as for Uberdoer (see `~/Dev/tasker/docs/TESTFLIGHT.md`).
