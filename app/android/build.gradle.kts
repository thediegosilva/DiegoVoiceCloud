allprojects {
    repositories {
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
// Plugins antigos (ex.: mp_audio_stream usa compileSdk 31) quebram com as
// dependências AndroidX atuais. Força todos os plugins a compilar com o SDK 37.
// O lint do AGP trava analisando o camera_android_camerax (bug do lint com o
// JDK 17: List.removeLast). Não é necessário para gerar o app.
subprojects {
    tasks.configureEach {
        if (name.startsWith("lintVital")) enabled = false
    }
}
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 37
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
