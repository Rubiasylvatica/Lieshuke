allprojects {
    repositories {
        google()
        mavenCentral()
        // 官方 Flutter 引擎组件仓库（flutter_embedding / libflutter 等）
        // 原因：清华镜像未同步引擎 Maven 组件；download.flutter.io 直连证书不匹配，
        // 改用 Google 存储官方域名（证书匹配、路径验证存在）（ADR-007）
        maven {
            url = uri("https://storage.googleapis.com/download.flutter.io")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
