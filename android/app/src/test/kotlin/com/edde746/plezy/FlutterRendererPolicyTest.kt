package com.edde746.plezy

import org.junit.Assert.assertEquals
import org.junit.Test

class FlutterRendererPolicyTest {

  @Test
  fun vulkan11Capable32BitTvKeepsImpellerForTheStore() {
    // A 32-bit Android TV that advertises Vulkan 1.1 (e.g. the ONN 4K box) must
    // keep Impeller so the flutter_scene 3D Blockbusta store can render. Forcing
    // Skia here disables Flutter GPU and hangs the store on "Opening the crypt…".
    val renderer = select(manufacturer = "TCL", is64Bit = false, supportsVulkan11 = true)

    assertEquals(FlutterRenderer.IMPELLER, renderer)
    assertEquals("Impeller", renderer.diagnosticName)
  }

  @Test
  fun capable64BitTclTvKeepsAutomaticImpellerBackend() {
    assertEquals(FlutterRenderer.IMPELLER, select(manufacturer = "TCL", is64Bit = true))
  }

  @Test
  fun vulkanIncapable32BitAndroidTvUsesSkia() {
    // Without Vulkan 1.1 there's no Impeller path, so a 32-bit TV falls to Skia.
    assertEquals(
      FlutterRenderer.SKIA,
      select(manufacturer = "SEI Robotics", is64Bit = false, supportsVulkan11 = false),
    )
  }

  @Test
  fun unsupportedTvsStayOnSkia() {
    assertEquals(FlutterRenderer.SKIA, select(sdkInt = 30))
    assertEquals(FlutterRenderer.SKIA, select(supportsVulkan11 = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "Amazon"))
  }

  @Test
  fun existingDeviceDenylistStillTakesPrecedence() {
    assertEquals(FlutterRenderer.SKIA, select(isEWaste = true, isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "NVIDIA", isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "Huawei", isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "HONOR", isAndroidTv = false))
  }

  @Test
  fun ordinaryAndroidDevicesKeepAutomaticImpellerBackend() {
    assertEquals(
      FlutterRenderer.IMPELLER,
      select(manufacturer = "Samsung", isAndroidTv = false, sdkInt = 28, supportsVulkan11 = false, is64Bit = false)
    )
  }

  private fun select(
    isEWaste: Boolean = false,
    manufacturer: String = "Google",
    isAndroidTv: Boolean = true,
    sdkInt: Int = 31,
    supportsVulkan11: Boolean = true,
    is64Bit: Boolean = true
  ): FlutterRenderer = FlutterRendererPolicy.select(
    isEWaste = isEWaste,
    manufacturer = manufacturer,
    isAndroidTv = isAndroidTv,
    sdkInt = sdkInt,
    supportsVulkan11 = supportsVulkan11,
    is64Bit = is64Bit
  )
}
