// 国内直连 dl.google.com / repo.maven.apache.org 经常卡在「Downloading…」不动
// （实测首次构建 CPU 100 秒只用 0.8 秒，全在等超时）。优先走阿里云镜像，
// 命中不到再回退官方源；镜像只是加速，构件内容由 Gradle 做校验和比对。
val mavenMirrors = listOf(
    "https://maven.aliyun.com/repository/google",
    "https://maven.aliyun.com/repository/public",
)

allprojects {
    repositories {
        mavenMirrors.forEach { mirror -> maven { setUrl(mirror) } }
        google()
        mavenCentral()
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
