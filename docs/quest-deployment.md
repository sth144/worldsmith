# Quest 3 deployment

Use Godot 4.6.3. The project uses the Compatibility renderer because [Godot's Quest guidance](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) recommends it for Android XR. Godot 4.6 includes the Khronos OpenXR loader in **Gradle Android builds**. The vendor plugin is optional for features outside this milestone. A direct APK export omits `libopenxr_loader.so` and opens as a flat app on Quest.

## Install a built APK

If `build/worldsmith.apk` already exists, enable Developer Mode, connect the Quest with a USB-C data cable, and accept **Allow USB debugging** inside the headset. From the repository root, run:

```sh
"$HOME/Library/Android/sdk/platform-tools/adb" devices
"$HOME/Library/Android/sdk/platform-tools/adb" install -r build/worldsmith.apk
```

The first command should list the Quest as `device`. Launch **Worldsmith** from **Library → Unknown Sources**. The current local build includes the merchant preview.

## Build the APK again

1. Install OpenJDK 17 and the Android SDK. In Godot on macOS, open **Godot → Editor Settings → Export → Android** and set the SDK and JDK paths. Install the matching Godot 4.6.3 export templates through **Editor → Manage Export Templates**.
2. Enable Developer Mode on Quest 3 in the Meta Horizon phone app, connect via a USB-C data cable, accept the headset's USB debugging prompt, and confirm `"$HOME/Library/Android/sdk/platform-tools/adb" devices` lists it as `device`.
3. Open `client/project.godot`. In **Project → Export**, confirm the checked-in `Quest 3` Android preset has **Runnable**, **OpenXR**, **arm64**, and **Use Gradle Build** enabled. Configure a debug keystore if requested. The preset uses package name `org.worldsmith.viewer`.
4. From the repository root, install the Gradle build template and build the first APK:

   ```sh
   mkdir -p build
   ./scripts/godot.sh --headless --path client --install-android-build-template --export-debug "Quest 3" "$PWD/build/worldsmith.apk"
   "$HOME/Library/Android/sdk/platform-tools/adb" install -r build/worldsmith.apk
   ```

   For later APK builds, omit `--install-android-build-template`.

5. Launch **Worldsmith** from **Library → Unknown Sources**. If a local `client/assets/local/preview.json` is active when you export, the APK opens that GLB (for example, `merchant.glb`); otherwise it opens the sample hall. The left thumbstick walks in the direction of your gaze immediately; X toggles walking. Aim at the floor with the right controller and teleport by releasing the trigger, then try entrances and stairs.

If the headset opens a flat window or OpenXR initialization fails, check that the export preset uses **Gradle Build** and **OpenXR**. `unzip -Z -1 build/worldsmith.apk | grep libopenxr_loader.so` should find the loader. Godot's [Android XR deployment instructions](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) describe optional vendor plugin setup when device-specific support is needed.

The preset is committed, while the generated `client/android/` build tree, signing paths, and Android SDK locations stay local. Headset controls and performance still need device verification.
