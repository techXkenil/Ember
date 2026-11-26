package com.ember.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServicePlugin
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.util.concurrent.Executors

private object PlaybackLockManager {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean) {
        val appCtx = context.applicationContext
        if (enabled) {
            if (wakeLock == null) {
                val pm = appCtx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Ember::PlaybackWakeLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire()
            }

            if (wifiLock == null) {
                val wm = appCtx.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm?.createWifiLock(mode, "Ember::PlaybackWifiLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
        } else {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        }
    }
}

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.ember/python"
    private val executor = Executors.newSingleThreadExecutor()

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return AudioServicePlugin.getFlutterEngine(context)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            PlaybackLockManager.setEnabled(this, false)
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "set_playback_wakelock") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                try {
                    PlaybackLockManager.setEnabled(this, enabled)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("WAKELOCK_ERROR", e.message, null)
                }
                return@setMethodCallHandler
            }

            val py = Python.getInstance()
            val module = py.getModule("android_api")
            
            when (call.method) {
                "search" -> {
                    val query = call.argument<String>("query")
                    val filter = call.argument<String>("filter")
                    executor.execute {
                        try {
                            val res = module.callAttr("search", query, filter)
                            val kotlinList = res.asList().map { it.asMap().mapKeys { k -> k.key.toString() }.mapValues { v -> v.value.toString() } }
                            runOnUiThread { result.success(kotlinList) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "similar" -> {
                    val seedId = call.argument<String>("seedId")
                    executor.execute {
                        try {
                            val res = module.callAttr("similar", seedId)
                            val kotlinList = res.asList().map { it.asMap().mapKeys { k -> k.key.toString() }.mapValues { v -> v.value.toString() } }
                            runOnUiThread { result.success(kotlinList) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "get_stream_url" -> {
                    val videoId = call.argument<String>("videoId")
                    val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
                    executor.execute {
                        try {
                            val res = module.callAttr("get_stream_url", videoId, forceRefresh).asMap()
                            val kotlinMap = res.mapKeys { it.key.toString() }.mapValues { it.value?.toString() }
                            runOnUiThread { result.success(kotlinMap) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "get_home" -> {
                    executor.execute {
                        try {
                            val res = module.callAttr("get_home").toString()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "lyrics" -> {
                    val videoId = call.argument<String>("videoId") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val duration = call.argument<String>("duration") ?: ""
                    executor.execute {
                        try {
                            val res = module.callAttr("lyrics", videoId, title, artist, duration)?.toString()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "get_artist_details" -> {
                    val browseId = call.argument<String>("browse_id")
                    executor.execute {
                        try {
                            val res = module.callAttr("get_artist_details", browseId)?.toString()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "import_playlist" -> {
                    val identifier = call.argument<String>("identifier")
                    executor.execute {
                        try {
                            val res = module.callAttr("import_playlist", identifier)?.toString()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                "build_affinity_graph" -> {
                    val historyJson = call.argument<String>("history_json")
                    executor.execute {
                        try {
                            val res = module.callAttr("build_affinity_graph", historyJson)?.toString()
                            runOnUiThread { result.success(res) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PYTHON_ERROR", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
