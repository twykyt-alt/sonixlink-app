# SonixLink iOS BLE remote

Open `SonixLink.xcodeproj` in Xcode 15 or newer, select an iPhone destination, set your Apple development team under Signing & Capabilities, then build and run. The app scans for SonixOS's custom BLE service and exposes playback, seeking, and player-volume controls. It uses CoreBluetooth background mode for reconnects while iOS suspends the app.

On the R1, enable Bluetooth and turn on the **SonixLink** service in SonixOS settings. The service is local BLE: the iPhone must remain within Bluetooth range of the player; it does not provide control over the Internet. First connection should work without pairing because the GATT service is read/write and currently has no encryption requirement.

The wire format and UUIDs are documented in `Protocol.md`.

## Build and install without a Mac

The repository includes `../codemagic.yaml` for a signed TestFlight build on Codemagic's hosted macOS runner. It builds for iPhone and iPad and uploads the IPA to TestFlight.

1. Push this repository, including `codemagic.yaml`, to a Git host accessible from your Codemagic account.
2. In Codemagic, add the repository as an iOS app and select the `sonixlink-ios-device` workflow.
3. In App Store Connect, create an app record with bundle ID `org.sonix.link.ios`.
4. Enroll in the Apple Developer Program and add an App Store Connect API key to Codemagic's Team integrations named `sonixlink_apple`.
5. Start the workflow. When the build finishes processing, add yourself as an internal TestFlight tester in App Store Connect and install Apple's TestFlight app on your iPhone or iPad.

TestFlight avoids registering device IDs or installing an IPA manually. Apple Developer Program membership is required for signing and TestFlight distribution. Keep the API key private and add it only in Codemagic's integration settings; never commit signing keys to this repository.
