package com.edde746.plezy

/** Workarounds verified against the 32-bit ONN Android TV graphics driver. */
internal object OnnRenderWorkarounds {
  fun applies(manufacturer: String, is64Bit: Boolean, isAndroidTv: Boolean): Boolean =
    isAndroidTv && !is64Bit && manufacturer.equals("onn", ignoreCase = true)
}
