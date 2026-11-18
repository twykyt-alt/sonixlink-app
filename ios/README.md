# SonixLink for iOS

The iOS target includes library sync and browsing over the player's Wi-Fi API, local search, queue viewing/removal, playlists, folders, favourites, artwork, and playback/volume controls. Enter the R1's IP address in the app and tap **Connect**. It downloads the player's SQLite index and reads the player API on port 7800. The BLE service supplies playback controls and now-playing state when there is no Wi-Fi connection.

On the R1, enable Bluetooth and turn on the **SonixLink** BLE service in SonixOS settings. BLE control works only within Bluetooth range. Full library sync and browsing currently use Wi-Fi; iOS cannot use Android's RFCOMM transport, so the BLE protocol needs more work before library browsing works without Wi-Fi.

The wire format and UUIDs are documented in `Protocol.md`.

## Build and install without a Mac

The repository includes `../codemagic.yaml` for a signed TestFlight build on Codemagic's hosted macOS runner. It builds for iPhone and iPad and uploads the IPA to TestFlight.

1. Push this repository, including `codemagic.yaml`, to a Git host accessible from your Codemagic account.
2. In Codemagic, add the repository as an iOS app and select the `sonixlink-ios-device` workflow.
3. In App Store Connect, create an app record with bundle ID `org.sonix.link.ios`.
4. Enroll in the Apple Developer Program and add an App Store Connect API key to Codemagic's Team integrations named `sonixlink_apple`.
5. Start the workflow. When the build finishes processing, add yourself as an internal TestFlight tester in App Store Connect and install Apple's TestFlight app on your iPhone or iPad.

TestFlight avoids registering device IDs or installing an IPA manually. Apple Developer Program membership is required for signing and TestFlight distribution. Keep the API key private and add it only in Codemagic's integration settings; never commit signing keys to this repository.
