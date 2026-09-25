# CricEco — Development Environment (Windows)

| Component | Location / version |
|---|---|
| Flutter | `C:\src\flutter` — 3.47.5 stable, Dart 3.13.4 (not on PATH: use `C:\src\flutter\bin\flutter.bat`, or add `C:\src\flutter\bin` to PATH) |
| JDK | `C:\src\jdk-21` — Eclipse Temurin 21.0.12 (`flutter config --jdk-dir` set) |
| Android SDK | `C:\src\android-sdk` (`flutter config --android-sdk` set). Includes platform-tools, platforms 35/36, build-tools 36.0.0/36.1.0, NDK 28.2.13676358, emulator |
| Emulator | AVD **`CricEco_API35`**: Pixel 6, Android 15 (API 35) Google APIs x86_64, 6 GB data, 2 GB RAM, WHPX acceleration; launch with `-gpu swiftshader_indirect` |

## Run on the emulator

```bash
C:\src\android-sdk\emulator\emulator.exe -avd CricEco_API35 -no-snapshot -gpu swiftshader_indirect
```

```bash
C:\src\flutter\bin\flutter.bat run -d emulator-5554
```

## Known pitfalls (found during setup)

- **Gradle hangs on NDK auto-install.** On the first build, AGP runs `sdkmanager` to install the NDK. That download stalled at 0 bytes for over 3 hours, because `sdkmanager` has no read timeout. The NDK is now pre-installed. If it happens again, kill the `sdkmanager` Java process and run `sdkmanager "ndk;<version>"` directly.
- **`Unable to establish loopback connection`.** Java on Windows uses an AF_UNIX socket in `%TEMP%`, and it fails if the TEMP path is too long. Normal user TEMP paths are fine; long sandbox paths need `TEMP=TMP=C:\src\tmp`.
- **AVD default data partition is 800 MB.** The debug APK (about 170 MB) plus the system apps fill it, and installs then fail with an empty error. Set `disk.dataPartition.size=6G` in the AVD's `config.ini` and wipe data.
- **First Android build takes about 27 minutes** on this machine (Gradle, Kotlin and Maven downloads, while the emulator competes for CPU). Later builds are incremental.
- **Android 36.1 emulator image is unusable on this machine.** Its `surfaceflinger` crash-loops on the Intel Iris Xe host under every GPU mode, so the API 36.1 AVD and image were removed. Use the API 35 image.
- **Gradle heap vs. emulator memory.** The Flutter template sets Gradle to `-Xmx8G`. On this 7.7 GB machine, a build running next to the emulator exhausted memory: Windows logged "low on virtual memory" and the emulator was killed. `android/gradle.properties` now caps Gradle at 2 GB and the Kotlin daemon at 1 GB.
- **Emulator seam artifact.** The API 35 emulator can draw a faint 1 px diagonal seam across large gradient surfaces (the rectangle is rasterized as two triangles). It is not present in the web build; confirm on a physical device.
- **Emulator 37.1.11 is unstable on this host.** `qemu-system-x86_64` repeatedly crashed with an access violation (`0xc0000005`, same fault offset, Windows Application log event 1000) during builds, installs, `pm clear` and app start, with both host and software GPU. Software rendering (`-gpu swiftshader_indirect`) survived a full Gradle build, but a debug app start at 1080×2400 can then take several minutes. For UI QA prefer a physical Android phone (USB debugging), or retry after an emulator update.
- **Visual Studio is not installed.** It is only needed for Windows desktop builds, which are not a CricEco target.
