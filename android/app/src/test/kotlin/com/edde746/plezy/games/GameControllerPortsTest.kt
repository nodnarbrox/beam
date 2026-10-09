package com.edde746.plezy.games

import org.junit.Assert.*
import org.junit.Test

class GameControllerPortsTest {
    @Test fun switchControllerUsesPlayerOneDespiteEarlierTvDevices() {
        val ports = GameControllerPorts()
        ports.update(listOf(13))
        assertEquals(0, ports.port(13, true))
        assertEquals(0, ports.port(8, false)) // virtual-remote
        assertEquals(0, ports.port(9, false)) // virtual-search
        assertEquals(0, ports.port(7, false)) // ONN remote
        assertEquals(0, ports.port(-1, false)) // injected keyboard
    }

    @Test fun independentPlayersStayAssignedWhenAnotherDisconnects() {
        val ports = GameControllerPorts()
        ports.update(listOf(13, 17))
        assertEquals(1, ports.port(17, true))
        assertEquals(setOf(0), ports.update(listOf(17)))
        assertEquals(1, ports.port(17, true))
        ports.update(listOf(17, 21))
        assertEquals(0, ports.port(21, true))
    }

    @Test fun fifthControllerCannotOverflowNativeFourPlayerArray() {
        val ports = GameControllerPorts()
        ports.update(listOf(13, 14, 15, 16, 17))
        for (id in 13..16) assertEquals(id - 13, ports.port(id, true))
        assertNull(ports.port(17, true))
        ports.update(listOf(14, 15, 16, 17))
        assertEquals(0, ports.port(17, true))
    }

    @Test fun reconnectAfterAllDisconnectReturnsToPlayerOne() {
        val ports = GameControllerPorts()
        ports.update(listOf(13))
        assertEquals(setOf(0), ports.update(emptyList()))
        ports.update(listOf(23))
        assertEquals(0, ports.port(23, true))
        assertTrue(ports.update(listOf(23)).isEmpty())
    }
}
