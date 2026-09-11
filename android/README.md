# Eburon Edge Android launcher

This APK is a thin Android WebView shell for the local appliance at `http://127.0.0.1:8850`.

It does not embed the multi-hundred-megabyte STT/translation/TTS models. Provision the Termux appliance first, then install the APK for a normal launcher experience.

The CI `release` build is currently signed with Gradle's debug signing configuration so it is installable for appliance testing. It is **not** the Play Store signing configuration. Use a protected production keystore before public Play distribution.
