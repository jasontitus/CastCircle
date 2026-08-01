# ONNX Runtime Java bindings are VENDORED (classes.jar, see build.gradle.kts)
# so the AAR's consumer rules don't apply — keep everything JNI touches or R8
# strips/renames methods the native bridge calls by name.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
