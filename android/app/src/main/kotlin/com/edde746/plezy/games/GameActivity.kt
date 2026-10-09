package com.edde746.plezy.games

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.hardware.input.InputManager
import android.media.AudioManager
import android.os.Bundle
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.lifecycle.lifecycleScope
import com.swordfish.libretrodroid.GLRetroView
import com.swordfish.libretrodroid.GLRetroViewData
import com.swordfish.libretrodroid.ShaderConfig
import kotlinx.coroutines.launch
import java.io.File

class GameActivity : ComponentActivity(), InputManager.InputDeviceListener {
    private lateinit var retro: GLRetroView
    private lateinit var container: FrameLayout
    private lateinit var saves: File
    private var menu: View? = null
    private var played = false
    private var failed = false
    private var frames = 0L
    private var reportedAt = 0L
    private val controllerPorts = GameControllerPorts()
    private val heldKeys = mutableSetOf<Pair<Int, Int>>()
    private lateinit var inputManager: InputManager
    private val pink = Color.rgb(255, 45, 149)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        container = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        setContentView(container)
        saves = File(intent.getStringExtra("saveDir")!!).apply { mkdirs() }
        if (intent.getStringExtra("core") == "ppsspp") {
            val marker = File(filesDir, "games/bios/PPSSPP/.installed")
            if (!marker.isFile) {
                fun copyAssets(path: String) {
                    val names = assets.list(path) ?: emptyArray()
                    val destination = File(filesDir, "games/bios/${path.removePrefix("ppsspp/")}")
                    if (names.isEmpty()) {
                        destination.parentFile?.mkdirs()
                        assets.open(path).use { input -> destination.outputStream().use { input.copyTo(it) } }
                    } else { names.forEach { copyAssets("$path/$it") } }
                }
                // PPSSPP assets, when included, come from the reviewed plugin.
                if (assets.list("ppsspp/PPSSPP").isNullOrEmpty()) {
                    setResult(Activity.RESULT_CANCELED, Intent().putExtra("error", "This emulator plugin is missing its required assets."))
                    finish()
                    return
                }
                copyAssets("ppsspp/PPSSPP")
                marker.writeText("1")
            }
        }
        val data = GLRetroViewData(this).apply {
            coreFilePath = File(applicationInfo.nativeLibraryDir, "lib${intent.getStringExtra("core")}_libretro_android.so").path
            gameFilePath = intent.getStringExtra("path")
            systemDirectory = File(filesDir, "games/bios").apply { mkdirs() }.path
            savesDirectory = saves.path
            saveRAMState = File(saves, "save.srm").takeIf { it.isFile }?.readBytes()
            shader = when(intent.getStringExtra("shader")) { "crt" -> ShaderConfig.CRT; "smooth" -> ShaderConfig.Default; else -> ShaderConfig.Sharp }
            // ONN's MMAP path can be silent; use the normal mixer for TV audio.
            preferLowLatencyAudio = !(Build.MANUFACTURER.equals("onn", ignoreCase = true) &&
                packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
        }
        retro = GLRetroView(this, data)
        lifecycle.addObserver(retro)
        container.addView(retro, FrameLayout.LayoutParams(-1, -1))
        retro.requestFocus()
        inputManager = getSystemService(InputManager::class.java)
        inputManager.registerInputDeviceListener(this, null)
        updateControllers()
        lifecycleScope.launch {
            retro.getGLRetroErrors().collect { code -> failGame("This game could not run with its emulator (code $code).") }
        }
        lifecycleScope.launch {
            retro.getGLRetroEvents().collect { event ->
                if (event is GLRetroView.GLRetroEvents.FrameRendered) {
                    if (!played) {
                        played = true
                        val state = File(saves, "resume.state")
                        if (intent.getBooleanExtra("resume", true) && state.isFile) {
                            try { retro.unserializeState(state.readBytes()) } catch (_: Exception) { Log.w("PlezyGames", "Previous state could not restore; starting game normally") }
                        }
                        Log.i("PlezyGames", "First game frame rendered")
                        setResult(Activity.RESULT_OK, Intent().putExtra("played", true))
                        reportedAt = System.currentTimeMillis()
                    }
                    frames++
                    val now = System.currentTimeMillis()
                    if (now - reportedAt >= 10000) {
                        Log.i("PlezyGames", "Emulation FPS: ${frames * 1000 / (now - reportedAt)}")
                        frames = 0; reportedAt = now
                    }
                }
            }
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { toggleMenu() }
        })
    }

    private fun writeAtomic(file: File, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val staging = File(file.parentFile, file.name + ".tmp")
        staging.writeBytes(bytes)
        if (!staging.renameTo(file)) throw IllegalStateException("Save could not be stored")
    }
    private fun persist(): Boolean {
        if (!played || failed) return true
        return try {
            writeAtomic(File(saves, "save.srm"), retro.serializeSRAM())
            writeAtomic(File(saves, "resume.state"), retro.serializeState())
            File(saves, ".pending").writeText("sync")
            Log.i("PlezyGames", "Game save persisted")
            true
        } catch (_: Exception) { Log.e("PlezyGames", "Game save failed"); false }
    }
    override fun onPause() { releaseInputs(); persist(); super.onPause() }
    override fun onDestroy() {
        if (::inputManager.isInitialized) inputManager.unregisterInputDeviceListener(this)
        super.onDestroy()
    }

    private fun isGamepad(device: InputDevice?): Boolean = device != null && !device.isVirtual &&
        !device.name.startsWith("virtual-", ignoreCase = true) && device.supportsSource(InputDevice.SOURCE_GAMEPAD)

    private fun updateControllers() {
        val devices = InputDevice.getDeviceIds().map { InputDevice.getDevice(it) }.filterNotNull().filter { isGamepad(it) }
        controllerPorts.update(devices.map { it.id }).forEach { releaseInputs(it) }
        devices.forEach { Log.i("PlezyGames", "Controller ${it.name}: Android ${it.controllerNumber}, player ${controllerPorts.port(it.id, true)?.plus(1) ?: "unassigned"}") }
    }
    override fun onInputDeviceAdded(deviceId: Int) = updateControllers()
    override fun onInputDeviceRemoved(deviceId: Int) = updateControllers()
    override fun onInputDeviceChanged(deviceId: Int) = updateControllers()

    private fun sendKey(action: Int, key: Int, port: Int) {
        if (action == KeyEvent.ACTION_DOWN) heldKeys.add(port to key)
        else if (action == KeyEvent.ACTION_UP) heldKeys.remove(port to key)
        else return
        retro.sendKeyEvent(action, key, port)
    }
    private fun releaseInputs(onlyPort: Int? = null) {
        if (!::retro.isInitialized) return
        heldKeys.filter { onlyPort == null || it.first == onlyPort }.toList().forEach { (port, key) ->
            sendKey(KeyEvent.ACTION_UP, key, port)
        }
        for (port in 0..3) if (onlyPort == null || port == onlyPort) {
            retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_DPAD, 0f, 0f, port)
            retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_ANALOG_LEFT, 0f, 0f, port)
            retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_ANALOG_RIGHT, 0f, 0f, port)
        }
    }
    private fun pressMenuKey(key: Int) {
        closeMenu()
        sendKey(KeyEvent.ACTION_DOWN, key, 0)
        container.postDelayed({ if (!isDestroyed) sendKey(KeyEvent.ACTION_UP, key, 0) }, 200)
    }

    private fun label(text: String, size: Float) = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(Color.WHITE); setPadding(16, 12, 16, 12)
    }
    private fun button(title: String, action: () -> Unit) = Button(this).apply {
        isFocusableInTouchMode = true
        text = title; isAllCaps = false; textSize = 18f
        val states = arrayOf(intArrayOf(android.R.attr.state_focused), intArrayOf(android.R.attr.state_pressed), intArrayOf())
        background = android.graphics.drawable.GradientDrawable().apply { cornerRadius = 16f; setColor(Color.WHITE) }
        backgroundTintList = ColorStateList(states, intArrayOf(pink, pink, Color.rgb(42, 42, 56)))
        setTextColor(ColorStateList(states, intArrayOf(Color.BLACK, Color.BLACK, Color.WHITE)))
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 8, 0, 8) }
        setOnClickListener { action() }
        setOnFocusChangeListener { _, focused -> alpha = if (focused) 1f else .7f; scaleX = if (focused) 1.03f else 1f }
    }
    private fun toggleMenu() {
        if (menu != null) { if (!failed) closeMenu(); return }
        releaseInputs()
        persist()
        retro.renderMode = android.opengl.GLSurfaceView.RENDERMODE_WHEN_DIRTY
        retro.audioEnabled = false
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(32, 24, 32, 24)
            setBackgroundColor(Color.rgb(20, 20, 28))
        }
        panel.addView(label(intent.getStringExtra("title") ?: "Games", 26f))
        val resume = button("Resume game") { closeMenu() }
        panel.addView(resume)
        panel.addView(button("Press Start") { pressMenuKey(KeyEvent.KEYCODE_BUTTON_START) })
        panel.addView(button("Press Select") { pressMenuKey(KeyEvent.KEYCODE_BUTTON_SELECT) })
        panel.addView(button("Restart game") { retro.reset(); closeMenu() })
        panel.addView(button("Save and return to Games") {
            // Resume the render loop while serializing the final state.
            if (persist()) { finish() } else { panel.addView(label("Save failed. Try again before leaving.", 16f)) }
        })
        panel.addView(label("Controller: A/B/X/Y • Start/Select\nRemote: OK = A • Play/Pause = Start", 15f))
        menu = panel
        container.addView(panel, FrameLayout.LayoutParams(600, -2, Gravity.CENTER))
        resume.requestFocus()
    }
    private fun closeMenu() {
        menu?.let { container.removeView(it) }; menu = null
        retro.renderMode = android.opengl.GLSurfaceView.RENDERMODE_CONTINUOUSLY; retro.audioEnabled = true; retro.requestFocus()
    }
    private fun failGame(message: String) {
        if (failed) return
        failed = true
        Log.e("PlezyGames", message)
        setResult(Activity.RESULT_CANCELED, Intent().putExtra("error", message))
        val panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 24, 32, 24); setBackgroundColor(Color.rgb(20,20,28)) }
        panel.addView(label(message, 22f))
        val back = button("Return to Games") { finish() }; panel.addView(back)
        menu = panel; container.addView(panel, FrameLayout.LayoutParams(600, -2, Gravity.CENTER)); back.requestFocus()
    }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK || event.keyCode == KeyEvent.KEYCODE_BUTTON_MODE || event.keyCode == KeyEvent.KEYCODE_MENU) {
            if (event.action == KeyEvent.ACTION_UP) toggleMenu()
            return true
        }
        if (menu != null) return super.dispatchKeyEvent(event)
        val key = when(event.keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> KeyEvent.KEYCODE_BUTTON_A
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> KeyEvent.KEYCODE_BUTTON_START
            else -> event.keyCode
        }
        if (key in KeyEvent.KEYCODE_DPAD_UP..KeyEvent.KEYCODE_DPAD_RIGHT || key in KeyEvent.KEYCODE_BUTTON_A..KeyEvent.KEYCODE_BUTTON_MODE) {
            val port = controllerPorts.port(event.deviceId, isGamepad(event.device)) ?: return true
            sendKey(event.action, key, port); return true
        }
        return super.dispatchKeyEvent(event)
    }
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (menu != null || !event.isFromSource(InputDevice.SOURCE_JOYSTICK) || event.action != MotionEvent.ACTION_MOVE) {
            return super.dispatchGenericMotionEvent(event)
        }
        // Intercept before GLRetroView can apply Android's unrelated controller number.
        val port = controllerPorts.port(event.deviceId, isGamepad(event.device)) ?: return true
        retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_DPAD, event.getAxisValue(MotionEvent.AXIS_HAT_X), event.getAxisValue(MotionEvent.AXIS_HAT_Y), port)
        retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_ANALOG_LEFT, event.getAxisValue(MotionEvent.AXIS_X), event.getAxisValue(MotionEvent.AXIS_Y), port)
        retro.sendMotionEvent(GLRetroView.MOTION_SOURCE_ANALOG_RIGHT, event.getAxisValue(MotionEvent.AXIS_Z), event.getAxisValue(MotionEvent.AXIS_RZ), port)
        return true
    }
}
