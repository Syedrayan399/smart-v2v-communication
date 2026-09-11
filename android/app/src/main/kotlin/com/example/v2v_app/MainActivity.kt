package com.example.v2v_app

import android.media.AudioAttributes
import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "v2v_collision_audio"
    private var collisionPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "initialize" -> {
                    // No notification is created.
                    // Collision audio uses Android notification/alert
                    // audio routing only.
                    result.success(null)
                }

                "play" -> {
                    playCollisionSound(result)
                }

                "stop" -> {
                    stopCollisionSound()
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun playCollisionSound(result: MethodChannel.Result) {

        try {
            stopCollisionSound()

            val resourceId = resources.getIdentifier(
                "collision_warning_chicken_squawk",
                "raw",
                packageName
            )

            if (resourceId == 0) {
                result.error(
                    "AUDIO_RESOURCE_MISSING",
                    "collision_warning_chicken_squawk.wav was not found in android/app/src/main/res/raw/",
                    null
                )
                return
            }

            val afd = resources.openRawResourceFd(resourceId)

            if (afd == null) {
                result.error(
                    "AUDIO_RESOURCE_OPEN_FAILED",
                    "Could not open the collision warning audio resource.",
                    null
                )
                return
            }

            val player = MediaPlayer()

            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(
                        AudioAttributes.CONTENT_TYPE_SONIFICATION
                    )
                    .build()
            )

            player.setDataSource(
                afd.fileDescriptor,
                afd.startOffset,
                afd.length
            )

            afd.close()

            player.setOnCompletionListener {
                it.release()

                if (collisionPlayer === it) {
                    collisionPlayer = null
                }
            }

            player.setOnErrorListener { mediaPlayer, _, _ ->

                mediaPlayer.release()

                if (collisionPlayer === mediaPlayer) {
                    collisionPlayer = null
                }

                true
            }

            collisionPlayer = player

            player.prepare()
            player.start()

            result.success(null)

        } catch (e: Exception) {

            collisionPlayer?.release()
            collisionPlayer = null

            result.error(
                "AUDIO_PLAY_FAILED",
                e.message ?: "Unable to play collision warning audio.",
                null
            )
        }
    }

    private fun stopCollisionSound() {

        collisionPlayer?.let { player ->

            try {
                if (player.isPlaying) {
                    player.stop()
                }
            } catch (_: IllegalStateException) {
                // Player was already stopped.
            }

            try {
                player.release()
            } catch (_: Exception) {
                // Ignore release errors.
            }
        }

        collisionPlayer = null
    }

    override fun onDestroy() {

        stopCollisionSound()

        super.onDestroy()
    }
}