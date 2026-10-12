# R8 混淆保留规则（release 压缩用）
# ML Kit 通过反射加载各语言识别模型类，不能被移除
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# sherpa-onnx 离线语音（FFI + 原生 .so），防御性保留其插件加载类
-keep class com.k2fsa.sherpa.onnx.** { *; }
-dontwarn com.k2fsa.sherpa.onnx.**
