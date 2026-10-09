package com.edde746.plezy.games

import android.app.Activity
import android.content.Intent
import android.os.StatFs
import io.flutter.plugin.common.MethodChannel
import java.io.File

class GamesChannel(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkCore" -> {
                val core = call.argument<String>("core") ?: ""
                if (!availableCore(core)) {
                    result.error("plugin_missing", "This build does not include the emulator plugin for this game.", null)
                } else result.success(null)
            }
            "launchRainbow" -> {
                try {
                    activity.startActivity(Intent(Intent.ACTION_MAIN).apply {
                        setClassName("com.luxuriouscomputers.rainbowoverdrive", "com.godot.game.GodotAppLauncher")
                        addCategory(Intent.CATEGORY_LAUNCHER)
                    })
                    result.success(null)
                } catch (_: android.content.ActivityNotFoundException) {
                    result.error("not_installed", "Install Rainbow Overdrive 3D on this device first.", null)
                }
            }
            "extract" -> {
                Thread {
                    try {
                        val root = File(activity.filesDir, "games/cache").canonicalFile
                        val source = File(call.argument<String>("path") ?: "").canonicalFile
                        require(source.path.startsWith(root.path + File.separator))
                        val extensions = call.argument<List<String>>("extensions") ?: emptyList()
                        var chosen: String? = null
                        java.util.zip.ZipFile(source).use { zip ->
                            val entries = zip.entries().asSequence().filter { !it.isDirectory && extensions.any { ext -> it.name.endsWith(ext, true) } }.toList()
                            require(entries.size == 1) { "This archive must contain one game." }
                            val entry = entries.single()
                            val output = File(source.parentFile, "unpacked/" + entry.name).canonicalFile
                            require(output.path.startsWith(File(source.parentFile, "unpacked").canonicalPath + File.separator))
                            require(entry.size in 1..(256L * 1024 * 1024)) { "This archive is too large." }
                            require(StatFs(root.path).availableBytes > entry.size + 128L*1024*1024) { "Not enough free space." }
                            output.parentFile?.mkdirs()
                            zip.getInputStream(entry).use { input -> output.outputStream().use { out ->
                                val buffer = ByteArray(65536); var total = 0L
                                while (true) { val count = input.read(buffer); if (count < 0) break; total += count; require(total <= entry.size); out.write(buffer, 0, count) }
                                require(total == entry.size)
                            } }
                            chosen = output.path
                        }
                        activity.runOnUiThread { result.success(chosen) }
                    } catch (_: Exception) { activity.runOnUiThread { result.error("archive", "This game archive could not be prepared. Check free space and archive contents.", null) } }
                }.start()
            }
            "paths" -> {
                val root = File(activity.filesDir, "games").apply { mkdirs() }
                result.success(mapOf("root" to root.absolutePath, "freeBytes" to StatFs(root.path).availableBytes))
            }
            "launch" -> {
                if (pending != null) { result.error("busy", "A game is already open.", null); return }
                val root = File(activity.filesDir, "games").canonicalFile
                val path = File(call.argument<String>("path") ?: "").canonicalFile
                val save = File(call.argument<String>("saveDir") ?: "").canonicalFile
                val core = call.argument<String>("core") ?: ""
                if (!path.path.startsWith(root.path + File.separator) || !path.isFile ||
                    !save.path.startsWith(root.path + File.separator) || !availableCore(core)) {
                    result.error("invalid_game", "The game file is unavailable.", null); return
                }
                pending = result
                try {
                    activity.startActivityForResult(Intent(activity, GameActivity::class.java).apply {
                        putExtra("path", path.path); putExtra("saveDir", save.path); putExtra("core", core)
                        putExtra("title", call.argument<String>("title"))
                        putExtra("shader", call.argument<String>("shader") ?: "sharp")
                        putExtra("resume", call.argument<Boolean>("resume") ?: true)
                    }, REQUEST)
                } catch (error: Exception) {
                    pending = null
                    result.error("launch_failed", "The emulator could not start.", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun availableCore(core: String): Boolean {
        if (!Regex("[a-z][a-z0-9_]{0,63}").matches(core)) return false
        if (!File(activity.applicationInfo.nativeLibraryDir, "lib${core}_libretro_android.so").isFile) return false
        return try {
            activity.assets.open("emulator_plugins/$core/manifest.json").use { }
            activity.assets.open("emulator_plugins/$core/LICENSE").use { }
            true
        } catch (_: java.io.IOException) { false }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val result = pending; pending = null
        if (resultCode == Activity.RESULT_OK) result?.success(mapOf("played" to (data?.getBooleanExtra("played", false) ?: false)))
        else result?.error("game_failed", data?.getStringExtra("error") ?: "The game closed unexpectedly. Your previous save is kept.", null)
        return true
    }
    companion object { const val REQUEST = 8442 }
}
