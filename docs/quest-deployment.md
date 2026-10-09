# Quest 3 deployment

Use Godot 4.6.3. The project uses the Compatibility renderer because [Godot's Quest guidance](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) recommends it for Android XR. Godot 4.6 bundles the Khronos OpenXR loader; the vendor plugin is optional for features outside this milestone.

1. Install OpenJDK 17 and the Android SDK. In Godot **Editor → Editor Settings → Export → Android**, set the SDK and JDK paths. Install the matching Godot 4.6.3 export templates through **Editor → Manage Export Templates**.
2. Enable Developer Mode on Quest 3, connect via USB, accept the headset's USB debugging prompt, and confirm `adb devices` lists it.
3. Open `client/project.godot`. In **Project → Export**, confirm the checked-in `Quest 3` Android preset has **Runnable**, **OpenXR**, and **arm64** enabled. Configure a debug keystore if requested. The preset uses package name `org.worldsmith.viewer`.
4. From the repository root, build and install:

   ```sh
   mkdir -p build
   (cd client && godot --headless --export-debug "Quest 3" ../build/worldsmith.apk)
   adb install -r build/worldsmith.apk
   ```

5. Launch Worldsmith from the headset's app library. You should start near the south side of the hall, see a floor at natural scale, aim at the floor with the right controller, and teleport when releasing the trigger. Press X to enable thumbstick walking. Confirm the walls and table block stick movement.

If the headset opens a flat window or OpenXR initialization fails, first check that the export preset's XR Mode is **OpenXR**, Developer Mode is enabled, and the headset firmware supports the Khronos loader. Godot's [Android XR deployment instructions](https://docs.godotengine.org/en/4.6/tutorials/xr/deploying_to_android.html) describe optional vendor plugin setup when device-specific support is needed.

The preset is committed, while signing paths and Android SDK locations stay in local Godot settings. On the authoring workstation, neither the SDK nor a connected Quest was available to validate an APK; the device acceptance check remains open.
