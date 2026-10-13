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
subprojects {
    // Plugins still pin compileSdk 33 or 37. Keep every library on 37 so it
    // matches the app. Register before evaluationDependsOn, which evaluates
    // the project immediately.
    afterEvaluate {
        if (name == "app") return@afterEvaluate
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val setter = android.javaClass.methods.firstOrNull { method ->
            val parameter = method.parameterTypes.singleOrNull()
            method.name == "setCompileSdk" &&
                (parameter == Int::class.javaPrimitiveType || parameter == Integer::class.java)
        }
        setter?.invoke(android, 37)
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
