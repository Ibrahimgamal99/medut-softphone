# Picked up by the Flutter Gradle plugin for release builds.

# ML Kit (the QR scanner) lists its component registrars in the manifest and
# builds them by reflection. Firebase's own rule keeps those classes but, in
# R8 full mode, not their empty constructors, so ML Kit never starts and
# scanning fails with "an unexpected error".
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }

