# Shipping PocketRoute to Google Play

These steps were checked against Play's rules as of October 2026. Google changes
them often, so check the linked Play Console Help pages before relying on a number.

The order matters. The two slow parts are **identity verification** (days) and the
**14-day closed test**, so start those early.

---

## 0. What is already done in this repo

| Requirement | State |
|---|---|
| Target API level 36 (Android 16), required for new apps since 31 Aug 2026 | ✅ Flutter's default `targetSdk` is 36 |
| Release signing read from `android/key.properties` | ✅ `android/app/build.gradle.kts` |
| Keystore and `key.properties` kept out of git | ✅ `android/.gitignore` |
| Android App Bundle (`.aab`) builds | ✅ `flutter build appbundle` |
| Privacy policy text | ✅ `docs/privacy-policy.md`; fill in the contact email |
| Unique application ID | ❌ Still `com.example.pocketroute`; see step 2 |
| Launcher icon and store graphics | ❌ Still the Flutter default icon; see step 5 |

---

## 1. Create the developer account (one time, about $25)

1. Go to <https://play.google.com/console/signup> and sign in with the Google account
   that will own the app. A separate account just for publishing is a good idea.
2. Choose **Personal**, unless you have a registered business with a D-U-N-S number.
   An **Organization** account skips the 12-tester rule in step 7.
3. Pay the one-time **US$25** registration fee.
4. Complete **identity verification**: legal name, address, a government ID and a
   verified phone number. This can take a few days. Your legal name is shown on the
   store listing for personal accounts.

## 2. Choose the application ID (permanent)

The application ID identifies the app on Play forever. You can never change it after
the first upload. It doesn't need to be a domain you own; it only has to be unique.
For example:

```
io.github.ranilojohn.pocketroute
```

That form is safe because your GitHub username is yours. Change it in two places:

- `app/android/app/build.gradle.kts`: `namespace` and `applicationId`
- `app/android/app/src/main/kotlin/.../MainActivity.kt`: move the file into the
  matching folder and update its `package` line

Then run `flutter clean` and rebuild. Claude can do this rename for you once you've
picked the ID.

## 3. Create your upload key (one time, keep it forever)

Run this yourself, in a terminal, and choose your own passwords. Don't paste the
passwords into chat or commit them anywhere.

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkey -v `
  -keystore "$env:USERPROFILE\pocketroute-upload.jks" `
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then create `app/android/key.properties`. It is git-ignored, so it's never committed:

```properties
storePassword=<the keystore password you chose>
keyPassword=<the key password you chose>
keyAlias=upload
storeFile=C:/Users/admin/pocketroute-upload.jks
```

**Back up `pocketroute-upload.jks` and both passwords** to a password manager or
cloud drive. With Play App Signing (step 6), Google holds the real app-signing key.
If you lose this upload key, you can ask Google to reset it, but that takes time.

## 4. Build the release bundle

Raise the version in `app/pubspec.yaml` for every upload. The number after `+` must
always go up:

```yaml
version: 1.0.0+1   # first upload
version: 1.0.1+2   # next one, and so on
```

Then build:

```powershell
cd C:\Users\admin\source\repos\routelab\app
flutter build appbundle --release
```

The bundle is written to `app\build\outputs\bundle\release\app-release.aab`. It is about
50 MB because it contains every CPU type; Play delivers only the part each phone
needs, which is usually about 15–20 MB.

Test the release build on a real phone first:

```powershell
flutter run --release
```

## 5. Prepare the store listing

You'll need:

- **App icon**: 512 × 512 PNG, 32-bit, under 1 MB. It must be original artwork,
  not Canva or Cisco icons.
- **Feature graphic**: 1024 × 500 PNG or JPG.
- **Screenshots**: at least 2 phone screenshots. Because PocketRoute targets tablets,
  also add 7-inch and 10-inch tablet screenshots. Take them on the emulators:
  ```powershell
  adb -s emulator-5662 exec-out screencap -p > tablet-1.png
  ```
- **Short description** (80 characters at most), for example:
  "Build, cable and configure routers and switches offline. A pocket network lab."
- **Full description** (4000 characters at most). Include this line, because the
  CLI looks like Cisco's:
  > PocketRoute is an independent educational tool. It is not affiliated with,
  > endorsed by or sponsored by Cisco Systems, Inc. Cisco, IOS and Packet Tracer
  > are trademarks of Cisco Systems, Inc.
- **Category**: Education. **Tags**: networking, education.
- **Contact email**: required, and shown publicly.
- **Privacy policy URL**: after you push, use the GitHub link to
  `docs/privacy-policy.md`, for example
  `https://github.com/RaniloJohn/PocketRoute/blob/main/docs/privacy-policy.md`.
  It must be a public page. GitHub Pages also works.

## 6. Create the app in Play Console

1. **Create app**: name *PocketRoute*, default language, choose **App**, **Free**,
   and accept the declarations.
   - Free apps can never be made paid later.
2. Fill in **App content** (Policy › App content):
   - **Privacy policy**: the URL from step 5.
   - **Ads**: No.
   - **App access**: All functionality is available without special access.
   - **Content rating**: complete the IARC questionnaire. Choose Education or
     Reference; there's no violence and no user interaction. This should rate
     Everyone / PEGI 3.
   - **Target audience**: 13+ or 18+ is simplest. Choosing under-13 brings in the
     Families policy requirements.
   - **Data safety**: *No data collected* and *No data shared*. This is accurate:
     the app has no internet permission in release builds, no analytics and no
     accounts.
   - **Government app**: No. **Financial features**: None. **Health**: None.
3. **Play App Signing**: accept the default, which lets Google manage the
   app-signing key. You upload `.aab` files signed with your upload key.

## 7. Closed test: 12 testers for 14 days (new personal accounts)

Personal accounts created after November 2023 can't publish to production straight
away. You must:

1. Create a **Closed testing** track (Testing › Closed testing). The internal
   testing track doesn't count.
2. Upload `app-release.aab` there, with release notes.
3. Add at least **12 testers** by email address or a Google Group. Share the opt-in
   link with them.
4. Testers must **opt in, install, and stay opted in for 14 days in a row**. Anyone
   who leaves resets their own count, so recruit 15–20 people to leave a margin.
   Classmates, an instructor or a networking club fit well.
5. Push at least one update during the test, and ask testers to leave feedback.
   Google asks what you learned when you apply.
6. After 14 days, go to **Dashboard › Apply for production** and answer the
   questions about the test. Google says review takes up to about 7 days.

## 8. Production release

1. Go to Production › Create new release and upload the `.aab`. You can also promote
   the closed-testing release.
2. Use a **staged rollout**, for example 20% first, then 100%.
3. Send it for review. A first review can take a few days; updates are usually
   faster.

## 9. Every update after that

1. Raise the `version:` in `pubspec.yaml`, especially the `+N` build number.
2. Run `flutter build appbundle --release`.
3. Upload to a track, write release notes and roll out.
4. Keep the target API level current. Google raises it every August, and next year
   it will be API 37. Updating Flutter and rebuilding usually covers this.

---

## Watch out for

- **Android developer verification (2026–2027).** Google is rolling out identity
  registration for all Android developers, including apps installed outside Play.
  Your Play Console account is already verified, so apps from Play are covered.
  Register the package name when the Console asks you to.
- **Don't ship the debug-signed build.** If `key.properties` is missing, Gradle falls
  back to the debug key, and Play rejects that upload. That's the signal that step 3
  is incomplete.
- **Trademarks.** Don't use "Cisco", "Packet Tracer" or Cisco icons in the app name,
  icon, screenshots or keywords.

## Sources

- [Target API level requirements (Play Console Help)](https://support.google.com/googleplay/android-developer/answer/11926878)
- [Testing requirements for new personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Flutter: Build and release an Android app](https://docs.flutter.dev/deployment/android)
