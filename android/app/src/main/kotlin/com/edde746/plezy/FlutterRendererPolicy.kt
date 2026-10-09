package com.edde746.plezy

internal enum class FlutterRenderer(
  val diagnosticName: String,
  val shellArgument: String?
) {
  SKIA("Skia", "--enable-impeller=false"),
  IMPELLER("Impeller", null)
}

/** Selects the Flutter UI renderer before the engine starts. */
internal object FlutterRendererPolicy {
  private const val ANDROID_12_API = 31

  fun select(
    isEWaste: Boolean,
    manufacturer: String,
    isAndroidTv: Boolean,
    sdkInt: Int,
    supportsVulkan11: Boolean,
    is64Bit: Boolean
  ): FlutterRenderer {
    if (isEWaste) return FlutterRenderer.SKIA
    if (manufacturer.equals("NVIDIA", ignoreCase = true)) return FlutterRenderer.SKIA
    if (manufacturer.equals("Huawei", ignoreCase = true) ||
      manufacturer.equals("HONOR", ignoreCase = true)
    ) {
      return FlutterRenderer.SKIA
    }
    if (!isAndroidTv) return FlutterRenderer.IMPELLER
    if (sdkInt < ANDROID_12_API || manufacturer.equals("Amazon", ignoreCase = true) || !supportsVulkan11) {
      return FlutterRenderer.SKIA
    }

    // 32-bit Android TV SoCs are the low-memory / low-throughput class. Skia
    // normally avoids Impeller/Vulkan's higher raster cost on these devices.
    // BUT the 3D video store (flutter_scene / Flutter GPU) REQUIRES Impeller,
    // and this fork forces the store on even on weak GPUs. So on a 32-bit TV
    // that actually advertises Vulkan 1.1 (checked by the caller and folded
    // into supportsVulkan11), keep Impeller so the store can render; only the
    // genuinely Vulkan-incapable 32-bit boxes fall back to Skia (handled by
    // the !supportsVulkan11 guard above). Reverting this to a blanket
    // `if (!is64Bit) return SKIA` disables Impeller on the ONN and hangs the
    // Blockbusta store forever on "Opening the crypt…".
    return FlutterRenderer.IMPELLER
  }
}
