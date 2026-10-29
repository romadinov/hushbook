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

## Sync

`CKSyncEngine`, private database, zone `Diary`, container `iCloud.com.romadinov.hushbook`. Records: `Vault`
(salt + wrapped key), `Entry` (sealed payload + modified date), `Photo` (sealed asset). Sync works on ciphertext,
so it keeps running while the diary is locked. Conflicts: last edit wins. A second device looks in iCloud first
and then asks for the existing diary's password instead of creating a new diary.

## Build and install

```sh
scripts/install-mac.sh        # → /Applications/Hushbook.app (iCloud Development)
scripts/install-iphone.sh     # → the connected iPhone (iCloud Development)
scripts/sim-shots.sh <dir> list calendar media editor   # simulator screenshots with demo data
swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
```

For TestFlight / Production builds, deploy the CloudKit schema (Vault, Entry, Photo) to Production first,
the same way as for Uberdoer (see `~/Dev/tasker/docs/TESTFLIGHT.md`).
