package com.edde746.plezy

import org.junit.Assert.*
import org.junit.Test

class OnnRenderWorkaroundsTest {
  @Test fun affectedDeviceIsScopedTo32BitOnnTv() {
    assertTrue(OnnRenderWorkarounds.applies("onn", false, true))
    assertTrue(OnnRenderWorkarounds.applies("ONN", false, true))
    assertFalse(OnnRenderWorkarounds.applies("onn", true, true))
    assertFalse(OnnRenderWorkarounds.applies("onn", false, false))
    assertFalse(OnnRenderWorkarounds.applies("NVIDIA", false, true))
  }
}
