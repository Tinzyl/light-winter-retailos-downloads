package com.lightwinter.light_winter_retailos

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import woyou.aidlservice.jiuiv5.IWoyouService

class MainActivity : FlutterActivity() {
    private val channelName = "com.lightwinter.retailos/printing"
    private val sunmiPrinterPackage = "woyou.aidlservice.jiuiv5"
    private var sunmiService: IWoyouService? = null
    private var sunmiLatch: CountDownLatch? = null

    private val sunmiConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            sunmiService = IWoyouService.Stub.asInterface(service)
            sunmiLatch?.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            sunmiService = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSunmiDevice" -> result.success(isSunmiDevice())
                    "printSunmiText" -> {
                        val text = call.argument<String>("text").orEmpty()
                        Thread {
                            try {
                                printSunmiText(text)
                                runOnUiThread { result.success(true) }
                            } catch (error: Throwable) {
                                runOnUiThread {
                                    result.error(
                                        "SUNMI_PRINT_FAILED",
                                        error.message ?: "SUNMI printer failed",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isSunmiDevice()) {
            bindSunmiPrinter()
        }
    }

    override fun onDestroy() {
        try {
            unbindService(sunmiConnection)
        } catch (_: IllegalArgumentException) {
        }
        super.onDestroy()
    }

    private fun isSunmiDevice(): Boolean {
        val brand = Build.BRAND.lowercase(Locale.US)
        val manufacturer = Build.MANUFACTURER.lowercase(Locale.US)
        val model = Build.MODEL.lowercase(Locale.US)
        return packageManager.getLaunchIntentForPackage(sunmiPrinterPackage) != null ||
            brand.contains("sunmi") ||
            manufacturer.contains("sunmi") ||
            model.contains("sunmi")
    }

    private fun bindSunmiPrinter(): Boolean {
        if (sunmiService != null) return true
        sunmiLatch = CountDownLatch(1)
        val intent = Intent("woyou.aidlservice.jiuiv5.IWoyouService").apply {
            component = ComponentName(
                sunmiPrinterPackage,
                "sunmi.inner.pkg.service.PrinterService"
            )
        }
        return bindService(intent, sunmiConnection, Context.BIND_AUTO_CREATE)
    }

    private fun getSunmiPrinter(): IWoyouService {
        sunmiService?.let { return it }
        if (!bindSunmiPrinter()) {
            throw IllegalStateException("SUNMI printer service is not available on this device.")
        }
        val connected = sunmiLatch?.await(3500, TimeUnit.MILLISECONDS) ?: false
        return sunmiService ?: throw IllegalStateException(
            if (connected) "SUNMI printer service returned no printer."
            else "Timed out connecting to SUNMI printer service."
        )
    }

    private fun printSunmiText(text: String) {
        if (text.isBlank()) {
            throw IllegalArgumentException("Receipt text is empty.")
        }
        val printer = getSunmiPrinter()
        printer.printerInit(null)
        printer.setAlignment(0, null)
        printer.printText(text.trimEnd() + "\n\n", null)
        printer.lineWrap(3, null)
    }
}
