# Quest 3 deployment

Use Godot 4.6.3. The project uses the Compatibility renderer because [Godot's Quest guidance](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) recommends it for Android XR. Godot 4.6 bundles the Khronos OpenXR loader; the vendor plugin is optional for features outside this milestone.

1. Install OpenJDK 17 and the Android SDK. In Godot on macOS, open **Godot → Editor Settings → Export → Android** and set the SDK and JDK paths. Install the matching Godot 4.6.3 export templates through **Editor → Manage Export Templates**.
2. Enable Developer Mode on Quest 3 in the Meta Horizon phone app, connect via a USB-C data cable, accept the headset's USB debugging prompt, and confirm `"$HOME/Library/Android/sdk/platform-tools/adb" devices` lists it as `device`.
3. Open `client/project.godot`. In **Project → Export**, confirm the checked-in `Quest 3` Android preset has **Runnable**, **OpenXR**, and **arm64** enabled. Configure a debug keystore if requested. The preset uses package name `org.worldsmith.viewer`.
4. From the repository root, build and install:

   ```sh
   mkdir -p build
   ./scripts/godot.sh --headless --path client --export-debug "Quest 3" "$PWD/build/worldsmith.apk"
   "$HOME/Library/Android/sdk/platform-tools/adb" install -r build/worldsmith.apk
   ```

5. Launch **Worldsmith** from **Library → Unknown Sources**. If a local `client/assets/local/preview.json` is active when you export, the APK opens that GLB (for example, `merchant.glb`); otherwise it opens the sample hall. Aim at the floor with the right controller and teleport by releasing the trigger. Press X to enable left-thumbstick walking, then try entrances and stairs.

If the headset opens a flat window or OpenXR initialization fails, first check that the export preset's XR Mode is **OpenXR**, Developer Mode is enabled, and the headset firmware supports the Khronos loader. Godot's [Android XR deployment instructions](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) describe optional vendor plugin setup when device-specific support is needed.

The preset is committed, while signing paths and Android SDK locations stay in local Godot settings. Headset launch, controls, and performance still need device verification.
