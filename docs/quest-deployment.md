# Quest 3 deployment

Use Godot 4.6.3. The project uses the Compatibility renderer because [Godot's Quest guidance](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) recommends it for Android XR. Godot 4.6 includes the Khronos OpenXR loader in **Gradle Android builds**. The vendor plugin is optional for features outside this milestone. A direct APK export omits `libopenxr_loader.so` and opens as a flat app on Quest.

## Connect the scene server

Run the server on your computer with `uv run --project server uvicorn app.main:app --host 0.0.0.0 --port 8765`. Keep it on a trusted LAN; this milestone has no authentication. Find the computer's Wi-Fi IP, copy `client/server.example.json` to `client/server.json`, and replace the example IP with it. The local config is gitignored and packaged when you build the APK. If that IP changes, update the config and rebuild. The server must be reachable from the Quest on the same Wi-Fi network.

## Install a built APK

If `build/worldsmith.apk` already exists, enable Developer Mode, connect the Quest with a USB-C data cable, and accept **Allow USB debugging** inside the headset. From the repository root, run:

```sh
"$HOME/Library/Android/sdk/platform-tools/adb" devices
"$HOME/Library/Android/sdk/platform-tools/adb" install -r build/worldsmith.apk
```

The first command should list the Quest as `device`. Launch **Worldsmith** from **Library → Unknown Sources**. Check the in-headset status for **Saved r…** before exiting after an edit. The app can still edit locally while offline, but unsynced edits remain in memory only.

## Build the APK again

1. Install OpenJDK 17 and the Android SDK. In Godot on macOS, open **Godot → Editor Settings → Export → Android** and set the SDK and JDK paths. Install the matching Godot 4.6.3 export templates through **Editor → Manage Export Templates**.
2. Enable Developer Mode on Quest 3 in the Meta Horizon phone app, connect via a USB-C data cable, accept the headset's USB debugging prompt, and confirm `"$HOME/Library/Android/sdk/platform-tools/adb" devices` lists it as `device`.
3. Open `client/project.godot`. In **Project → Export**, confirm the checked-in `Quest 3` Android preset has **Runnable**, **OpenXR**, **arm64**, **Use Gradle Build**, **INTERNET**, and **RECORD_AUDIO** enabled. Configure a debug keystore if requested. The preset uses package name `org.worldsmith.viewer`.
4. From the repository root, install the Gradle build template and build the first APK:

   ```sh
   mkdir -p build
   ./scripts/godot.sh --headless --path client --install-android-build-template --export-debug "Quest 3" "$PWD/build/worldsmith.apk"
   "$HOME/Library/Android/sdk/platform-tools/adb" install -r build/worldsmith.apk
   ```

   For later APK builds, omit `--install-android-build-template`.

5. Launch **Worldsmith** from **Library → Unknown Sources**. The APK opens the environment specified by local preview data, if supplied; otherwise it opens an empty workspace. Connect to a scene server whose selected scene has its own catalog and environment data. Use the left thumbstick to walk, the right thumbstick to turn or tilt, and the right trigger to teleport to a configured walkable surface. Press B or Y to open the inventory populated from that scene's catalog. Place, select, move, rotate, scale, duplicate, delete, undo, and redo available objects. The **AI command…** panel supports typed or transcribed instructions, and **View AI output** shows the proposed operations or an error. Check for the saved revision in the status display before exiting after an edit.

If the headset opens a flat window or OpenXR initialization fails, check that the export preset uses **Gradle Build** and **OpenXR**. `unzip -Z -1 build/worldsmith.apk | grep libopenxr_loader.so` should find the loader. Godot's [Android XR deployment instructions](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) describe optional vendor plugin setup when device-specific support is needed.

The preset is committed, while the generated `client/android/` build tree, signing paths, and Android SDK locations stay local. Scene visual quality and performance still need headset verification.
