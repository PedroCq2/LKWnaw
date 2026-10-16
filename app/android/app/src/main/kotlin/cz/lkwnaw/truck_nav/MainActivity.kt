package cz.lkwnaw.truck_nav

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.valhalla.valhalla.Valhalla
import com.valhalla.valhalla.config.ValhallaConfigFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Rational
import java.io.File
import java.util.concurrent.Executors

/**
 * Výpočet tras přímo v telefonu (Valhalla Mobile) nad staženým balíkem tras ČR.
 * Dart posílá stejný JSON jako na server Valhally a dostává stejnou odpověď.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var valhalla: Valhalla? = null
    private var tarPath: String? = null

    // Obraz v obraze: během navigace se mapa po odchodu z aplikace zmenší do okénka.
    private var pip: MethodChannel? = null
    private var navigating = false

    private fun pipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(3, 4))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(navigating)
            b.setSeamlessResizeEnabled(false)
        }
        return b.build()
    }

    private fun enterPip(): Boolean {
        val params = pipParams() ?: return false
        return try {
            enterPictureInPictureMode(params)
        } catch (e: Throwable) {
            false
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ přejde do okénka sám (setAutoEnterEnabled), starší verze ručně.
        if (navigating && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pip?.invokeMethod("pip", isInPictureInPictureMode)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lkwnav/pip").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "navigating" -> {
                        navigating = call.arguments as? Boolean ?: false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                setPictureInPictureParams(pipParams()!!)
                            } catch (e: Throwable) {
                            }
                        }
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lkwnav/valhalla").setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("tar")
                    worker.execute {
                        try {
                            if (path == null || !File(path).exists()) throw IllegalStateException("balík tras nenalezen")
                            if (path != tarPath) {
                                valhalla?.close()
                                valhalla = Valhalla(this, ValhallaConfigFactory.usingTileExtract(path))
                                tarPath = path
                            }
                            main.post { result.success(true) }
                        } catch (e: Throwable) {
                            main.post { result.error("open", e.message, null) }
                        }
                    }
                }
                "close" -> {
                    worker.execute {
                        valhalla?.close()
                        valhalla = null
                        tarPath = null
                        main.post { result.success(true) }
                    }
                }
                "route", "trace_attributes" -> {
                    val json = call.argument<String>("json") ?: ""
                    worker.execute {
                        try {
                            val v = valhalla ?: throw IllegalStateException("balík tras není otevřený")
                            val out = if (call.method == "route") v.routeRaw(json) else v.traceAttributesRaw(json)
                            main.post { result.success(out) }
                        } catch (e: Throwable) {
                            main.post { result.error(call.method, e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        valhalla?.close()
        super.onDestroy()
    }
}
